// ═══════════════════════════════════════════════════════════════════
// Saldo Positivo — robô diário
//
//   node robo/robo.mjs dia        busca oscilação, fecha o dia, manda e-mail
//   node robo/robo.mjs recuperar  só age se algum dia ficou sem fechar
//   node robo/robo.mjs universo   refaz a lista de papéis válidos
//
// Fontes, nesta ordem: Yahoo Finance, bolsai, brapi.dev.
//
// Por que o Yahoo vem primeiro (medido em 30/07/2026): o plano
// gratuito da brapi aceita UM ticker por chamada — o robô descobriu
// sozinho, descendo de 20 para 1. Ou seja, no fechamento diário as
// duas custam o mesmo número de requisições, mas o Yahoo é ilimitado
// e a brapi tem cota de 15.000 no mês. E o intradiário SÓ funciona
// pela brapi, porque o Yahoo devolve 429 para IP de datacenter em
// volume. Então a cota fica reservada para onde ela é insubstituível,
// e o fechamento usa a fonte que não acaba.
// Cada uma cobre o que a anterior não entregou. O log diz quem
// entregou quanto — é assim que se percebe uma fonte degradando ao
// longo das semanas em vez de descobrir no dia da queda.
// O Fundamentus recusa conexão de datacenter, então
// raspar a página dele de dentro do GitHub não funciona — e parou de
// funcionar pelo navegador também.
//
// Sem dependência: só o fetch nativo do Node 20.
// ═══════════════════════════════════════════════════════════════════

const URL_SB = process.env.SUPABASE_URL;
const CHAVE  = process.env.SUPABASE_SERVICE_KEY;
const BRAPI  = process.env.BRAPI_TOKEN;
const BOLSAI = process.env.BOLSAI_TOKEN || "";   // opcional, ver adaptador abaixo
const RESEND = process.env.RESEND_API_KEY || "";
const DE     = process.env.EMAIL_DE || "";

if (!URL_SB || !CHAVE) { console.error("faltam SUPABASE_URL e SUPABASE_SERVICE_KEY"); process.exit(1); }
if (!BRAPI)  console.warn("aviso: sem BRAPI_TOKEN — pula a brapi");
if (!BOLSAI) console.warn("aviso: sem BOLSAI_TOKEN — pula a bolsai");

const modo = process.argv[2] || "dia";
const espera = ms => new Promise(r => setTimeout(r, ms));
const HOJE_BR = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const diaBR = iso => new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });

// ─── Supabase ──────────────────────────────────────────────────────
async function sb(caminho, opcoes = {}) {
  const r = await fetch(`${URL_SB}${caminho}`, {
    ...opcoes,
    headers: {
      apikey: CHAVE,
      Authorization: `Bearer ${CHAVE}`,
      "Content-Type": "application/json",
      ...(opcoes.headers || {})
    }
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`${caminho} devolveu ${r.status}: ${txt.slice(0, 300)}`);
  return txt ? JSON.parse(txt) : null;
}

const rpc = (fn, args = {}) =>
  sb(`/rest/v1/rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

// ─── brapi ─────────────────────────────────────────────────────────
// PETR4, MGLU3, VALE3 e ITUB4 respondem sem token, então continuam
// vindo mesmo com a cota do mês zerada. Não confunda isso com "a
// brapi está funcionando" — confira o painel em brapi.dev/dashboard.
async function brapi(caminho) {
  const corta = AbortSignal.timeout(30000);
  let r;
  try {
    r = await fetch(`https://brapi.dev/api${caminho}`, {
      headers: { Authorization: `Bearer ${BRAPI}` },
      signal: corta
    });
  } catch (e) {
    throw new Error(e.name === "TimeoutError" ? "brapi não respondeu em 30s" : `rede: ${e.message}`);
  }
  const txt = await r.text();
  if (!r.ok) throw new Error(`brapi ${r.status}: ${txt.slice(0, 250)}`);
  const j = JSON.parse(txt);
  if (j.error) throw new Error(`brapi: ${j.message}`);
  return j;
}

// ─── Yahoo, a fonte reserva ────────────────────────────────────────
// Um papel por chamada, e exige User-Agent de navegador: com o padrão
// do Node ele recusa. Só entra onde a brapi não entregou.
// Papel da B3 leva sufixo .SA; índice (^BVSP) não leva, e o ^ tem de
// ser escapado na URL. Sem isso o Yahoo devolve 404 no índice.
const simboloYahoo = a => a.startsWith("^") ? encodeURIComponent(a) : `${a}.SA`;

async function yahoo(ativo) {
  const corta = AbortSignal.timeout(20000);
  const r = await fetch(
    `https://query1.finance.yahoo.com/v8/finance/chart/${simboloYahoo(ativo)}?range=5d&interval=1d`,
    { headers: { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
                               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" },
      signal: corta });
  if (!r.ok) throw new Error(`yahoo ${r.status}`);
  const m = (await r.json())?.chart?.result?.[0]?.meta;
  if (!m) throw new Error("yahoo sem meta");

  const preco = m.regularMarketPrice;
  const ante  = m.previousClose ?? m.chartPreviousClose;
  if (!preco || !ante) throw new Error("yahoo sem preço ou fechamento anterior");
  if (!m.regularMarketTime) throw new Error("yahoo sem horário");

  return {
    ativo,
    valor: preco / ante - 1,
    data_cot: diaBR(new Date(m.regularMarketTime * 1000).toISOString())
  };
}

// ─── bolsai, a segunda reserva ─────────────────────────────────────
// ⚠️ ADAPTADOR NÃO VERIFICADO. Eu não testei a API da bolsai e não
// invento formato de resposta. Antes de ligar: crie a conta grátis em
// usebolsai.com, gere o token, e confira em /docs três coisas —
//   1. o caminho do endpoint de cotação em lote
//   2. como o token é enviado (header ou querystring)
//   3. o nome do campo de variação percentual e o de data
// Ajuste as três linhas marcadas e ponha BOLSAI_TOKEN nos secrets.
// Sem o token, esta fonte é pulada e nada muda.
async function bolsai(grupo) {
  const corta = AbortSignal.timeout(25000);
  const r = await fetch(
    `https://api.usebolsai.com/v1/quotes?symbols=${grupo.join(",")}`,   // (1) conferir
    { headers: { Authorization: `Bearer ${BOLSAI}` }, signal: corta }); // (2) conferir
  if (!r.ok) throw new Error(`bolsai ${r.status}`);
  const j = await r.json();
  const saida = [];
  for (const x of (j.results || j.data || [])) {                        // (3) conferir
    const pct = x.change_percent ?? x.regularMarketChangePercent;
    const dia = x.date ?? x.regularMarketTime;
    if (pct == null || !dia) continue;
    saida.push({ ativo: String(x.symbol || x.ticker).toUpperCase(),
                 valor: pct / 100, data_cot: diaBR(dia) });
  }
  return saida;
}


// ─── busca adaptativa ──────────────────────────────────────────────
// A brapi devolve 400 para o LOTE INTEIRO quando algo nele não serve —
// pode ser um ticker que não existe mais, ou o próprio tamanho do lote
// no plano gratuito. Em vez de adivinhar o teto, o robô descobre:
// começa em 20 e vai cortando pela metade até passar. Um papel que
// falhe sozinho fica de fora sozinho, sem derrubar os outros.
// Medido em 30/07/2026: o plano gratuito aceita UM ticker por chamada.
// Começar em 20 desperdiçava 4 requisições por rodada só redescobrindo
// isso. Se um dia o plano mudar, é só pôr BRAPI_LOTE=20 nos secrets —
// o corte pela metade continua valendo como rede de proteção.
let tamanhoOk = Number(process.env.BRAPI_LOTE || 1);

async function buscarBrapi(alvos, guardar) {
  let i = 0, maior = 0, falharam = [];
  while (i < alvos.length) {
    let n = Math.min(tamanhoOk, alvos.length - i);
    for (;;) {
      const g = alvos.slice(i, i + n);
      try {
        const j = await brapiQuote(g);
        for (const x of (j.results || [])) guardar(x);
        maior = Math.max(maior, n);
        i += n;
        break;
      } catch (e) {
        if (n === 1) {
          console.error(`  ${g[0]}: ${e.message}`);
          falharam.push(g[0]);
          i += 1;
          break;
        }
        n = Math.floor(n / 2);
        tamanhoOk = n;
        console.error(`  ${e.message} — reduzindo lote para ${n}`);
      }
      await espera(350);
    }
    await espera(400);
  }
  if (maior) console.log(`maior lote que a brapi aceitou: ${maior}`);
  if (falharam.length) console.log(`recusados um a um: ${falharam.join(", ")}`);
}

async function brapiQuote(grupo) {
  const alvo = grupo.map(encodeURIComponent).join(",");
  const r = await fetch(`https://brapi.dev/api/quote/${alvo}`,
    { headers: { Authorization: `Bearer ${BRAPI}` }, signal: AbortSignal.timeout(20000) });
  if (!r.ok) throw new Error(`brapi ${r.status}`);
  return r.json();
}

const pedacos = (lista, n) => {
  const p = [];
  for (let i = 0; i < lista.length; i += n) p.push(lista.slice(i, i + n));
  return p;
};

// ─── sondar ────────────────────────────────────────────────────────
// Uma requisição só, para saber de que pregão é o dado mais recente.
async function sondar() {
  const linhas = await sb("/rest/v1/peso_atual?select=ativo&limit=1");
  const ref = linhas[0]?.ativo || "PETR4";
  if (BRAPI) {
    try {
      const t = (await brapi(`/quote/${ref}`)).results?.[0]?.regularMarketTime;
      if (t) return diaBR(t);
    } catch (e) { console.error(`sonda pela brapi falhou (${e.message}) — indo de Yahoo`); }
  }
  return (await yahoo(ref)).data_cot;
}

async function recuperar() {
  const data = await sondar();

  if (data === HOJE_BR()) {
    console.log(`última cotação é de hoje (${data}) — pregão em andamento, não é hora de fechar`);
    return;
  }
  // Confere retorno_dia, não oscilacao: se a noite gravou as oscilações
  // e o fechar_dia estourou depois, oscilacao teria a data e o dia
  // ficaria perdido do mesmo jeito.
  const ja = await sb(`/rest/v1/retorno_dia?data=eq.${data}&select=data&limit=1`);
  if (ja.length) { console.log(`${data} já está fechado — nada a recuperar`); return; }

  console.log(`${data} não está no banco — recuperando`);
  await fecharDia();
  await mandarEmails();
}

// ─── fechar o dia ──────────────────────────────────────────────────
async function fecharDia() {
  // papeis_do_dia = o que está valendo + o que este fechamento vai adotar
  // + os índices de referência. Ler peso_atual direto travava tudo: com
  // declaração pendente, peso_atual está vazio e a adoção mora dentro do
  // fechar_dia, que o robô nem chegava a chamar.
  const linhas = await sb("/rest/v1/papeis_do_dia?select=ativo");
  const lista = [...new Set(linhas.map(x => x.ativo))];
  if (!lista.length) {
    console.log("nenhuma carteira com posição em vigor — nada a fazer");
    console.log("ATENÇÃO: se há declaração pendente esperando o pregão, ela NÃO será");
    console.log("adotada, porque a adoção mora dentro do fechar_dia e o robô parou antes.");
    return;
  }

  console.log(`${lista.length} papéis para buscar`);
  const osc = [], achados = new Set(), porFonte = {};

  const registrar = (linha, fonte) => {
    if (achados.has(linha.ativo)) return;
    osc.push(linha);
    achados.add(linha.ativo);
    porFonte[fonte] = (porFonte[fonte] || 0) + 1;
  };

  const faltantes = () => lista.filter(a => !achados.has(a));

  // ── 1ª fonte: Yahoo, um papel por chamada, sem cota ──
  for (const a of faltantes()) {
    try { registrar(await yahoo(a), "yahoo"); }
    catch (e) { console.error(`  ${a}: ${e.message}`); }
    await espera(250);
  }

  // ── 3ª fonte: brapi, reserva ──
  // Só entra no que o Yahoo não entregou. Gasta cota, então quanto
  // menos vier parar aqui, melhor para o intradiário.
  const buracos = faltantes();
  if (BRAPI && buracos.length) {
    console.log(`tentando ${buracos.length} na brapi`);
    const guardar = x => {
      const pct = x.regularMarketChangePercent;
      if (pct == null || !x.regularMarketTime) return;
      registrar({ ativo: x.symbol, valor: pct / 100,
                  data_cot: diaBR(x.regularMarketTime) }, "brapi");
    };
    await buscarBrapi(buracos.filter(a => !a.startsWith("^")), guardar);
    await buscarBrapi(buracos.filter(a =>  a.startsWith("^")), guardar);
  }

  const resumo = Object.entries(porFonte).map(([f, n]) => `${f} ${n}`).join(" · ") || "ninguém";
  console.log(`de ${lista.length} papéis: ${resumo}`);

  const faltando = faltantes();
  // O robô antigo engolia falha em silêncio e dizia "pronto". Aqui não.
  if (faltando.length) console.error(`NÃO VIERAM ${faltando.length}: ${faltando.join(", ")}`);

  const limite = Math.max(2, Math.ceil(lista.length * 0.1));
  if (faltando.length > limite) {
    throw new Error(`${faltando.length} de ${lista.length} não vieram — passou do limite de ${limite}. ` +
                    `Não vou fechar o dia com dado furado.`);
  }
  if (!osc.length) throw new Error("nenhuma oscilação lida");

  // Misturar fontes tem um custo escondido: se uma ajustar a variação
  // por provento e a outra não, dois papéis do mesmo dia saem em
  // réguas diferentes. Enquanto o teste do dia "ex" não for feito,
  // o log acima é a única pista de quando isso aconteceu.
  const datas = [...new Set(osc.map(o => o.data_cot))];
  if (datas.length > 1) {
    console.error(`ATENÇÃO: veio mais de uma data no mesmo lote — ${datas.join(", ")}`);
  }
  console.log(`pregão: ${datas.join(", ")}`);

  await rpc("robo_gravar_oscilacao", { dados: osc });
  const n = await rpc("robo_fechar_dia");
  console.log(`gravadas ${osc.length} oscilações · ${n} carteiras fechadas`);
}

// ─── universo de papéis ────────────────────────────────────────────
async function atualizarUniverso() {
  const lista = [];
  let pagina = 1, paginas = 1;

  do {
    const j = await brapi(`/quote/list?type=stock&limit=500&page=${pagina}`);
    paginas = j.totalPages || 1;
    for (const s of (j.stocks || [])) {
      const ativo = String(s.stock || "").toUpperCase();
      if (s.subType && s.subType !== "stock") continue;   // corta unit, fii, etf, bdr
      if (!/^[A-Z]{4}\d$/.test(ativo)) continue;
      const cot = Number(s.close), vol = Number(s.volume);
      if (!cot || cot <= 0) continue;
      const liq = cot * (vol || 0);                        // volume financeiro do dia
      if (liq < 200000) continue;
      lista.push({ ativo, cotacao: cot, liquidez: Math.round(liq) });
    }
    pagina++;
    await espera(400);
  } while (pagina <= paginas && pagina <= 20);

  if (lista.length < 150) {
    throw new Error(`só ${lista.length} papéis passaram no filtro — resposta veio curta. ` +
                    `Não vou regravar o universo com lista incompleta.`);
  }

  for (const g of pedacos(lista, 400)) await rpc("robo_gravar_universo", { dados: g });
  console.log(`universo regravado com ${lista.length} papéis`);
}

// ─── esvaziar a fila de e-mail ─────────────────────────────────────
async function mandarEmails() {
  if (!RESEND || !DE) { console.log("sem RESEND_API_KEY ou EMAIL_DE — fila não foi tocada"); return; }

  const fila = await sb("/rest/v1/fila_email?enviado_em=is.null&tentativas=lt.5" +
                        "&order=criado_em.asc&limit=50");
  if (!fila.length) { console.log("fila vazia"); return; }

  let ok = 0;
  for (const m of fila) {
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: DE, to: m.destino, subject: m.assunto, text: m.corpo })
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 200)}`);
      await sb(`/rest/v1/fila_email?id=eq.${m.id}`, {
        method: "PATCH",
        body: JSON.stringify({ enviado_em: new Date().toISOString(), erro: null })
      });
      ok++;
    } catch (e) {
      await sb(`/rest/v1/fila_email?id=eq.${m.id}`, {
        method: "PATCH",
        body: JSON.stringify({ tentativas: (m.tentativas || 0) + 1, erro: String(e.message).slice(0, 400) })
      });
    }
    await espera(200);
  }
  console.log(`e-mails enviados: ${ok} de ${fila.length}`);
}

// ─── ordem do dia ──────────────────────────────────────────────────
try {
  if (modo === "universo")       await atualizarUniverso();
  else if (modo === "recuperar") await recuperar();
  else { await fecharDia(); await mandarEmails(); }
  console.log("fim");
} catch (e) {
  console.error("ERRO:", e.message);
  process.exit(1);
}
