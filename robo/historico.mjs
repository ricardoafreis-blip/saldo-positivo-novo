// ═══════════════════════════════════════════════════════════════════
// historico.mjs — carrega pregões REAIS do Yahoo e fecha um por um
//
//   node robo/historico.mjs 3mo      (padrão: 3mo; aceita 1mo, 6mo, 1y)
//
// ⚠️ LABORATÓRIO. Isto viola de propósito a regra "sem histórico
// retroativo": as carteiras não existiam nessas datas. Serve para
// provar o motor com mercado real em vez de número sorteado. APAGAR
// antes de entrar gente de verdade — o SQL do rodapé faz isso.
//
// Antes de rodar, no SQL Editor:
//   delete from retorno_dia;
//   delete from oscilacao;
//   delete from peso_atual;
//   update posicao set valida_de = '2026-05-04';   -- início da janela
//
// Sem dependência: fetch nativo do Node 20.
// ═══════════════════════════════════════════════════════════════════

const URL_SB = process.env.SUPABASE_URL;
const CHAVE  = process.env.SUPABASE_SERVICE_KEY;
const FAIXA  = process.argv[2] || "3mo";

if (!URL_SB || !CHAVE) {
  console.error("faltou SUPABASE_URL ou SUPABASE_SERVICE_KEY");
  process.exit(1);
}

const espera = ms => new Promise(r => setTimeout(r, ms));

async function sb(caminho, opcoes = {}) {
  const r = await fetch(`${URL_SB}${caminho}`, {
    ...opcoes,
    headers: {
      apikey: CHAVE,
      Authorization: `Bearer ${CHAVE}`,
      "Content-Type": "application/json",
      ...(opcoes.headers || {}),
    },
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`supabase ${r.status}: ${txt.slice(0, 300)}`);
  return txt ? JSON.parse(txt) : null;
}

const rpc = (fn, corpo) =>
  sb(`/rest/v1/rpc/${fn}`, { method: "POST", body: JSON.stringify(corpo || {}) });

// Índice não leva .SA e o ^ precisa ser escapado.
const simbolo = a => (a.startsWith("^") ? encodeURIComponent(a) : `${a}.SA`);

// unix em segundos → data no fuso de São Paulo
const diaBR = seg =>
  new Date(seg * 1000).toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

// ─── série diária real de um papel ─────────────────────────────────
// Devolve [{ativo, valor, data_cot}] com a variação de cada dia,
// calculada de fechamento contra fechamento anterior. O primeiro dia
// usa chartPreviousClose, que é o fechamento do dia anterior à janela.
async function serie(ativo) {
  const r = await fetch(
    `https://query1.finance.yahoo.com/v8/finance/chart/${simbolo(ativo)}?range=${FAIXA}&interval=1d`,
    {
      headers: { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" },
      signal: AbortSignal.timeout(25000),
    });
  if (!r.ok) throw new Error(`yahoo ${r.status}`);

  const res = (await r.json())?.chart?.result?.[0];
  if (!res) throw new Error("yahoo sem resultado");

  const t = res.timestamp || [];
  const f = res.indicators?.quote?.[0]?.close || [];
  let ante = res.meta?.chartPreviousClose ?? null;

  const saida = [];
  for (let i = 0; i < t.length; i++) {
    const p = f[i];
    // dia sem negócio vem null; pula sem quebrar a corrente
    if (p == null) continue;
    if (ante != null && ante > 0) {
      saida.push({ ativo, valor: p / ante - 1, data_cot: diaBR(t[i]) });
    }
    ante = p;
  }
  return saida;
}

// ═══════════════════════════════════════════════════════════════════
try {
  const linhas = await sb("/rest/v1/papeis_do_dia?select=ativo");
  const lista = [...new Set(linhas.map(x => x.ativo))];
  if (!lista.length) throw new Error("papeis_do_dia está vazio — rode o banco10 e o banco12");

  console.log(`${lista.length} papéis · janela ${FAIXA}`);

  const tudo = [];
  const falhou = [];
  for (const a of lista) {
    try {
      const s = await serie(a);
      tudo.push(...s);
      console.log(`  ${a}: ${s.length} pregões`);
    } catch (e) {
      falhou.push(a);
      console.error(`  ${a}: ${e.message}`);
    }
    await espera(300);
  }

  if (falhou.length) console.error(`NÃO VIERAM: ${falhou.join(", ")}`);
  if (!tudo.length) throw new Error("nenhuma série lida");

  // Uma chamada só: cada linha carrega seu data_cot, e a
  // gravar_oscilacao do banco10 arquiva cada uma na data certa.
  console.log(`gravando ${tudo.length} oscilações…`);
  await rpc("robo_gravar_oscilacao", { dados: tudo });

  // Fechar em ORDEM: a deriva de cada dia entra em cima da do anterior
  // e o índice acumulado depende do valor de ontem.
  const datas = [...new Set(tudo.map(x => x.data_cot))].sort();
  console.log(`fechando ${datas.length} pregões, de ${datas[0]} a ${datas[datas.length - 1]}`);

  let fechados = 0;
  for (const d of datas) {
    const n = await rpc("robo_fechar_dia", { d });
    if (n > 0) fechados++;
  }
  console.log(`pronto: ${fechados} pregões com carteira fechada`);
} catch (e) {
  console.error("falhou:", e.message);
  process.exit(1);
}

// ═══════════════════════════════════════════════════════════════════
// PARA APAGAR TUDO E VOLTAR AO LIMPO
//
//   delete from retorno_dia;
//   delete from oscilacao;
//   delete from peso_atual;
//   update posicao set valida_de = proximo_pregao();
//
// O QUE ISTO PROVA, E O QUE NÃO PROVA
//
// Prova: o cálculo de retorno, a deriva de peso, o índice acumulado, o
// Sharpe e a queda máxima contra mercado real. O hedge tem de aparecer
// com volatilidade bem menor que as outras, e o LFTS11 quase reto —
// eram os dois casos que o gerador aleatório distorcia.
//
// Não prova: o cron das 19h, nem se a data do pregão chega certa no dia
// a dia. Só o fechamento real de amanhã mostra isso.
// ═══════════════════════════════════════════════════════════════════
