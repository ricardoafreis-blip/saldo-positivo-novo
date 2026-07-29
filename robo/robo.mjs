// ═══════════════════════════════════════════════════════════════════
// Saldo Positivo — robô diário
//
//   node robo/robo.mjs dia        busca oscilação, fecha o dia, manda e-mail
//   node robo/robo.mjs recuperar  só age se algum dia ficou sem fechar
//   node robo/robo.mjs universo   refaz a lista de papéis válidos
//
// Fonte: brapi.dev, com Yahoo Finance de reserva.
// O Fundamentus recusa conexão de datacenter, então
// raspar a página dele de dentro do GitHub não funciona — e parou de
// funcionar pelo navegador também.
//
// Sem dependência: só o fetch nativo do Node 20.
// ═══════════════════════════════════════════════════════════════════

const URL_SB = process.env.SUPABASE_URL;
const CHAVE  = process.env.SUPABASE_SERVICE_KEY;
const BRAPI  = process.env.BRAPI_TOKEN;
const RESEND = process.env.RESEND_API_KEY || "";
const DE     = process.env.EMAIL_DE || "";

if (!URL_SB || !CHAVE) { console.error("faltam SUPABASE_URL e SUPABASE_SERVICE_KEY"); process.exit(1); }
if (!BRAPI) console.warn("aviso: sem BRAPI_TOKEN — vai direto para o Yahoo");

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
async function yahoo(ativo) {
  const corta = AbortSignal.timeout(20000);
  const r = await fetch(
    `https://query1.finance.yahoo.com/v8/finance/chart/${ativo}.SA?range=5d&interval=1d`,
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
  const linhas = await sb("/rest/v1/peso_atual?select=ativo");
  const lista = [...new Set(linhas.map(x => x.ativo))];
  if (!lista.length) { console.log("nenhuma carteira publicada — nada a fazer"); return; }

  console.log(`${lista.length} papéis para buscar`);
  const osc = [], achados = new Set();

  if (BRAPI) {
    for (const g of pedacos(lista, 20)) {
      try {
        const j = await brapi(`/quote/${g.join(",")}`);
        for (const r of (j.results || [])) {
          const pct = r.regularMarketChangePercent;
          if (pct == null || !r.regularMarketTime) continue;
          osc.push({ ativo: r.symbol, valor: pct / 100, data_cot: diaBR(r.regularMarketTime) });
          achados.add(r.symbol);
        }
      } catch (e) {
        console.error(`brapi falhou neste lote (${e.message}) — o Yahoo assume`);
      }
      await espera(400);
    }
    console.log(`brapi entregou ${achados.size} de ${lista.length}`);
  }

  // O Yahoo tapa buraco: serve tanto para um papel que faltou quanto
  // para a brapi inteira fora do ar. Um caminho só cobre os dois casos.
  const buracos = lista.filter(a => !achados.has(a));
  if (buracos.length) {
    console.log(`tentando ${buracos.length} no Yahoo`);
    for (const a of buracos) {
      try {
        osc.push(await yahoo(a));
        achados.add(a);
      } catch (e) {
        console.error(`  ${a}: ${e.message}`);
      }
      await espera(250);
    }
  }

  const faltando = lista.filter(a => !achados.has(a));
  // O robô antigo engolia falha em silêncio e dizia "pronto". Aqui não.
  if (faltando.length) console.error(`NÃO VIERAM ${faltando.length}: ${faltando.join(", ")}`);

  const limite = Math.max(2, Math.ceil(lista.length * 0.1));
  if (faltando.length > limite) {
    throw new Error(`${faltando.length} de ${lista.length} não vieram — passou do limite de ${limite}. ` +
                    `Não vou fechar o dia com dado furado.`);
  }
  if (!osc.length) throw new Error("nenhuma oscilação lida");

  const datas = [...new Set(osc.map(o => o.data_cot))];
  console.log(`pregão: ${datas.join(", ")}`);

  await rpc("gravar_oscilacao", { dados: osc });
  const n = await rpc("fechar_dia");
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

  for (const g of pedacos(lista, 400)) await rpc("gravar_universo", { dados: g });
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
