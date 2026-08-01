// Confere se os candles do Yahoo batem com o pregão. Roda sozinho pelo
// Actions: Actions → Testar Yahoo → Run workflow.
const alvos = process.argv.slice(2);
const papeis = alvos.length ? alvos : ["AUAU3", "ALLD3", "PETR4"];
const diaBR = ms => new Date(ms).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });

for (const a of papeis) {
  try {
    const r = await fetch(
      `https://query1.finance.yahoo.com/v8/finance/chart/${a}.SA?range=10d&interval=1d`,
      { headers: { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" } });
    if (!r.ok) { console.log(`${a}: yahoo ${r.status}`); continue; }
    const res = (await r.json()).chart.result[0];

    const ts = res.timestamp || [];
    const cl = res.indicators?.quote?.[0]?.close || [];
    const dias = ts.map((t, i) => ({ dia: diaBR(t * 1000), fech: cl[i] }))
                   .filter(x => x.fech != null);

    console.log(`\n═══ ${a} ═══`);
    console.log(`previousClose do meta: ${res.meta.previousClose}`);
    dias.forEach(d => console.log(`  ${d.dia}  ${d.fech.toFixed(2)}`));

    if (dias.length >= 2) {
      const h = dias[dias.length - 1], o = dias[dias.length - 2];
      const porCandle = (h.fech / o.fech - 1) * 100;
      const porMeta   = (h.fech / res.meta.previousClose - 1) * 100;
      console.log(`  pelos candles: ${porCandle.toFixed(3)}%   (${o.fech} → ${h.fech})`);
      console.log(`  pelo meta:     ${porMeta.toFixed(3)}%`);
    }
  } catch (e) { console.log(`${a}: ${e.message}`); }
}
