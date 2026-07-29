
-- ═══════════════════════════════════════════════════════════════════
-- banco9.sql — a declaração pendente passa a valer no pregão certo
--
-- Depende do banco8.sql (hoje_br, proximo_pregao, declarar).
--
-- O banco8 fez metade: declarar() passou a gravar valida_de = próximo
-- pregão. Mas o gatilho tg_declarar carregava max(valida_de) sem
-- comparar com hoje, então a declaração futura entrava em vigor no
-- mesmo instante e o furo continuava aberto.
--
-- Por que não basta reler posicao a cada fechamento: o peso em
-- peso_atual é o declarado MAIS toda a deriva diária acumulada
-- (fechar_dia, "o peso anda"). Reler apagaria a deriva toda noite.
-- Daí a coluna marco: ela diz qual declaração está carregada, e o
-- fechamento só recarrega quando aparece uma mais nova.
--
-- Ordem dos acontecimentos depois deste arquivo:
--   dia D, 10h   pessoa declara      → posicao.valida_de = D+1
--                                      peso_atual intocado
--   dia D, 19h   fechar_dia(D)       → adota? D+1 <= D é falso, não.
--                                      fecha D com a carteira antiga
--   dia D+1, 19h fechar_dia(D+1)     → adota (D+1 <= D+1), e SÓ ENTÃO
--                                      calcula o retorno de D+1
--
-- A adoção vem antes do cálculo de propósito: quem declara no sábado
-- (valida_de = segunda) entra no fechamento de segunda, não no de
-- terça. Feriado idem — não há fechamento no feriado, e o pregão
-- seguinte adota porque a data pendente é menor ou igual à dele.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. a coluna que faltava ───────────────────────────────────────
-- Aditiva. Nenhuma linha existente muda de valor.

alter table peso_atual add column if not exists marco date;


-- ─── 2. backfill ───────────────────────────────────────────────────
-- Marca o que já está carregado. O gatilho antigo usava max(valida_de)
-- sem filtro nenhum, então é esse mesmo valor que descreve a verdade
-- de hoje. Sem este passo, o primeiro fechamento acharia que toda
-- carteira tem declaração nova e apagaria a deriva de todas.

update peso_atual pa
   set marco = (select max(p.valida_de) from posicao p
                 where p.carteira_id = pa.carteira_id)
 where pa.marco is null;


-- ─── 3. gatilho: declaração futura não mexe em nada ────────────────

create or replace function public.ao_declarar_posicao()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_marco date;
begin
  -- Declaração para o próximo pregão fica pendente em posicao.
  -- Quem adota é o fechar_dia. Mexer aqui destruiria a deriva do dia.
  if new.valida_de > hoje_br() then
    return new;
  end if;

  -- Caminho de exceção: inserção com data de hoje ou anterior
  -- (correção manual, carga de admin). Comportamento antigo, agora
  -- sem enxergar o futuro.
  select max(valida_de) into v_marco
    from posicao
   where carteira_id = new.carteira_id and valida_de <= hoje_br();

  if v_marco is null then
    return new;
  end if;

  delete from peso_atual where carteira_id = new.carteira_id;

  insert into peso_atual (carteira_id, ativo, peso, marco)
  select carteira_id, ativo, sum(peso), v_marco
    from posicao
   where carteira_id = new.carteira_id and valida_de = v_marco
   group by carteira_id, ativo;

  perform recalcular_exposicao(new.carteira_id);
  return new;
end $function$;


-- ─── 4. fechar_dia: adota a pendente antes de calcular ─────────────
-- Igual à versão anterior, com um bloco novo no topo do laço.
-- O resto — CDI, retorno, índice, deriva — está intocado.

create or replace function public.fechar_dia(d date default current_date)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c        record;
  cdi_dia  real := power(1.105, 1.0/252) - 1;
  ret      real;
  l real; s real; caixa real; rende real;
  idx_ant  real;
  n        int := 0;
  m_novo   date;
  m_atual  date;
begin
  if not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'só admin';
  end if;

  for c in select id from carteira where ativa loop

    -- ── adoção da declaração pendente ──
    -- Antes do cálculo: a declaração que passou a valer hoje precisa
    -- valer para o retorno de hoje. Só recarrega se houver marco mais
    -- novo — senão a deriva acumulada seria apagada.
    select max(valida_de) into m_novo
      from posicao where carteira_id = c.id and valida_de <= d;
    select max(marco) into m_atual
      from peso_atual where carteira_id = c.id;

    if m_novo is not null and (m_atual is null or m_novo > m_atual) then
      delete from peso_atual where carteira_id = c.id;

      insert into peso_atual (carteira_id, ativo, peso, marco)
      select carteira_id, ativo, sum(peso), m_novo
        from posicao
       where carteira_id = c.id and valida_de = m_novo
       group by carteira_id, ativo;

      perform recalcular_exposicao(c.id);
    end if;

    if not exists (select 1 from peso_atual where carteira_id = c.id) then
      continue;
    end if;

    -- exposição de hoje, antes de o mercado mexer
    select coalesce(sum(peso) filter (where peso > 0), 0),
          -coalesce(sum(peso) filter (where peso < 0), 0)
      into l, s from peso_atual where carteira_id = c.id;
    caixa := 100 - (l - s);
    rende := least(caixa, 100.0);

    -- retorno do dia
    select coalesce(sum((pa.peso/100.0) * coalesce(o.valor, 0)), 0)
      into ret
      from peso_atual pa
      left join oscilacao o on o.ativo = pa.ativo and o.data = d
     where pa.carteira_id = c.id;
    ret := ret + (rende/100.0) * cdi_dia;

    -- índice acumulado, base 100
    select indice into idx_ant from retorno_dia
     where carteira_id = c.id and data < d order by data desc limit 1;
    idx_ant := coalesce(idx_ant, 100.0);

    insert into retorno_dia (carteira_id, data, retorno, indice)
    values (c.id, d, ret, idx_ant * (1 + ret))
    on conflict (carteira_id, data) do update
       set retorno = excluded.retorno, indice = excluded.indice;

    -- o peso anda: quem subiu mais que a carteira ganha espaço
    update peso_atual pa
       set peso = pa.peso * (1 + coalesce(o.valor, 0)) / (1 + ret)
      from (select ativo, valor from oscilacao where data = d) o
     where pa.carteira_id = c.id and pa.ativo = o.ativo and (1 + ret) <> 0;

    perform recalcular_exposicao_atual(c.id);
    n := n + 1;
  end loop;
  return n;
end $function$;


-- ═══════════════════════════════════════════════════════════════════
-- CONFERIR DEPOIS DE RODAR
--
-- 1. Toda carteira com posição tem que ter marco preenchido:
--
--    select count(*) filter (where marco is null) as sem_marco,
--           count(*) as total
--      from peso_atual;
--
--    sem_marco tem que ser 0.
--
-- 2. Alguma carteira já está com declaração futura carregada?
--    (só acontece se alguém declarou hoje entre o banco8 e o banco9 —
--    o gatilho antigo teria adotado na hora)
--
--    select carteira_id, marco from peso_atual
--     where marco > hoje_br() group by carteira_id, marco;
--
--    Se vier vazio, está tudo limpo. Se vier alguma linha, essa
--    carteira vai fechar hoje com a posição de amanhã — é o furo
--    antigo acontecendo uma última vez. Avise antes das 19h.
--
-- 3. Teste de mesa, numa carteira de teste:
--    declarar → conferir que peso_atual NÃO mudou e que apareceu
--    linha nova em posicao com valida_de futura.
--
--    select ativo, peso, valida_de from posicao
--     where carteira_id = <id> order by valida_de desc, ativo;
--    select ativo, peso, marco from peso_atual where carteira_id = <id>;
--
-- PENDENTE NA TELA (index.html, não é banco):
-- carteira nova, cuja primeira declaração é para o próximo pregão,
-- fica com peso_atual vazio até o fechamento. O site vai mostrar ela
-- sem posição. Precisa dizer "vale a partir do próximo pregão" em vez
-- de parecer defeito.
-- ═══════════════════════════════════════════════════════════════════
