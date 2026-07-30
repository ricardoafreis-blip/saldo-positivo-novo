// ═══════════════════════════════════════════════════════════════════
// intradia.mjs — a foto do pregão, de meia em meia hora
//
//   node robo/intradia.mjs
//
// Roda pelo Actions durante o pregão e grava em cotacao_viva. O site
// lê de lá. NUNCA escreve em oscilacao: o apurado continua saindo de
// uma fonte só, uma vez por dia, no fechamento.
//
// SÓ USA A BRAPI, de propósito. Ela traz 20 papéis por chamada, então
// uma rodada de 25 papéis custa 2 requisições — umas 34 por dia, ~700
// por mês, folgado nos 15.000. O Yahoo é um papel por chamada: a mesma
// rodada custaria 25, daria 850 por dia, e ele devolve 429 para IP de
// datacenter muito antes disso. Sem brapi, esta rotina simplesmente
// não roda, e o site mostra só o fechado.
// ═══════════════════════════════════════════════════════════════════

const URL_SB = process.env.SUPABASE_URL;
const CHAVE  = process.env.SUPABASE_SERVICE_KEY;
const BRAPI  = process.env.BRAPI_TOKEN;

if (!URL_SB || !CHAVE) { console.error("faltou SUPABASE_URL ou SUPABASE_SERVICE_KEY"); process.exit(1); }
if (!BRAPI) { console.log("sem BRAPI_TOKEN — intradiário não roda"); process.exit(0); }

const espera = ms => new Promise(r => setTimeout(r, ms));

async function sb(caminho, opcoes = {}) {
  const r = await fetch(`${URL_SB}${caminho}`, {
    ...opcoes,
    headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`,
               "Content-Type": "application/json", ...(opcoes.headers || {}) },
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`supabase ${r.status}: ${txt.slice(0, 200)}`);
  return txt ? JSON.parse(txt) : null;
}
const rpc = (fn, corpo) =>
  sb(`/rest/v1/rpc/${fn}`, { method: "POST", body: JSON.stringify(corpo || {}) });


// ─── busca adaptativa ──────────────────────────────────────────────
// A brapi devolve 400 para o LOTE INTEIRO quando algo nele não serve —
// pode ser um ticker que não existe mais, ou o próprio tamanho do lote
// no plano gratuito. Em vez de adivinhar o teto, o robô descobre:
// começa em 20 e vai cortando pela metade até passar. Um papel que
// falhe sozinho fica de fora sozinho, sem derrubar os outros.
let tamanhoOk = 20;

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

const pedacos = (l, n) => { const s = []; for (let i = 0; i < l.length; i += n) s.push(l.slice(i, i + n)); return s; };

try {
  const linhas = await sb("/rest/v1/papeis_do_dia?select=ativo");
  const lista = [...new Set(linhas.map(x => x.ativo))];
  if (!lista.length) { console.log("nenhum papel em jogo — nada a fazer"); process.exit(0); }

  const viva = [];
  const guardar = x => {
    const pct = x.regularMarketChangePercent;
    if (pct == null) return;
    viva.push({ ativo: x.symbol, valor: pct / 100, preco: x.regularMarketPrice ?? null });
  };

  // Índice vai separado dos papéis: são catálogos diferentes na brapi e
  // misturar aumenta a chance de o lote inteiro ser recusado.
  await buscarBrapi(lista.filter(a => !a.startsWith("^")), guardar);
  await buscarBrapi(lista.filter(a =>  a.startsWith("^")), guardar);

  if (!viva.length) { console.log("nada veio da brapi — cotacao_viva intocada"); process.exit(0); }

  const n = await rpc("robo_gravar_viva", { dados: viva });
  console.log(`${n} de ${lista.length} papéis atualizados`);

  const faltou = lista.filter(a => !viva.some(v => v.ativo === a));
  if (faltou.length) console.log(`sem cotação: ${faltou.join(", ")}`);
} catch (e) {
  console.error("falhou:", e.message);
  process.exit(1);
}
