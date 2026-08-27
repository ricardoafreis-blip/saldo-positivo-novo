// Saldo Positivo — robô diário
//
//   node robo/robo.mjs dia        apura o pregão e manda os e-mails
//   node robo/robo.mjs conferir    só olha e relata, não muda nada
//
// ═══════════════════════════════════════════════════════════════════
//  ESTE ROBÔ NÃO BUSCA COTAÇÃO. Quem traz preço é o MT5.
//
//  Yahoo, brapi e bolsai foram removidos em 02/08/2026. O motivo:
//  o meta.previousClose do Yahoo vinha UNDEFINED e o robô calculava a
//  variação em cima disso — todas as oscilações até então estavam
//  erradas. Pior, a mesma URL devolvia 10 candles às 20h30 e 9 às
//  20h41. E mesmo com os candles certos, o fechamento dele divergia
//  do oficial da B3: em 31/07 o AUAU3 fechou 3,53 e o Yahoo deu 3,49.
//
//  Agora o caminho é: MT5 → tabela fechamento → oscilacao (derivada
//  no banco, um pregão sobre o anterior) → este robô só apura.
//
//  ORDEM DE TODO DIA:
//    1. rodar o script SaldoPositivo_Exportar no MT5
//    2. rodar este robô (Actions → Fechar o dia)
//  Se inverter, ele avisa que não há cotação nova e não fecha nada.
// ═══════════════════════════════════════════════════════════════════

const URL_SB = process.env.SUPABASE_URL;
const CHAVE  = process.env.SUPABASE_SERVICE_KEY;
const RESEND = process.env.RESEND_API_KEY || "";
const DE     = process.env.EMAIL_DE || "";

if (!URL_SB || !CHAVE) { console.error("faltam SUPABASE_URL e SUPABASE_SERVICE_KEY"); process.exit(1); }

const modo = process.argv[2] || "dia";
const espera = ms => new Promise(r => setTimeout(r, ms));

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

// ─── o que o banco tem ─────────────────────────────────────────────
// Devolve o quadro do dia sem mudar nada: qual o último pregão com
// cotação, se ele já foi apurado, e se falta papel de alguma carteira.
async function situacao() {
  const ult = await sb("/rest/v1/oscilacao?select=data&order=data.desc&limit=1");
  if (!ult.length) return { erro: "não há nenhuma oscilação no banco. Rode o MT5 primeiro." };
  const dia = ult[0].data;

  const fechado = await sb(`/rest/v1/retorno_dia?data=eq.${dia}&select=data&limit=1`);

  const papeis = await sb("/rest/v1/papeis_do_dia?select=ativo");
  const lista = [...new Set(papeis.map(x => x.ativo))];

  let comCotacao = [];
  if (lista.length) {
    const alvo = lista.map(encodeURIComponent).join(",");
    const osc = await sb(`/rest/v1/oscilacao?data=eq.${dia}&ativo=in.(${alvo})&select=ativo`);
    comCotacao = osc.map(x => x.ativo);
  }
  const faltando = lista.filter(a => !comCotacao.includes(a));

  return { dia, jaFechado: fechado.length > 0, papeis: lista.length,
           comCotacao: comCotacao.length, faltando };
}

function relatar(s) {
  console.log(`último pregão com cotação: ${s.dia}`);
  console.log(`papéis em carteira: ${s.papeis} · com cotação nesse dia: ${s.comCotacao}`);
  if (s.faltando.length)
    console.error(`SEM COTAÇÃO (${s.faltando.length}): ${s.faltando.join(", ")}`);
  console.log(s.jaFechado ? "esse pregão JÁ está apurado" : "esse pregão ainda não foi apurado");
}

// ─── apurar ────────────────────────────────────────────────────────
async function fecharDia() {
  const s = await situacao();
  if (s.erro) throw new Error(s.erro);
  relatar(s);

  if (s.papeis === 0) {
    console.log("nenhuma carteira com posição em vigor — nada a apurar");
    return;
  }

  // Papel sem cotação entra no cálculo como oscilação ZERO e a carteira
  // rende menos do que deveria, sem erro nenhum aparecer. Por isso o
  // limite: melhor não apurar do que apurar torto e ninguém perceber.
  const limite = Math.max(1, Math.ceil(s.papeis * 0.2));
  if (s.faltando.length > limite) {
    throw new Error(
      `${s.faltando.length} de ${s.papeis} papéis sem cotação em ${s.dia} — passou do ` +
      `limite de ${limite}. Rode o MT5 e confira se esses papéis estão no Observador ` +
      `de Mercado. Não vou apurar com dado furado.`);
  }

  if (s.jaFechado) {
    console.log(`${s.dia} já estava apurado — nada a fazer`);
    return;
  }

  const n = await rpc("robo_fechar_dia");
  console.log(`${n} carteiras apuradas em ${s.dia}`);
}

// ─── esvaziar a fila de e-mail ─────────────────────────────────────
async function mandarEmails() {
  if (!RESEND || !DE) { console.log("sem RESEND_API_KEY ou EMAIL_DE — fila não foi tocada"); return; }

  const fila = await sb("/rest/v1/fila_email?enviado_em=is.null&tentativas=lt.5" +
                        "&order=criado_em.asc&limit=50");
  if (!fila.length) { console.log("fila de e-mail vazia"); return; }

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
  if (modo === "conferir") {
    const s = await situacao();
    if (s.erro) { console.error(s.erro); process.exit(1); }
    relatar(s);
  } else {
    await fecharDia();
    await mandarEmails();
  }
  console.log("fim");
} catch (e) {
  console.error("ERRO:", e.message);
  process.exit(1);
}
