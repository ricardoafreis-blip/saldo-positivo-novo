// ═══════════════════════════════════════════════════════════════════
// Saldo Positivo — robô diário
//
//   node robo/robo.mjs dia        busca oscilação, fecha o dia, manda e-mail
//   node robo/robo.mjs recuperar  só age se algum dia ficou sem fechar
//   node robo/robo.mjs universo   refaz a lista de papéis vá// ═══════════════════════════════════════════════════════════════════
// Saldo Positivo — robô diário
//
//   node robo/robo.mjs dia        busca oscilação, fecha o dia, manda e-mail
//   node robo/robo.mjs recuperar  só age se algum dia ficou sem fechar
//   node robo/robo.mjs universo   refaz a lista de papéis válidos
//
// Roda no GitHub Actions. Sem CORS, sem intermediário, sem navegador.
// Sem dependência: só o fetch nativo do Node 20.
// ═══════════════════════════════════════════════════════════════════

const URL_SB  = process.env.SUPABASE_URL;
const CHAVE   = process.env.SUPABASE_SERVICE_KEY;
const RESEND  = process.env.RESEND_API_KEY || "";
const DE      = process.env.EMAIL_DE || "";

if (!URL_SB || !CHAVE) { console.error("faltam SUPABASE_URL e SUPABASE_SERVICE_KEY"); process.exit(1); }

const modo = process.argv[2] || "dia";
const espera = ms => new Promise(r => setTimeout(r, ms));

// ─── Supabase por HTTP puro ────────────────────────────────────────
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

// ─── Fundamentus ───────────────────────────────────────────────────
// A página vem em iso-8859-1. Decodificar como utf-8 quebra o
// "Data últ cot" e o parser não acha mais nada.
const CABECALHO = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
  "Referer": "https://www.fundamentus.com.br/"
};

let JA_MOSTREI = false;

async function pagina(url) {
  const r = await fetch(url, { headers: CABECALHO, redirect: "follow" });
  const buf = await r.arrayBuffer();
  const html = new TextDecoder("iso-8859-1").decode(buf);

  // Diagnóstico: na primeira página que vier estranha, mostra o que
  // chegou de verdade. Sem isso ficamos adivinhando.
  if (!JA_MOSTREI && (!r.ok || !html.includes("Oscila"))) {
    JA_MOSTREI = true;
    console.log("─────── o que o Fundamentus devolveu ───────");
    console.log("status:", r.status, "| url final:", r.url, "| bytes:", buf.byteLength);
    console.log("tipo:", r.headers.get("content-type"));
    console.log(html.replace(/\s+/g, " ").slice(0, 700));
    console.log("────────────────────────────────────────────");
  }

  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return html;
}

const num = s => {
  if (s == null) return null;
  s = String(s).replace("%", "").replace(/\./g, "").replace(",", ".").trim();
  return s === "" || s === "-" ? null : (isFinite(parseFloat(s)) ? parseFloat(s) : null);
};

function campo(txt, rotulo, padrao) {
  const m = txt.match(new RegExp(rotulo + "\\s*\\|\\s*" + padrao));
  return m ? m[1] : null;
}

// ─── sondar ────────────────────────────────────────────────────────
// Descobre em UMA requisição qual foi o último pregão fechado, e se ele
// já está no banco. Antes das 10h o campo "Dia" do Fundamentus ainda é
// o do pregão anterior; depois das 10h ele vira parcial do dia em curso.
const HOJE_BR = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });

async function sondar() {
  const linhas = await sb("/rest/v1/peso_atual?select=ativo&limit=1");
  const ref = linhas[0]?.ativo || "PETR4";
  const html = await pagina(`https://www.fundamentus.com.br/detalhes.php?papel=${ref}`);
  const txt  = html.replace(/<[^>]+>/g, "|").replace(/\|+/g, "|");
  const dc   = campo(txt, "Data últ cot", "(\\d{2}/\\d{2}/\\d{4})");
  if (!dc) throw new Error(`não consegui ler a data em ${ref}`);
  return dc.split("/").reverse().join("-");
}

async function recuperar() {
  const data = await sondar();

  if (data === HOJE_BR()) {
    console.log(`última cotação é de hoje (${data}) — pregão em andamento, não é hora de fechar`);
    return;
  }
  // Confere retorno_dia, não oscilacao. Se a noite gravou as oscilações
  // mas o fechar_dia estourou depois, oscilacao teria a data e o dia
  // ficaria perdido do mesmo jeito. retorno_dia é o que prova que fechou.
  const ja = await sb(`/rest/v1/retorno_dia?data=eq.${data}&select=data&limit=1`);
  if (ja.length) {
    console.log(`${data} já está fechado — nada a recuperar`);
    return;
  }

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
  const osc = [], falhou = [];

  for (const ativo of lista) {
    try {
      const html = await pagina(`https://www.fundamentus.com.br/detalhes.php?papel=${ativo}`);
      const txt  = html.replace(/<[^>]+>/g, "|").replace(/\|+/g, "|");
      const dia  = num(campo(txt, "Dia", "([-\\d.,]+%?)"));
      const dc   = campo(txt, "Data últ cot", "(\\d{2}/\\d{2}/\\d{4})");
      if (dia === null || !dc) throw new Error("não achei Dia ou Data últ cot");
      osc.push({ ativo, valor: dia / 100, data_cot: dc.split("/").reverse().join("-") });
    } catch (e) {
      falhou.push(`${ativo} (${e.message})`);
    }
    await espera(350);
  }

  // O site antigo engolia falha em silêncio e dizia "pronto". Aqui não.
  if (falhou.length) console.error(`FALHARAM ${falhou.length}: ${falhou.join(", ")}`);

  const limite = Math.max(2, Math.ceil(lista.length * 0.1));
  if (falhou.length > limite) {
    throw new Error(`${falhou.length} de ${lista.length} falharam — passou do limite de ${limite}. ` +
                    `Não vou fechar o dia com dado furado.`);
  }
  if (!osc.length) throw new Error("nenhuma oscilação lida");

  await rpc("gravar_oscilacao", { dados: osc });
  const n = await rpc("fechar_dia");
  console.log(`gravadas ${osc.length} oscilações · ${n} carteiras fechadas`);
}

// ─── universo de papéis ────────────────────────────────────────────
async function atualizarUniverso() {
  const html = await pagina("https://www.fundamentus.com.br/resultado.php");
  const linhas = html.split(/<tr[^>]*>/i).slice(1);
  const lista = [];

  for (const ln of linhas) {
    const cel = ln.split(/<td[^>]*>/i).slice(1).map(c => c.replace(/<[^>]+>/g, "").trim());
    if (cel.length < 8) continue;
    const ativo = cel[0].toUpperCase();
    if (!/^[A-Z]{4}\d$/.test(ativo)) continue;
    const cot = num(cel[1]), liq = num(cel[8]);
    if (!cot || cot <= 0) continue;
    if (!liq || liq < 200000) continue;
    lista.push({ ativo, cotacao: cot, liquidez: liq });
  }

  if (lista.length < 150) {
    throw new Error(`só ${lista.length} papéis passaram no filtro — a página veio cortada. ` +
                    `Não vou regravar o universo com lista incompleta.`);
  }

  for (let i = 0; i < lista.length; i += 400) {
    await rpc("gravar_universo", { dados: lista.slice(i, i + 400) });
  }
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
  if (modo === "universo") {
    await atualizarUniverso();
  } else if (modo === "recuperar") {
    await recuperar();
  } else {
    await fecharDia();
    await mandarEmails();
  }
  console.log("fim");
} catch (e) {
  console.error("ERRO:", e.message);
  process.exit(1);
}
lidos
//
// Roda no GitHub Actions. Sem CORS, sem intermediário, sem navegador.
// Sem dependência: só o fetch nativo do Node 20.
// ═══════════════════════════════════════════════════════════════════

const URL_SB  = process.env.SUPABASE_URL;
const CHAVE   = process.env.SUPABASE_SERVICE_KEY;
const RESEND  = process.env.RESEND_API_KEY || "";
const DE      = process.env.EMAIL_DE || "";

if (!URL_SB || !CHAVE) { console.error("faltam SUPABASE_URL e SUPABASE_SERVICE_KEY"); process.exit(1); }

const modo = process.argv[2] || "dia";
const espera = ms => new Promise(r => setTimeout(r, ms));

// ─── Supabase por HTTP puro ────────────────────────────────────────
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

// ─── Fundamentus ───────────────────────────────────────────────────
// A página vem em iso-8859-1. Decodificar como utf-8 quebra o
// "Data últ cot" e o parser não acha mais nada.
async function pagina(url) {
  const r = await fetch(url, {
    headers: { "User-Agent": "Mozilla/5.0 (compatible; SaldoPositivo/1.0)" }
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const buf = await r.arrayBuffer();
  return new TextDecoder("iso-8859-1").decode(buf);
}

const num = s => {
  if (s == null) return null;
  s = String(s).replace("%", "").replace(/\./g, "").replace(",", ".").trim();
  return s === "" || s === "-" ? null : (isFinite(parseFloat(s)) ? parseFloat(s) : null);
};

function campo(txt, rotulo, padrao) {
  const m = txt.match(new RegExp(rotulo + "\\s*\\|\\s*" + padrao));
  return m ? m[1] : null;
}

// ─── sondar ────────────────────────────────────────────────────────
// Descobre em UMA requisição qual foi o último pregão fechado, e se ele
// já está no banco. Antes das 10h o campo "Dia" do Fundamentus ainda é
// o do pregão anterior; depois das 10h ele vira parcial do dia em curso.
const HOJE_BR = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });

async function sondar() {
  const linhas = await sb("/rest/v1/peso_atual?select=ativo&limit=1");
  const ref = linhas[0]?.ativo || "PETR4";
  const html = await pagina(`https://www.fundamentus.com.br/detalhes.php?papel=${ref}`);
  const txt  = html.replace(/<[^>]+>/g, "|").replace(/\|+/g, "|");
  const dc   = campo(txt, "Data últ cot", "(\\d{2}/\\d{2}/\\d{4})");
  if (!dc) throw new Error(`não consegui ler a data em ${ref}`);
  return dc.split("/").reverse().join("-");
}

async function recuperar() {
  const data = await sondar();

  if (data === HOJE_BR()) {
    console.log(`última cotação é de hoje (${data}) — pregão em andamento, não é hora de fechar`);
    return;
  }
  // Confere retorno_dia, não oscilacao. Se a noite gravou as oscilações
  // mas o fechar_dia estourou depois, oscilacao teria a data e o dia
  // ficaria perdido do mesmo jeito. retorno_dia é o que prova que fechou.
  const ja = await sb(`/rest/v1/retorno_dia?data=eq.${data}&select=data&limit=1`);
  if (ja.length) {
    console.log(`${data} já está fechado — nada a recuperar`);
    return;
  }

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
  const osc = [], falhou = [];

  for (const ativo of lista) {
    try {
      const html = await pagina(`https://www.fundamentus.com.br/detalhes.php?papel=${ativo}`);
      const txt  = html.replace(/<[^>]+>/g, "|").replace(/\|+/g, "|");
      const dia  = num(campo(txt, "Dia", "([-\\d.,]+%?)"));
      const dc   = campo(txt, "Data últ cot", "(\\d{2}/\\d{2}/\\d{4})");
      if (dia === null || !dc) throw new Error("não achei Dia ou Data últ cot");
      osc.push({ ativo, valor: dia / 100, data_cot: dc.split("/").reverse().join("-") });
    } catch (e) {
      falhou.push(`${ativo} (${e.message})`);
    }
    await espera(350);
  }

  // O site antigo engolia falha em silêncio e dizia "pronto". Aqui não.
  if (falhou.length) console.error(`FALHARAM ${falhou.length}: ${falhou.join(", ")}`);

  const limite = Math.max(2, Math.ceil(lista.length * 0.1));
  if (falhou.length > limite) {
    throw new Error(`${falhou.length} de ${lista.length} falharam — passou do limite de ${limite}. ` +
                    `Não vou fechar o dia com dado furado.`);
  }
  if (!osc.length) throw new Error("nenhuma oscilação lida");

  await rpc("gravar_oscilacao", { dados: osc });
  const n = await rpc("fechar_dia");
  console.log(`gravadas ${osc.length} oscilações · ${n} carteiras fechadas`);
}

// ─── universo de papéis ────────────────────────────────────────────
async function atualizarUniverso() {
  const html = await pagina("https://www.fundamentus.com.br/resultado.php");
  const linhas = html.split(/<tr[^>]*>/i).slice(1);
  const lista = [];

  for (const ln of linhas) {
    const cel = ln.split(/<td[^>]*>/i).slice(1).map(c => c.replace(/<[^>]+>/g, "").trim());
    if (cel.length < 8) continue;
    const ativo = cel[0].toUpperCase();
    if (!/^[A-Z]{4}\d$/.test(ativo)) continue;
    const cot = num(cel[1]), liq = num(cel[8]);
    if (!cot || cot <= 0) continue;
    if (!liq || liq < 200000) continue;
    lista.push({ ativo, cotacao: cot, liquidez: liq });
  }

  if (lista.length < 150) {
    throw new Error(`só ${lista.length} papéis passaram no filtro — a página veio cortada. ` +
                    `Não vou regravar o universo com lista incompleta.`);
  }

  for (let i = 0; i < lista.length; i += 400) {
    await rpc("gravar_universo", { dados: lista.slice(i, i + 400) });
  }
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
  if (modo === "universo") {
    await atualizarUniverso();
  } else if (modo === "recuperar") {
    await recuperar();
  } else {
    await fecharDia();
    await mandarEmails();
  }
  console.log("fim");
} catch (e) {
  console.error("ERRO:", e.message);
  process.exit(1);
}
