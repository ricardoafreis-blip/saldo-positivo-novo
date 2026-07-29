
-- ═══════════════════════════════════════════════════════════════════
-- banco8.sql — declaração vale a partir do próximo pregão
--
-- ⚠️ RASCUNHO. NÃO RODAR AINDA.
--
-- Falta conferir a definição de peso_atual. Se ela pega o maior
-- valida_de de cada carteira SEM comparar com a data de hoje, este
-- arquivo não resolve nada e ainda pode deixar a carteira um dia sem
-- posição — e o fechar_dia fecharia vazio. Rodar só depois disso.
--
-- Problema que este arquivo conserta:
--   declarar() gravava valida_de = current_date. Quem declarava às
--   17h30, já sabendo que o papel subiu 8%, entrava no cálculo do dia
--   que acabou de ver acontecer. Horário de corte não resolve — quem
--   declara às 15h já viu cinco horas de pregão.
--
-- Regra nova: declaração vale a partir do próximo pregão, sempre.
-- ═══════════════════════════════════════════════════════════════════


-- ─── data no fuso de São Paulo ─────────────────────────────────────
-- O banco do Supabase roda em UTC. Depois das 21h BRT, current_date
-- já é o dia seguinte para o Postgres e não para a bolsa. Mesma
-- definição que o HOJE_BR() do robô usa.

create or replace function public.hoje_br()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Sao_Paulo')::date;
$$;


-- ─── próximo pregão ────────────────────────────────────────────────
-- Só pula fim de semana. Feriado não precisa de tabela: se valida_de
-- cair num feriado, não há pregão naquele dia, o robô não fecha nada,
-- e a posição entra em vigor no pregão seguinte do mesmo jeito.
-- isodow: segunda = 1 ... domingo = 7.

create or replace function public.proximo_pregao(a_partir date default null)
returns date
language sql
stable
as $$
  select case extract(isodow from coalesce(a_partir, hoje_br()))
           when 5 then coalesce(a_partir, hoje_br()) + 3   -- sexta  → segunda
           when 6 then coalesce(a_partir, hoje_br()) + 2   -- sábado → segunda
           when 7 then coalesce(a_partir, hoje_br()) + 1   -- domingo→ segunda
           else        coalesce(a_partir, hoje_br()) + 1
         end;
$$;


-- ─── declarar ──────────────────────────────────────────────────────
-- Mudou em relação à versão anterior:
--   1. valida_de = proximo_pregao(), não current_date
--   2. o delete apaga a declaração PENDENTE (a do próximo pregão),
--      não a que está em vigor hoje — senão a carteira ficaria sem
--      posição entre a declaração e o pregão seguinte
--   3. current_date → hoje_br() no registro da nota
--   4. o cid voltou para o select do insert (conferir contra o
--      original: a cópia que eu recebi estava sem ele)

create or replace function public.declarar(cid bigint, pesos jsonb, nota_txt text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n int := 0;
  bruta real;
  v_de date := proximo_pregao();
begin
  if not exists (select 1 from carteira
                  where id = cid and usuario_id = auth.uid() and ativa) then
    raise exception 'essa carteira não é sua';
  end if;

  select coalesce(sum(abs((x->>'peso')::real)), 0) into bruta
    from jsonb_array_elements(pesos) x;

  if bruta > 200.01 then
    raise exception 'exposição bruta de % por cento passa do teto de 200', round(bruta);
  end if;

  -- substitui a declaração pendente; o passado e o que vale hoje ficam intocados
  delete from posicao where carteira_id = cid and valida_de = v_de;

  insert into posicao (carteira_id, ativo, peso, valida_de)
  select cid, upper(x->>'ativo'), (x->>'peso')::real, v_de
    from jsonb_array_elements(pesos) x
   where (x->>'peso')::real <> 0;

  get diagnostics n = row_count;

  if nota_txt is not null and length(trim(nota_txt)) > 0 then
    insert into nota (carteira_id, data, texto) values (cid, hoje_br(), nota_txt);
  end if;

  return n;
end $function$;


-- ═══════════════════════════════════════════════════════════════════
-- DEPOIS DE RODAR, CONFERIR:
--
--   select proximo_pregao();          -- deve dar o próximo dia útil
--   select hoje_br();                 -- deve bater com o calendário daqui
--
-- E declarar numa carteira de teste, depois:
--   select ativo, peso, valida_de from posicao
--    where carteira_id = <id> order by valida_de desc;
--
-- A linha nova tem que estar com data futura, e a anterior tem que
-- continuar lá.
--
-- FICA PENDENTE NA TELA: o index.html não avisa que a declaração só
-- vale amanhã. Sem isso a pessoa declara, olha o dia e acha que
-- quebrou. É texto no front, não no banco.
--
-- DECISÃO EM ABERTO: a nota fica com a data em que foi escrita
-- (hoje_br), enquanto a posição fica com a data em que passa a valer.
-- No histórico as duas aparecem em dias diferentes. Alinhar as duas
-- pode esbarrar em chave primária de (carteira_id, data) se a pessoa
-- declarar duas vezes no mesmo dia — por isso ficou como está.
-- ═══════════════════════════════════════════════════════════════════
