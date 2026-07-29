-- ═══════════════════════════════════════════════════════════════════
-- simular.sql — fabrica um mês de pregões para ver o motor funcionando
--
-- ⚠️ ISTO INVENTA DADO. Só rode enquanto o site é seu laboratório.
-- No dia em que houver gente de verdade, o bloco 0 apaga tudo e o
-- projeto volta a "sem histórico retroativo", que é a regra de verdade.
--
-- Depende de banco10, banco11 e banco12.
--
-- O que ele faz: recua as declarações para 1º de julho, gera variação
-- diária aleatória para cada papel em cada dia útil até hoje, e roda o
-- fechamento dia por dia, na ordem. Como o fechar_dia aplica a deriva
-- de peso a cada dia, o resultado no fim é uma carteira que andou de
-- verdade ao longo de um mês — não um número colado.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 0. ZERAR (rode isto quando quiser começar limpo) ──────────────
-- Deixado comentado de propósito. Descomente as quatro linhas para
-- apagar a simulação inteira sem tocar nas carteiras nem nos usuários.
--
-- delete from retorno_dia;
-- delete from oscilacao;
-- delete from peso_atual;
-- update posicao set valida_de = proximo_pregao();


-- ─── 1. as declarações passam a valer de 1º de julho ───────────────
-- Só assim o fechamento tem o que adotar nos dias simulados. O update
-- não dispara o gatilho, que é AFTER INSERT.

update posicao set valida_de = '2026-07-01' where valida_de >= '2026-07-01';

delete from peso_atual;
delete from retorno_dia;
delete from oscilacao;


-- ─── 2. um mês de variações inventadas ─────────────────────────────
-- Cada papel ganha um viés próprio pequeno e constante (via hashtext,
-- para ser o mesmo em todos os dias) somado a ruído diário de ±2,2%.
-- Sem o viés, todas as carteiras terminariam empatadas em zero e o
-- ranking não mostraria nada.

with dias as (
  select g::date as d
    from generate_series('2026-07-01'::date, hoje_br(), interval '1 day') g
   where extract(isodow from g) < 6            -- só dia útil
),
papeis as (select ativo from papeis_do_dia)
insert into oscilacao (ativo, data, valor, data_cot)
select p.ativo, d.d,
       ( (random() - 0.5) * 0.044                      -- ruído do dia
         + ((abs(hashtext(p.ativo)) % 9) - 4) * 0.0011 -- viés do papel
       )::real,
       d.d
  from dias d cross join papeis p
on conflict (ativo, data) do update
   set valor = excluded.valor, data_cot = excluded.data_cot;


-- ─── 3. fechar dia por dia, na ordem ───────────────────────────────
-- Na ordem importa: a deriva de cada dia entra em cima da do anterior,
-- e o índice acumulado depende do valor de ontem. Rodar fora de ordem
-- daria número errado sem dar erro.

do $$
declare d date; n int; total int := 0;
begin
  for d in select distinct data from oscilacao order by data loop
    n := robo_fechar_dia(d);
    total := total + 1;
  end loop;
  raise notice '% pregões fechados', total;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- CONFERIR — e é aqui que se vê se o motor está certo
--
-- 1. Quantos dias cada carteira tem, e onde chegou:
--
--    select c.nome, c.classe, count(*) as dias,
--           round((max(r.indice)::numeric/100 - 1) * 100, 2) as pico_pct,
--           round(((select indice from retorno_dia x
--                    where x.carteira_id = c.id order by data desc limit 1)::numeric/100 - 1)*100, 2) as acum_pct
--    from carteira c join retorno_dia r on r.carteira_id = c.id
--    group by c.id, c.nome, c.classe order by 5 desc;
--
-- 2. O peso andou? Tem que estar diferente do declarado, e a soma da
--    carteira comprada tem que continuar perto de 100:
--
--    select carteira_id, round(sum(abs(peso))::numeric,2) as bruta,
--           round(sum(peso)::numeric,2) as liquida, count(*) as papeis
--    from peso_atual group by 1 order by 1;
--
-- 3. O Ibovespa virou índice:
--
--    select data, round(indice::numeric,2) from indice_referencia
--    order by data desc limit 5;
--
-- 4. Carteira contra Ibovespa, na janela de cada uma:
--
--    select carteira_id, dias,
--           round(carteira*100,2) as cart, round(referencia*100,2) as ibov,
--           round(excedente*100,2) as excedente
--    from carteira_contra_referencia order by excedente desc;
--
-- 5. E o teste que mais importa: abra o site. Deve haver curva, Sharpe
--    com número em vez de travessão, queda máxima negativa de verdade,
--    e o ranking por classe com ordem diferente em cada uma.
--
--
-- O QUE ESTA SIMULAÇÃO NÃO TESTA
--
-- Nada da parte de fora: não prova que o Yahoo responde, nem que o
-- Actions roda, nem que a data do pregão vem certa da fonte. Isso só o
-- fechamento real de amanhã às 19h mostra. Aqui é o motor de cálculo,
-- que é a metade que estava sem prova nenhuma.
--
-- A alavancada tende a liderar e a vendida a afundar, porque o viés
-- aleatório é positivo na média. Isso é artefato do gerador, não
-- descoberta sobre estratégia — não tire conclusão do resultado.
-- ═══════════════════════════════════════════════════════════════════
