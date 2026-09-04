--
-- PostgreSQL database dump
--

\restrict Uk0EYjE4FurP1Rc7Qn7Q1gsJxMOOM4HObR28ZcVffdHreVVFvQXOp8pHSA7aBvl

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Ubuntu 17.11-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: abrir_ciclo(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.abrir_ciclo(p_ciclo bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r        record;
  v_hash   text;
  v_dono   bigint;
  n_ok     int := 0;
  n_clone  int := 0;
  v_clones text := '';
begin
  for r in
    select i.time_id,
           array_agg(m.carteira_id order by m.carteira_id) as carteiras,
           count(*) as quantos
      from time_inscricao i
      join time_membro m on m.time_id = i.time_id and m.situacao = 'ativo'
      join carteira ca   on ca.id = m.carteira_id
                        and ca.ativa and ca.classe = 'diversificada'
     where i.ciclo_id = p_ciclo
     group by i.time_id
     order by i.time_id
  loop
    if r.quantos < 5 then
      continue;                          -- sem elenco mínimo, não entra
    end if;

    v_hash := md5(array_to_string(r.carteiras, ','));

    select i.time_id into v_dono from time_inscricao i
     where i.ciclo_id = p_ciclo and i.elenco_hash = v_hash
       and i.time_id <> r.time_id limit 1;

    if v_dono is not null then
      n_clone  := n_clone + 1;
      v_clones := v_clones || format(' · time %s repete o elenco do time %s',
                                     r.time_id, v_dono);
      continue;
    end if;

    update time_inscricao set elenco_hash = v_hash
     where ciclo_id = p_ciclo and time_id = r.time_id;

    insert into time_ciclo_membro (ciclo_id, time_id, usuario_id, carteira_id)
    select p_ciclo, m.time_id, m.usuario_id, m.carteira_id
      from time_membro m
     where m.time_id = r.time_id and m.situacao = 'ativo'
       and m.carteira_id is not null
    on conflict do nothing;

    n_ok := n_ok + 1;
  end loop;

  update ciclo set situacao = 'aberto' where id = p_ciclo;
  return format('%s time(s) no ciclo, %s recusado(s) por elenco repetido%s',
                n_ok, n_clone, v_clones);
end;
$$;


--
-- Name: abrir_copa(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.abrir_copa(p_data date DEFAULT NULL::date) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  d    date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  d2   date;
  v_id bigint;
begin
  if extract(dow from d) in (0, 6) then return null; end if;

  insert into copa (data) values (d)
  on conflict (data) do nothing returning id into v_id;
  if v_id is null then select id into v_id from copa where data = d; end if;

  -- a do próximo pregão, para a inscrição já estar aberta na véspera
  d2 := d + 1;
  while extract(dow from d2) in (0, 6) loop d2 := d2 + 1; end loop;
  insert into copa (data) values (d2) on conflict (data) do nothing;

  return v_id;
end;
$$;


--
-- Name: abrir_rodadas(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.abrir_rodadas(p_data date DEFAULT NULL::date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  d      date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  d2     date;
  n      int := 0;
begin
  -- alem de hoje, o proximo pregao: assim da para votar hoje as rodadas de
  -- amanha. O voto de cada uma so fecha uma hora antes dela, entao todas
  -- ficam abertas desde ja.
  if extract(dow from d) not in (0, 6) then
    n := n + abrir_um_dia(d);
  end if;
  d2 := d + 1;
  while extract(dow from d2) in (0, 6) loop d2 := d2 + 1; end loop;
  n := n + abrir_um_dia(d2);
  return n;
end;
$$;


--
-- Name: abrir_um_dia(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.abrir_um_dia(d date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  h      int;
  n      int := 0;
  v_id   bigint;
  v_corte real;
  j      text;
begin

  -- O alvo da PETR4 é o giro médio por hora dela no último pregão que
  -- tem foto. Fica sabido antes de o jogador votar, e acompanha o
  -- mercado sem eu precisar arbitrar um número fixo.
  select round(avg(m.giro_hora)::numeric / 1e6) * 1e6 into v_corte
    from (select max(data) as d0 from cotacao_hora where data < d) u
    cross join lateral (
      select (movimento_da_hora(u.d0, hh)).* from generate_series(11,17) hh
    ) m
   where m.ativo = 'PETR4' and m.giro_hora > 0;

  for h in 11..16 loop
    insert into rodada (data, hora, abre_em, fecha_em, corte_petr)
    values (d, h,
            ((d + make_interval(hours => h - 1)) at time zone 'America/Sao_Paulo'),
            ((d + make_interval(hours => h))     at time zone 'America/Sao_Paulo'),
            v_corte)
    on conflict (data, hora) do nothing
    returning id into v_id;

    if v_id is not null then
      n := n + 1;
      -- três sorteios independentes, três papéis cada. Mico e blue chip
      -- concorrem igual; a única exigência é ter cotação recente, senão
      -- o papel não teria foto na hora e a rodada ficaria sem gabarito.
      foreach j in array array['sobe','cai','volume'] loop
        insert into rodada_papel (rodada_id, jogo, ativo)
        select v_id, j, u.ativo
          from (select ativo from universo
                 where tipo = 'acao' and liquidez > 0
                 order by random() limit 3) u;
      end loop;
    end if;
    v_id := null;
  end loop;

  return n;
end;
$$;


--
-- Name: admin_apagar_carteira(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_apagar_carteira(cid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  update carteira set ativa = false where id = cid;
  if not found then raise exception 'carteira não encontrada'; end if;
end $$;


--
-- Name: admin_apagar_lead(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_apagar_lead(lid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  delete from lead where id = lid;
  if not found then raise exception 'lead não encontrado'; end if;
end $$;


--
-- Name: admin_bloquear(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_bloquear(quem uuid, valor boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin()  then raise exception 'sem permissão'; end if;
  if quem = auth.uid() then raise exception 'não dá para bloquear a própria conta'; end if;
  update perfil set bloqueado = valor where id = quem;
  if not found then raise exception 'conta não encontrada'; end if;
end $$;


--
-- Name: admin_contas(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_contas() RETURNS TABLE(id uuid, apelido text, email text, identidade text, assinante boolean, admin boolean, bloqueado boolean, criado_em timestamp with time zone, n_carteiras bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  return query
    select p.id, p.apelido, u.email::text, p.identidade,
           p.assinante, p.admin, p.bloqueado, p.criado_em,
           (select count(*) from carteira c
             where c.usuario_id = p.id and c.ativa) as n_carteiras
      from perfil p
      left join auth.users u on u.id = p.id
     order by p.criado_em desc;
end $$;


--
-- Name: admin_editar_lead(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_editar_lead(lid bigint, dados jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  update lead set
    nome_completo = coalesce(dados->>'nome_completo', nome_completo),
    email         = coalesce(dados->>'email',         email),
    telefone      = coalesce(dados->>'telefone',      telefone),
    cpf           = coalesce(dados->>'cpf',           cpf),
    cep           = coalesce(dados->>'cep',           cep),
    logradouro    = coalesce(dados->>'logradouro',    logradouro),
    numero        = coalesce(dados->>'numero',        numero),
    complemento   = coalesce(dados->>'complemento',   complemento),
    bairro        = coalesce(dados->>'bairro',        bairro),
    cidade        = coalesce(dados->>'cidade',        cidade),
    uf            = coalesce(dados->>'uf',            uf),
    observacao    = coalesce(dados->>'observacao',    observacao)
  where id = lid;
  if not found then raise exception 'lead não encontrado'; end if;
end $$;


--
-- Name: admin_excluir_conta(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_excluir_conta(quem uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not exists (select 1 from perfil where id = auth.uid() and admin) then
    raise exception 'só administrador';
  end if;
  if quem = auth.uid() then
    raise exception 'não dá para excluir a própria conta por aqui';
  end if;
  delete from lead   where usuario_id = quem;
  delete from perfil where id = quem;
  delete from auth.users where id = quem;
end $$;


--
-- Name: cpf_valido(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cpf_valido(t text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
declare d text; s int; r int; i int;
begin
  d := regexp_replace(coalesce(t,''), '\D', '', 'g');
  if length(d) <> 11 then return false; end if;
  if d ~ '^(\d)\1{10}$'  then return false; end if;

  s := 0;
  for i in 1..9 loop s := s + substr(d,i,1)::int * (11 - i); end loop;
  r := s % 11;
  if (case when r < 2 then 0 else 11 - r end) <> substr(d,10,1)::int
    then return false; end if;

  s := 0;
  for i in 1..10 loop s := s + substr(d,i,1)::int * (12 - i); end loop;
  r := s % 11;
  return (case when r < 2 then 0 else 11 - r end) = substr(d,11,1)::int;
end $_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: lead; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead (
    id bigint NOT NULL,
    usuario_id uuid,
    nome_completo text,
    email text,
    telefone text,
    cpf text,
    cep text,
    logradouro text,
    numero text,
    complemento text,
    bairro text,
    cidade text,
    uf text,
    origem text DEFAULT 'cadastro'::text NOT NULL,
    observacao text,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    atualizado_em timestamp with time zone DEFAULT now() NOT NULL,
    nome text,
    whatsapp text,
    horario text,
    recado text,
    assuntos text[] DEFAULT '{}'::text[],
    atendido_em timestamp with time zone,
    atendido_por uuid,
    situacao text DEFAULT 'novo'::text NOT NULL,
    retomar_em date,
    responsavel uuid,
    CONSTRAINT lead_cep_ok CHECK (((cep IS NULL) OR (cep ~ '^\d{8}$'::text))),
    CONSTRAINT lead_cpf_ok CHECK (((cpf IS NULL) OR public.cpf_valido(cpf))),
    CONSTRAINT lead_origem_ok CHECK ((origem = ANY (ARRAY['cadastro'::text, 'servicos'::text, 'clube'::text, 'assinatura'::text, 'manual'::text, 'importado'::text, 'contato'::text, 'aulas'::text]))),
    CONSTRAINT lead_tel_ok CHECK (((telefone IS NULL) OR (telefone ~ '^\d{10,13}$'::text))),
    CONSTRAINT lead_uf_ok CHECK (((uf IS NULL) OR (uf ~ '^[A-Z]{2}$'::text)))
);


--
-- Name: admin_leads(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_leads(busca text DEFAULT NULL::text) RETURNS SETOF public.lead
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  return query
    select * from lead l
     where busca is null or btrim(busca) = ''
        or l.nome_completo ilike '%'||busca||'%'
        or l.email         ilike '%'||busca||'%'
        or l.telefone       like '%'||regexp_replace(busca,'\D','','g')||'%'
        or l.cpf            like '%'||regexp_replace(busca,'\D','','g')||'%'
     order by l.criado_em desc
     limit 500;
end $$;


--
-- Name: admin_renomear_carteira(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_renomear_carteira(cid bigint, novo_nome text, nova_desc text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  if btrim(coalesce(novo_nome,'')) = '' then raise exception 'nome vazio'; end if;
  update carteira
     set nome = btrim(novo_nome), descricao = coalesce(nova_desc,'')
   where id = cid;
  if not found then raise exception 'carteira não encontrada'; end if;
exception when unique_violation then
  raise exception 'essa pessoa já tem carteira com esse nome';
end $$;


--
-- Name: admin_trocar_apelido(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_trocar_apelido(quem uuid, novo text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  if btrim(novo) !~ '^[A-Za-z0-9._-]{3,24}$' then
    raise exception 'apelido inválido: 3 a 24 caracteres';
  end if;
  update perfil set apelido = btrim(novo) where id = quem;
  if not found then raise exception 'conta não encontrada'; end if;
exception when unique_violation then
  raise exception 'apelido já em uso';
end $_$;


--
-- Name: ao_declarar_posicao(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ao_declarar_posicao() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_marco date;
begin
  perform valida_classe(new.carteira_id, new.valida_de);

  -- Declaração para o próximo pregão fica pendente em posicao.
  -- Quem adota é o fechar_dia. Mexer aqui destruiria a deriva do dia.
  if new.valida_de > hoje_br() then
    return new;
  end if;

  select max(valida_de) into v_marco
    from posicao
   where carteira_id = new.carteira_id and valida_de <= hoje_br();

  if v_marco is null then return new; end if;

  delete from peso_atual where carteira_id = new.carteira_id;

  insert into peso_atual (carteira_id, ativo, peso, marco)
  select carteira_id, ativo, sum(peso), v_marco
    from posicao
   where carteira_id = new.carteira_id and valida_de = v_marco
   group by carteira_id, ativo;

  perform recalcular_exposicao(new.carteira_id);
  return new;
end $$;


--
-- Name: apagar_carteira(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apagar_carteira(cid bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare tem_historico boolean;
begin
  if not exists (select 1 from carteira
                  where id = cid and usuario_id = auth.uid() and ativa) then
    raise exception 'essa carteira não é sua, ou já foi encerrada';
  end if;

  select exists (select 1 from retorno_dia where carteira_id = cid)
    into tem_historico;

  if tem_historico then
    -- tem passado apurado: encerra, não apaga
    update carteira
       set ativa = false, encerrada_em = hoje_br()
     where id = cid;
    delete from peso_atual where carteira_id = cid;
    return 'encerrada';
  end if;

  -- nunca contou nada: desfaz o erro por inteiro
  delete from peso_atual where carteira_id = cid;
  delete from posicao     where carteira_id = cid;
  delete from nota        where carteira_id = cid;
  delete from seguidor    where carteira_id = cid;
  delete from carteira    where id = cid;
  return 'apagada';
end $$;


--
-- Name: apelido_livre(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apelido_livre(t text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
  select btrim(coalesce(t,'')) ~ '^[A-Za-z0-9._-]{3,24}$'
     and lower(btrim(t)) <> all (array[
       'admin','administrador','adm','root','sistema','suporte','moderador',
       'contato','oficial','saldopositivo','saldo-positivo','ranking'])
     and not exists (
       select 1 from perfil p where lower(p.apelido) = lower(btrim(t)))
$_$;


--
-- Name: apurar_aposta(text, date, text, real, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_aposta(p_ativo text, p_data date, p_direcao text, p_mult_stop real DEFAULT 0.6, p_mult_alvo real DEFAULT 0.6) RETURNS TABLE(tipo text, entrada real, stop real, alvo real, saida real, retorno real, pts integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  amp real;
  ab  real;
  r   record;
begin
  select f.amplitude into amp from faixa_papel f where f.ativo = upper(p_ativo);
  select b.abertura  into ab  from barra b
   where b.ativo = upper(p_ativo) and b.data = p_data;
  if amp is null or ab is null then return; end if;

  if upper(p_direcao) = 'C' then
    stop := (ab * (1 - amp * p_mult_stop))::real;
    alvo := (ab * (1 + amp * p_mult_alvo))::real;
  else
    stop := (ab * (1 + amp * p_mult_stop))::real;
    alvo := (ab * (1 - amp * p_mult_alvo))::real;
  end if;

  select * into r from apurar_operacao(p_ativo, p_data, p_direcao, stop, alvo);
  if r is null then return; end if;

  tipo := r.tipo; entrada := r.entrada; saida := r.saida; retorno := r.retorno;
  pts  := pontos(r.tipo, r.retorno);
  return next;
end $$;


--
-- Name: apurar_copa(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_copa(p_copa bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  j        record;
  pa       int; pb int;
  sa       int; sb int;
  ta       timestamptz; tb timestamptz;
  d        date;
  v_rod    bigint;
  vencs    uuid[];
  i        int;
  saida    text := '';
begin
  select data into d from copa where id = p_copa;

  -- confrontos de fases já rodadas e ainda sem vencedor
  for j in select * from copa_jogo cj
            join rodada r on r.id = cj.rodada_id
           where cj.copa_id = p_copa and cj.vencedor is null
             and r.situacao = 'apurada'
           order by cj.fase, cj.posicao loop

    if j.jogador_b is null then           -- passou direto
      update copa_jogo set vencedor = j.jogador_a where id = j.id;
      continue;
    end if;

    select coalesce(sum(pontos),0), min(votado_em) into pa, ta
      from voto where rodada_id = j.rodada_id and usuario_id = j.jogador_a;
    select coalesce(sum(pontos),0), min(votado_em) into pb, tb
      from voto where rodada_id = j.rodada_id and usuario_id = j.jogador_b;

    select coalesce(sequencia,0) into sa from intraday_sequencia where usuario_id = j.jogador_a;
    select coalesce(sequencia,0) into sb from intraday_sequencia where usuario_id = j.jogador_b;

    update copa_jogo set pontos_a = pa, pontos_b = pb,
      vencedor = case
        when pa > pb then j.jogador_a
        when pb > pa then j.jogador_b
        when coalesce(sa,0) > coalesce(sb,0) then j.jogador_a
        when coalesce(sb,0) > coalesce(sa,0) then j.jogador_b
        when ta is not null and (tb is null or ta < tb) then j.jogador_a
        else j.jogador_b end
     where id = j.id;
  end loop;

  -- fase seguinte, quando a anterior estiver completa
  if not exists (select 1 from copa_jogo where copa_id = p_copa
                  and fase = 'quartas' and vencedor is null)
     and not exists (select 1 from copa_jogo where copa_id = p_copa and fase = 'semi')
     and exists (select 1 from copa_jogo where copa_id = p_copa and fase = 'quartas') then
    select array_agg(vencedor order by posicao) into vencs
      from copa_jogo where copa_id = p_copa and fase = 'quartas' and vencedor is not null;
    select id into v_rod from rodada where data = d and hora = 14;
    for i in 1..2 loop
      insert into copa_jogo (copa_id, fase, posicao, rodada_id, jogador_a, jogador_b)
      values (p_copa, 'semi', i, v_rod, vencs[i*2-1], vencs[i*2])
      on conflict do nothing;
    end loop;
    saida := saida || ' · semifinal montada';
  end if;

  if not exists (select 1 from copa_jogo where copa_id = p_copa
                  and fase = 'semi' and vencedor is null)
     and not exists (select 1 from copa_jogo where copa_id = p_copa and fase = 'final')
     and exists (select 1 from copa_jogo where copa_id = p_copa and fase = 'semi') then
    select array_agg(vencedor order by posicao) into vencs
      from copa_jogo where copa_id = p_copa and fase = 'semi' and vencedor is not null;
    select id into v_rod from rodada where data = d and hora = 16;
    insert into copa_jogo (copa_id, fase, posicao, rodada_id, jogador_a, jogador_b)
    values (p_copa, 'final', 1, v_rod, vencs[1], vencs[2])
    on conflict do nothing;
    saida := saida || ' · final montada';
  end if;

  -- campeão
  update copa c set situacao = 'encerrada',
         campeao = (select vencedor from copa_jogo
                     where copa_id = p_copa and fase = 'final')
   where c.id = p_copa
     and exists (select 1 from copa_jogo where copa_id = p_copa
                  and fase = 'final' and vencedor is not null);

  if exists (select 1 from copa where id = p_copa and campeao is not null) then
    insert into conquista (usuario_id, ciclo_id, papel, regua, posicao)
    select campeao, null, 'individual', 'geral', 1 from copa where id = p_copa
    on conflict do nothing;
    saida := saida || ' · temos campeão';
  end if;

  return coalesce(nullif(saida,''), 'nada a apurar na copa');
end;
$$;


--
-- Name: apurar_dia_apostas(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_dia_apostas(p_data date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare a record; r record; n int := 0;
begin
  for a in select id, ativo, direcao from aposta
            where data = p_data
              and not exists (select 1 from aposta_apurada x where x.id = a.id)
  loop
    select * into r from apurar_aposta(a.ativo, p_data, a.direcao);
    if r.tipo is null then continue; end if;   -- sem candle ainda
    insert into aposta_apurada (id, tipo, entrada, stop, alvo, saida, retorno, pts)
    values (a.id, r.tipo, r.entrada, r.stop, r.alvo, r.saida, r.retorno, r.pts)
    on conflict (id) do update
       set tipo = excluded.tipo, retorno = excluded.retorno, pts = excluded.pts;
    n := n + 1;
  end loop;
  return n;
end $$;


--
-- Name: apurar_operacao(text, date, text, real, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_operacao(p_ativo text, p_data date, p_direcao text, p_stop real DEFAULT NULL::real, p_alvo real DEFAULT NULL::real) RETURNS TABLE(tipo text, entrada real, saida real, retorno real)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  b barra;
  tocou_stop boolean;
  tocou_alvo boolean;
begin
  select * into b from barra where ativo = upper(p_ativo) and data = p_data;
  if not found then return; end if;

  entrada := b.abertura;

  if upper(p_direcao) = 'C' then
    -- Gap primeiro: se abriu além do limite, a operação nem começou no
    -- preço planejado. Stop não é promessa de preço.
    if p_stop is not null and b.abertura <= p_stop then
      tipo := 'gap_contra'; saida := b.abertura;
    elsif p_alvo is not null and b.abertura >= p_alvo then
      tipo := 'gap_favor';  saida := b.abertura;
    else
      tocou_stop := p_stop is not null and b.minima <= p_stop;
      tocou_alvo := p_alvo is not null and b.maxima >= p_alvo;
      if tocou_stop and tocou_alvo then
        tipo := 'ambiguo'; saida := b.fechamento;   -- não se sabe a ordem
      elsif tocou_stop then tipo := 'stop';       saida := p_stop;
      elsif tocou_alvo then tipo := 'alvo';       saida := p_alvo;
      else                  tipo := 'fechamento'; saida := b.fechamento;
      end if;
    end if;
    retorno := saida / entrada - 1;

  elsif upper(p_direcao) = 'V' then
    -- vendido: stop ACIMA da entrada, alvo ABAIXO
    if p_stop is not null and b.abertura >= p_stop then
      tipo := 'gap_contra'; saida := b.abertura;
    elsif p_alvo is not null and b.abertura <= p_alvo then
      tipo := 'gap_favor';  saida := b.abertura;
    else
      tocou_stop := p_stop is not null and b.maxima >= p_stop;
      tocou_alvo := p_alvo is not null and b.minima <= p_alvo;
      if tocou_stop and tocou_alvo then
        tipo := 'ambiguo'; saida := b.fechamento;
      elsif tocou_stop then tipo := 'stop';       saida := p_stop;
      elsif tocou_alvo then tipo := 'alvo';       saida := p_alvo;
      else                  tipo := 'fechamento'; saida := b.fechamento;
      end if;
    end if;
    retorno := 1 - saida / entrada;

  else
    raise exception 'direção tem de ser C ou V';
  end if;

  return next;
end $$;


--
-- Name: apurar_rodada(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_rodada(p_rodada bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  r        record;
  v_sobe   record;
  v_cai    record;
  v_vol    record;
  v_petr   real;
  v_lado   text;
  v_med    int;
  n_votos  int := 0;
begin
  select * into r from rodada where id = p_rodada;
  if r is null                then return 'rodada não existe'; end if;
  if r.situacao = 'apurada'   then return 'já estava apurada';  end if;
  if now() < r.fecha_em       then return 'ainda não fechou';   end if;

  -- A cotacao_hora guarda em `hora = h` o ultimo preco da faixa h:00–h:59.
  -- Entao movimento_da_hora(data, h-1) mede o andar das h-1 as h — que e
  -- exatamente a janela desta rodada. A rodada das 11h cobre 10h→11h e le
  -- a hora 10. E as 11h essa hora ja fechou: o dado esta completo.
  v_med := r.hora - 1;
  if not exists (select 1 from movimento_da_hora(r.data, v_med)) then
    return 'sem foto da hora ' || v_med || ' — nada a apurar';
  end if;

  -- quem subiu mais, entre os três sorteados para 'sobe'
  select m.* into v_sobe
    from movimento_da_hora(r.data, v_med) m
    join rodada_papel p on p.rodada_id = p_rodada and p.jogo = 'sobe'
                       and p.ativo = m.ativo
   order by m.variacao desc limit 1;

  -- quem caiu mais, entre os três sorteados para 'cai'
  select m.* into v_cai
    from movimento_da_hora(r.data, v_med) m
    join rodada_papel p on p.rodada_id = p_rodada and p.jogo = 'cai'
                       and p.ativo = m.ativo
   order by m.variacao asc limit 1;

  -- quem girou mais, entre os três sorteados para 'volume'
  select m.* into v_vol
    from movimento_da_hora(r.data, v_med) m
    join rodada_papel p on p.rodada_id = p_rodada and p.jogo = 'volume'
                       and p.ativo = m.ativo
   order by m.giro_hora desc limit 1;

  -- a PETR4 girou acima ou abaixo do corte combinado?
  select m.giro_hora into v_petr
    from movimento_da_hora(r.data, v_med) m where m.ativo = 'PETR4';
  v_lado := case when v_petr is null then null
                 when v_petr >= coalesce(r.corte_petr, 0) then 'acima'
                 else 'abaixo' end;

  delete from rodada_gabarito where rodada_id = p_rodada;

  if v_sobe.ativo is not null then
    insert into rodada_gabarito values (p_rodada, 'sobe', v_sobe.ativo,
      to_char(v_sobe.variacao*100,'FM990D00') || '%');
  end if;
  if v_cai.ativo is not null then
    insert into rodada_gabarito values (p_rodada, 'cai', v_cai.ativo,
      to_char(v_cai.variacao*100,'FM990D00') || '%');
  end if;
  if v_vol.ativo is not null then
    insert into rodada_gabarito values (p_rodada, 'volume', v_vol.ativo,
      'R$ ' || to_char(v_vol.giro_hora/1e6,'FM999G990D0') || ' mi');
  end if;
  if v_lado is not null then
    insert into rodada_gabarito values (p_rodada, 'petr', v_lado,
      'R$ ' || to_char(v_petr/1e6,'FM999G990D0') || ' mi de R$ '
            || to_char(r.corte_petr/1e6,'FM999G990D0') || ' mi');
  end if;

  -- conferência dos votos: 10 pontos por acerto, errar não tira ponto
  update voto v set acertou = false, pontos = 0 where v.rodada_id = p_rodada;
  update voto v set acertou = true, pontos = 10
    from rodada_gabarito g
   where v.rodada_id = p_rodada and g.rodada_id = p_rodada
     and g.jogo = v.jogo and v.palpite = g.resposta;

  select count(*) into n_votos from voto where rodada_id = p_rodada;
  update rodada set situacao = 'apurada', apurada_em = now() where id = p_rodada;
  perform somar_intraday(p_rodada);
  return format('rodada das %sh apurada · %s voto(s)', r.hora, n_votos);
end;
$_$;


--
-- Name: apurar_rodadas_vencidas(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apurar_rodadas_vencidas() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r record; saida text := ''; n int := 0;
begin
  for r in select id from rodada
            where situacao <> 'apurada' and fecha_em < now()
            order by data, hora loop
    saida := saida || ' · ' || apurar_rodada(r.id);
    n := n + 1;
  end loop;
  if n = 0 then return 'nenhuma rodada vencida'; end if;
  return saida;
end;
$$;


--
-- Name: avisar_lead(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.avisar_lead() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
begin
  insert into fila_email (destino, assunto, corpo)
  values (
    'voce@seuemail.com.br',
    'Novo pedido de contato — ' || new.nome,
    'Nome: '     || new.nome                              || E'\n' ||
    'WhatsApp: ' || new.whatsapp                          || E'\n' ||
    'E-mail: '   || coalesce(new.email,   '—')            || E'\n' ||
    'Horário: '  || coalesce(new.horario, '—')            || E'\n' ||
    'Assuntos: ' || coalesce(array_to_string(new.assuntos, ', '), '—') || E'\n' ||
    'Recado: '   || coalesce(new.recado,  '—')
  );
  return new;
end $$;


--
-- Name: avisar_seguidores(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.avisar_seguidores(cid bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare c record; dono uuid; n int := 0;
begin
  select ca.nome, p.apelido, ca.usuario_id into c
    from carteira ca join perfil p on p.id = ca.usuario_id
   where ca.id = cid and ca.ativa;
  if not found then return 0; end if;
  dono := c.usuario_id;

  insert into fila_email (destino, assunto, corpo)
  select u.email,
         c.apelido || ' mexeu em ' || c.nome,
         c.apelido || ' declarou posições novas em "' || c.nome || '".'
           || E'\n\nhttps://SEU-DOMINIO/#/carteira/' || cid
           || E'\n\nPara parar de receber, desmarque o sino na página da carteira.'
    from seguidor s
    join perfil     pf on pf.id = s.usuario_id
    join auth.users u  on u.id  = s.usuario_id
   where s.carteira_id = cid
     and pf.assinante            -- confere DE NOVO: pode ter cancelado
     and not pf.bloqueado
     and u.email is not null
     and s.usuario_id <> dono;   -- ninguém se avisa

  get diagnostics n = row_count;
  return n;
end $$;


--
-- Name: barra_atualiza_universo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.barra_atualiza_universo() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- a guarda do `data >` faz a carga funda de 90 pregoes nao sobrescrever
  -- o preco de hoje com o de tres meses atras
  update universo u
     set cotacao    = new.fechamento,
         cotacao_em = new.data,
         liquidez   = case when new.volume is not null and new.volume > 0
                           then new.volume * new.fechamento
                           else u.liquidez end
   where u.ativo = new.ativo
     and new.data > coalesce(u.cotacao_em, date '1900-01-01');
  return new;
end $$;


--
-- Name: chavear_copa(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.chavear_copa(p_copa bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v      uuid[];
  n      int;
  i      int;
  v_rod  bigint;
  d      date;
  v_fase text;
  k      int;      -- quantos jogos tem a primeira fase
  h      int;      -- hora da rodada dessa fase
  base   int;      -- índice do adversário: base - i
begin
  select data into d from copa where id = p_copa;
  select array_agg(usuario_id order by ordem) into v
    from copa_vaga where copa_id = p_copa;
  n := coalesce(array_length(v,1), 0);

  if n < 2 then
    update copa set situacao = 'encerrada' where id = p_copa;
    return 'menos de duas pessoas na chave — copa de hoje não acontece';
  end if;

  -- A CHAVE COMEÇA NA FASE QUE CABE. Antes eram sempre 4 quartas: com 2
  -- inscritos sobravam dois jogos sem jogador nenhum dos dois lados, que
  -- nunca ganhavam vencedor — e o apurar_copa, que só monta a semifinal
  -- quando não há quartas pendentes, travava a copa em 'andamento' para
  -- sempre. Por isso copa apurada nunca aconteceu de verdade.
  if    n >= 5 then v_fase := 'quartas'; k := 4; h := 12;
  elsif n >= 3 then v_fase := 'semi';    k := 2; h := 14;
  else              v_fase := 'final';   k := 1; h := 16;
  end if;
  base := 2*k + 1;

  select id into v_rod from rodada where data = d and hora = h;

  -- v[i] contra v[base-i]. Quando o adversário não existe, quem entrou
  -- primeiro passa direto — os byes caem nos primeiros da ordem de chegada,
  -- que é a ordem de inscrição.
  for i in 1..k loop
    insert into copa_jogo (copa_id, fase, posicao, rodada_id, jogador_a, jogador_b)
    values (p_copa, v_fase, i, v_rod,
            v[i], case when base - i <= n then v[base - i] end)
    on conflict (copa_id, fase, posicao) do nothing;
  end loop;

  update copa set situacao = 'andamento' where id = p_copa;
  return format('chave montada em %s com %s participante(s)', v_fase, n);
end;
$$;


--
-- Name: consenso(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consenso(min_carteiras integer DEFAULT 5) RETURNS TABLE(ativo text, carteiras integer, comprada integer, vendida integer, peso_medio real, peso_liquido real)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select pa.ativo,
         count(distinct pa.carteira_id)::int,
         count(*) filter (where pa.peso > 0)::int,
         count(*) filter (where pa.peso < 0)::int,
         avg(abs(pa.peso))::real,
         avg(pa.peso)::real
    from peso_atual pa
    join carteira c on c.id = pa.carteira_id and c.ativa
   group by pa.ativo
  having count(distinct pa.carteira_id) >= min_carteiras
   order by count(distinct pa.carteira_id) desc, avg(abs(pa.peso)) desc;
$$;


--
-- Name: dar_assinatura(text, integer, real, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dar_assinatura(p_apelido text, p_dias integer DEFAULT 30, p_valor real DEFAULT 19, p_meio text DEFAULT 'pix'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare uid uuid; ini date; fim date;
begin
  if not sou_admin() then raise exception 'só admin'; end if;

  select id into uid from perfil where lower(apelido) = lower(p_apelido);
  if uid is null then return 'não achei o apelido ' || p_apelido; end if;

  select max(a.fim) into fim from assinatura a
   where a.usuario_id = uid and a.fim >= hoje_br();
  ini := coalesce(fim + 1, hoje_br());

  insert into assinatura (usuario_id, inicio, fim, valor, meio)
  values (uid, ini, ini + p_dias - 1, p_valor, p_meio);

  perform sincronizar_assinantes();
  return p_apelido || ' assinante até ' || (ini + p_dias - 1);
end $$;


--
-- Name: declarar(bigint, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.declarar(cid bigint, pesos jsonb, nota_txt text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
end $$;


--
-- Name: definir_assinante(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.definir_assinante(quem uuid, valor boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then
    raise exception 'só admin pode mexer em assinatura';
  end if;
  update perfil set assinante = valor where id = quem;
  return valor;
end $$;


--
-- Name: eh_assinante(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.eh_assinante() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select assinante or admin from perfil where id = auth.uid()), false);
$$;


--
-- Name: encerrar_duelos(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.encerrar_duelos() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare d record; ra real; rb real; venc uuid; n int := 0;
begin
  for d in select * from duelo
            where situacao = 'aceito'
              and fim < (now() at time zone 'America/Sao_Paulo')::date loop
    ra := retorno_periodo(d.carteira_a, d.inicio, d.fim);
    rb := retorno_periodo(d.carteira_b, d.inicio, d.fim);

    venc := case when ra is null or rb is null then null
                 when ra > rb then d.desafiante
                 when rb > ra then d.desafiado
                 else null end;   -- empate exato: sem vencedor

    update duelo set situacao = 'encerrado', ret_a = ra, ret_b = rb,
                     vencedor = venc, encerrado_em = now()
     where id = d.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;


--
-- Name: encerrar_minha_conta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.encerrar_minha_conta() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare uid uuid; ap text;
begin
  uid := auth.uid();
  if uid is null then raise exception 'precisa estar logado'; end if;

  select apelido into ap from perfil where id = uid;

  insert into conta_arquivada (usuario_id, apelido, nome, telefone, email, criado_em, motivo)
  select p.id, p.apelido, p.nome, p.telefone,
         (select u.email from auth.users u where u.id = p.id),
         p.criado_em, 'pedido do usuário'
    from perfil p where p.id = uid
  on conflict (usuario_id) do update set encerrada_em = now();

  -- as carteiras saem do ranking; o retorno já apurado fica
  update carteira set ativa = false where usuario_id = uid;

  -- o cadastro sai do site. O apelido é liberado com um sufixo, para
  -- não travar o nome nem revelar quem era.
  update perfil
     set bloqueado = true,
         assinante = false,
         nome = null,
         telefone = null,
         nome_publico = null,
         exibir = 'anonimo',
         apelido = 'encerrada_' || left(uid::text, 8)
   where id = uid;

  return coalesce(ap, 'conta') || ' encerrada';
end $$;


--
-- Name: encerrar_se_zerou(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.encerrar_se_zerou() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.indice <= 0 then
    update carteira set ativa = false where id = new.carteira_id and ativa;
  end if;
  return new;
end $$;


--
-- Name: enfileirar_papel(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enfileirar_papel() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into papel_fila (ativo, estado)
  select new.ativo, 'pendente'
   where not exists (select 1 from cotacao_viva c where c.ativo = new.ativo)
  on conflict (ativo) do nothing;
  return new;
end $$;


--
-- Name: entrar_na_copa(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.entrar_na_copa() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  agora  timestamp := (now() at time zone 'America/Sao_Paulo');
  hoje   date := agora::date;
  v_copa bigint;
  v_data date;
  n      int;
begin
  -- A de hoje só aceita antes das 10h, que é quando a chave é sorteada.
  -- Depois disso a inscrição vale para o próximo pregão.
  select id, data into v_copa, v_data
    from copa
   where situacao = 'inscricoes'
     and (data > hoje or (data = hoje and extract(hour from agora) < 10))
   order by data limit 1;

  if v_copa is null then return 'não há copa com inscrição aberta agora'; end if;

  if exists (select 1 from copa_vaga where copa_id = v_copa
              and usuario_id = auth.uid()) then
    return 'você já está na chave de ' || to_char(v_data, 'DD/MM');
  end if;

  select count(*) into n from copa_vaga where copa_id = v_copa;
  if n >= 8 then
    return 'as oito vagas de ' || to_char(v_data, 'DD/MM') || ' já foram preenchidas';
  end if;

  insert into copa_vaga (copa_id, usuario_id, ordem)
  values (v_copa, auth.uid(), n + 1);
  return 'você entrou na chave de ' || to_char(v_data, 'DD/MM')
       || ', na vaga ' || (n + 1);
end;
$$;


--
-- Name: estado_papel(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.estado_papel(p_ativo text) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (select f.estado from papel_fila f where f.ativo = p_ativo),
    case when exists (select 1 from cotacao_viva c where c.ativo = p_ativo)
         then 'cotando' else 'pendente' end
  );
$$;


--
-- Name: fechar_ciclo(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fechar_ciclo(p_ciclo bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int;
begin
  delete from time_ciclo_resultado where ciclo_id = p_ciclo;

  insert into time_ciclo_resultado
    (ciclo_id, time_id, dias, acumulado, sharpe, drawdown)
  select d.ciclo_id, d.time_id, count(*)::int,
         (max(d.indice) filter (where d.data = ult.ultima)) / 100.0 - 1,
         case when count(*) >= 2 and stddev_samp(d.retorno) > 0
              then ((avg(d.retorno) * 252) - taxa_rf_ano())
                   / (stddev_samp(d.retorno) * sqrt(252))
                   * (count(*)::real / (count(*) + 40))
         end,
         min(d.indice / greatest(pico.pico, 1) - 1)
    from time_carteira_dia d
    join lateral (select max(data) as ultima from time_carteira_dia x
                   where x.ciclo_id = d.ciclo_id and x.time_id = d.time_id
                     and x.retorno is not null) ult on true
    join lateral (select max(y.indice) as pico from time_carteira_dia y
                   where y.ciclo_id = d.ciclo_id and y.time_id = d.time_id
                     and y.data <= d.data) pico on true
   where d.ciclo_id = p_ciclo and d.retorno is not null
   group by d.ciclo_id, d.time_id, ult.ultima;

  -- posições em cada régua. Quem não tem a régua vai para o fim dela e não
  -- some da conta: excluir daria vantagem a quem tem menos dado.
  with p as (
    select time_id,
           rank() over (order by acumulado desc nulls last) as pa,
           rank() over (order by sharpe    desc nulls last) as ps,
           rank() over (order by drawdown  desc nulls last) as pd,
           count(*) filter (where sharpe is not null) over () as com_sharpe
      from time_ciclo_resultado where ciclo_id = p_ciclo)
  update time_ciclo_resultado r
     set pos_acum = p.pa, pos_sharpe = p.ps, pos_dd = p.pd,
         pos_geral = p.pa + p.pd + case when p.com_sharpe > 0 then p.ps else 0 end
    from p where p.time_id = r.time_id and r.ciclo_id = p_ciclo;

  insert into conquista (time_id, ciclo_id, papel, regua, posicao)
  select time_id, p_ciclo, 'time', v.regua, v.pos
    from time_ciclo_resultado r
    cross join lateral (values
      ('rentabilidade', r.pos_acum), ('sharpe', r.pos_sharpe),
      ('queda', r.pos_dd),           ('geral',  r.pos_geral)
    ) as v(regua, pos)
   where r.ciclo_id = p_ciclo and v.pos <= 3;

  insert into conquista (usuario_id, time_id, ciclo_id, papel, regua, posicao)
  select m.usuario_id, c.time_id, p_ciclo,
         case when t.capitao = m.usuario_id then 'capitao' else 'membro' end,
         c.regua, c.posicao
    from conquista c
    join time_ t on t.id = c.time_id
    join time_ciclo_membro m on m.ciclo_id = p_ciclo and m.time_id = c.time_id
   where c.ciclo_id = p_ciclo and c.papel = 'time' and c.usuario_id is null;

  update ciclo set situacao = 'encerrado', encerrado_em = now() where id = p_ciclo;
  select count(*) into n from time_ciclo_resultado where ciclo_id = p_ciclo;
  return n;
end;
$$;


--
-- Name: fechar_dia(date, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fechar_dia(d date DEFAULT NULL::date, refazer boolean DEFAULT false) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  c record; reb text; bnd real;
  cdi_dia real; ret real;
  l real; s real; caixa real; rende real;
  idx_ant real; idx_novo real; n int := 0;
  m_novo date; m_atual date;
  dia date := coalesce(d, (select max(data) from oscilacao), hoje_br());
  vira_sem boolean; vira_mes boolean; vira_ano boolean;
  jafechou boolean; motivo text;
  aj jsonb;                                   -- ⚠️ NOVO: foto do ajuste
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role'
     and not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'só admin';
  end if;

  cdi_dia := power(1 + taxa_rf_ano()/100.0, 1.0/252) - 1;
  jafechou := exists (select 1 from retorno_dia where data = dia);
  if not refazer and jafechou then
    raise notice 'pregão % já fechado', dia; return 0;
  end if;

  vira_sem := date_trunc('week',  proximo_pregao(dia)) <> date_trunc('week',  dia);
  vira_mes := date_trunc('month', proximo_pregao(dia)) <> date_trunc('month', dia);
  vira_ano := date_trunc('year',  proximo_pregao(dia)) <> date_trunc('year',  dia);

  -- ⚠️ A GUARDA: carteira não apura pregão anterior ao nascimento dela.
  -- ⚠️ A GUARDA 2: quem já quebrou não apura mais. `encerrada_em` é a marca;
  -- `ativa` continua true de propósito, para a carteira seguir no ranking
  -- mostrando o −100% em vez de sumir. Encerramento manual usa `ativa=false`
  -- e continua funcionando como antes.
  for c in select id, rebalancear, banda_pct from carteira
            where ativa and encerrada_em is null and criada_em <= dia loop

    -- ⚠️ A RÉGUA VEM DA DATA. O autor troca quando quiser; o que já foi
    -- apurado continua apurado pela regra que valia naquele pregão.
    reb := null; bnd := null;
    select r.rebalancear, r.banda_pct into reb, bnd
      from regra r where r.carteira_id = c.id and r.valida_de <= dia
     order by r.valida_de desc limit 1;
    reb := coalesce(reb, c.rebalancear);
    bnd := coalesce(bnd, c.banda_pct);

    if refazer and jafechou then
      perform refazer_pesos(c.id, dia);
      delete from rebalanceamento where carteira_id = c.id and data = dia;
    end if;

    select max(valida_de) into m_novo
      from posicao where carteira_id = c.id and valida_de <= dia;
    select max(marco) into m_atual from peso_atual where carteira_id = c.id;

    if m_novo is not null and (m_atual is null or m_novo > m_atual) then
      delete from peso_atual where carteira_id = c.id;
      insert into peso_atual (carteira_id, ativo, peso, marco)
      select carteira_id, ativo, sum(peso), m_novo
        from posicao where carteira_id = c.id and valida_de = m_novo
       group by carteira_id, ativo;
      perform recalcular_exposicao(c.id);
      m_atual := m_novo;
    end if;

    if not exists (select 1 from peso_atual where carteira_id = c.id) then continue; end if;

    select coalesce(sum(peso) filter (where peso > 0), 0),
          -coalesce(sum(peso) filter (where peso < 0), 0)
      into l, s from peso_atual where carteira_id = c.id;

    caixa := greatest(0, least(100, 100 - l));
    rende := greatest(0, 100 - l - s);

    select coalesce(sum((pa.peso/100.0) * coalesce(o.valor, 0)), 0) into ret
      from peso_atual pa
      left join oscilacao o on o.ativo = pa.ativo and o.data = dia
     where pa.carteira_id = c.id;
    ret := ret + (rende/100.0) * cdi_dia;

    select indice into idx_ant from retorno_dia
     where carteira_id = c.id and data < dia order by data desc limit 1;
    idx_ant := coalesce(idx_ant, 100.0);

    idx_novo := idx_ant * (1 + ret);

    -- ⚠️ RUÍNA. Numa vendida o capital é 200 − 100×(P/P₀) e zera quando o
    -- papel dobra; numa comprada zera se tudo for a zero. Passando disso o
    -- índice ficava negativo, o retorno do dia virava −380%, e no pregão
    -- seguinte o peso invertia de sinal e a carteira quebrada voltava a
    -- "ganhar". Aqui ela para: perde 100% e encerra.
    if idx_novo <= 0 then
      insert into retorno_dia (carteira_id, data, retorno, indice)
      values (c.id, dia, -1.0, 0.0)
      on conflict (carteira_id, data) do update
         set retorno = excluded.retorno, indice = excluded.indice;

      -- não desativa: a carteira fica visível no ranking com −100%.
      -- O que para é a apuração, pela marca de encerrada_em.
      update carteira
         set encerrada_em = dia
       where id = c.id;

      perform recalcular_resumo(c.id);
      n := n + 1;
      raise notice 'carteira % quebrou em %: perda total, apuração encerrada', c.id, dia;
      continue;
    end if;

    insert into retorno_dia (carteira_id, data, retorno, indice)
    values (c.id, dia, ret, idx_novo)
    on conflict (carteira_id, data) do update
       set retorno = excluded.retorno, indice = excluded.indice;

    update peso_atual pa
       set peso = pa.peso * (1 + coalesce(o.valor, 0)) / (1 + ret)
      from (select ativo, valor from oscilacao where data = dia) o
     where pa.carteira_id = c.id and pa.ativo = o.ativo and (1 + ret) <> 0;

    motivo := null;
    if m_atual is not null then
      if    reb = 'semanal' and vira_sem then motivo := 'semanal';
      elsif reb = 'mensal'  and vira_mes then motivo := 'mensal';
      elsif reb = 'anual'   and vira_ano then motivo := 'anual';
      elsif reb = 'banda' and fora_da_banda(c.id, m_atual, bnd) then
        motivo := 'banda de ' || round(bnd) || '% estourada';
      end if;
    end if;

    if motivo is not null then
      -- ⚠️ NOVO: fotografa o antes/depois ANTES de apagar o peso_atual.
      -- Neste ponto o peso_atual já tem o drift do dia — é exatamente o
      -- "antes". O full join pega papel que entrou e papel que saiu; o
      -- where no fim descarta quem não se mexeu, então o jsonb só carrega
      -- o que virou ordem de verdade.
      aj := null;
      select jsonb_object_agg(x.ativo,
               jsonb_build_array(round(x.antes::numeric,2), round(x.depois::numeric,2)))
        into aj
        from (select coalesce(pa.ativo, p.ativo) as ativo,
                     coalesce(pa.peso, 0)        as antes,
                     coalesce(p.peso,  0)        as depois
                from (select ativo, peso from peso_atual
                       where carteira_id = c.id) pa
                full join (select ativo, sum(peso) as peso from posicao
                            where carteira_id = c.id and valida_de = m_atual
                            group by ativo) p on p.ativo = pa.ativo) x
       where round(x.antes::numeric,2) <> round(x.depois::numeric,2);

      delete from peso_atual where carteira_id = c.id;
      insert into peso_atual (carteira_id, ativo, peso, marco)
      select carteira_id, ativo, sum(peso), m_atual
        from posicao where carteira_id = c.id and valida_de = m_atual
       group by carteira_id, ativo;

      -- ⚠️ o on conflict atualiza o ajuste também: sem isso, um `refazer`
      -- deixaria a foto velha presa na linha.
      insert into rebalanceamento (carteira_id, data, motivo, ajuste)
      values (c.id, dia, motivo, aj)
      on conflict (carteira_id, data) do update
         set motivo = excluded.motivo, ajuste = excluded.ajuste;
    end if;

    perform recalcular_exposicao_atual(c.id);
    -- ⚠️ O resumo é o que o ranking lê. Sem esta linha ele congela no
    -- dia em que foi semeado e o pódio para de mexer.
    perform recalcular_resumo(c.id);
    n := n + 1;
  end loop;

  perform sincronizar_assinantes();
  return n;
end $$;


--
-- Name: fechar_dia_times(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fechar_dia_times(p_data date DEFAULT NULL::date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_dia   date := coalesce(p_data, (select max(data) from oscilacao));
  v_prox  date;
  r       record;
  v_ret   real;
  v_ant   real;
  n       int := 0;
begin
  select min(data) into v_prox from oscilacao where data > v_dia;
  -- garante a linha do próprio dia antes de apurar. Antes, a rotina só
  -- apurava dias que ela mesma tinha criado na véspera: bastava faltar um
  -- pregão para a corrente romper e não reatar mais.
  for r in
    select i.ciclo_id, i.time_id from time_inscricao i
      join ciclo c on c.id = i.ciclo_id
     where c.situacao = 'aberto' and v_dia between c.inicio and c.fim
       and not exists (select 1 from time_carteira_dia d
                        where d.ciclo_id = i.ciclo_id and d.time_id = i.time_id
                          and d.data = v_dia)
  loop
    perform montar_carteira_time(r.ciclo_id, r.time_id, v_dia);
  end loop;
  for r in
    select d.ciclo_id, d.time_id, d.ativos
      from time_carteira_dia d
      join ciclo c on c.id = d.ciclo_id
     where d.data = v_dia and c.situacao <> 'encerrado'
  loop
    select avg(o.valor)::real into v_ret
      from oscilacao o
     where o.data = v_dia and o.ativo = any(r.ativos);
    if v_ret is null then continue; end if;
    select indice into v_ant from time_carteira_dia
     where ciclo_id = r.ciclo_id and time_id = r.time_id and data < v_dia
     order by data desc limit 1;
    update time_carteira_dia
       set retorno = v_ret,
           indice  = coalesce(v_ant, 100) * (1 + v_ret)
     where ciclo_id = r.ciclo_id and time_id = r.time_id and data = v_dia;
    n := n + 1;
  end loop;
  -- carteira do próximo pregão, com o que os membros têm agora
  if v_prox is not null then
    for r in
      select i.ciclo_id, i.time_id from time_inscricao i
        join ciclo c on c.id = i.ciclo_id
       where c.situacao = 'aberto' and v_prox between c.inicio and c.fim
    loop
      perform montar_carteira_time(r.ciclo_id, r.time_id, v_prox);
    end loop;
  end if;
  return n;
end;
$$;


--
-- Name: fitas(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fitas(p_classe text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(jsonb_object_agg(r.carteira_id, r.fita), '{}'::jsonb)
    from resumo r
    join carteira c on c.id = r.carteira_id and c.ativa
    left join carteira_classe cc on cc.id = c.id
   where r.fita is not null and (p_classe is null or cc.classe = p_classe);
$$;


--
-- Name: fora_da_banda(bigint, date, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fora_da_banda(cid bigint, marco date, banda real) RETURNS boolean
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare cl text; b_atual real; b_decl real;
begin
  select classe into cl from carteira where id = cid;

  -- Na 60/40 o que deriva é a PROPORÇÃO entre renda fixa e ações, não
  -- cada papel: dez ações de 4% nunca se afastam sozinhas, mas o bloco
  -- todo vai de 40 para 50 e descaracteriza a carteira.
  if cl = 'sessenta_quarenta' then
    select coalesce(sum(abs(peso)),0) into b_atual from peso_atual where carteira_id = cid;
    select coalesce(sum(abs(peso)),0) into b_decl  from posicao
     where carteira_id = cid and valida_de = marco;
    return b_decl > 0 and abs(b_atual - b_decl) / b_decl > banda / 100.0;
  end if;

  return exists (
    select 1
      from peso_atual pa
      join (select ativo, sum(peso) as dec from posicao
             where carteira_id = cid and valida_de = marco group by ativo) q
        on q.ativo = pa.ativo
     where pa.carteira_id = cid and abs(q.dec) > 0
       and abs(abs(pa.peso) - abs(q.dec)) / abs(q.dec) > banda / 100.0);
end $$;


--
-- Name: fotografar_hora(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fotografar_hora() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_agora timestamptz := coalesce(new.atualizado_em, now());
  v_br    timestamp   := v_agora at time zone 'America/Sao_Paulo';
  v_hora  int         := extract(hour from v_br);
begin
  -- fora do pregão não interessa, e evita encher a tabela de madrugada
  if v_hora < 10 or v_hora > 17 then return new; end if;
  if extract(dow from v_br) in (0, 6) then return new; end if;
  if new.preco is null or new.preco <= 0 then return new; end if;
  insert into cotacao_hora (ativo, data, hora, preco, abertura, fech_ant,
                            volume, atualizado_em)
  values (new.ativo, v_br::date, v_hora, new.preco, new.abertura, new.valor,
          new.volume, v_agora)
  on conflict (ativo, data, hora) do update
    set preco = excluded.preco,
        abertura = excluded.abertura,
        fech_ant = excluded.fech_ant,
        volume = excluded.volume,
        atualizado_em = excluded.atualizado_em;
  return new;
end;
$$;


--
-- Name: giro_do_dia(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.giro_do_dia(p_data date DEFAULT NULL::date) RETURNS real
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
  select sum(x.volume * x.preco)::real from (
    select distinct on (ativo) ativo, volume, preco
      from cotacao_hora
     where data = coalesce(p_data, (select max(data) from cotacao_hora))
       and ativo ~ '[0-9]$'
     order by ativo, hora desc
  ) x;
$_$;


--
-- Name: gravar_oscilacao(jsonb, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gravar_oscilacao(dados jsonb, d date DEFAULT NULL::date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int := 0;
begin
  if not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'só admin';
  end if;

  insert into oscilacao (ativo, data, valor, data_cot)
  select upper(x->>'ativo'),
         coalesce(nullif(x->>'data_cot','')::date, d, hoje_br()),
         (x->>'valor')::real,
         nullif(x->>'data_cot','')::date
    from jsonb_array_elements(dados) x
  on conflict (ativo, data) do update
     set valor = excluded.valor, data_cot = excluded.data_cot;

  get diagnostics n = row_count;
  return n;
end $$;


--
-- Name: gravar_universo(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gravar_universo(dados jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int := 0;
begin
  if not sou_admin() then
    raise exception 'só admin pode atualizar o universo';
  end if;

  insert into universo (ativo, cotacao, liquidez)
  select upper(x->>'ativo'), (x->>'cotacao')::real, (x->>'liquidez')::real
    from jsonb_array_elements(dados) x
   where x->>'ativo' is not null
  on conflict (ativo) do update
     set cotacao = excluded.cotacao, liquidez = excluded.liquidez;

  get diagnostics n = row_count;
  return n;
end $$;


--
-- Name: hoje_br(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hoje_br() RETURNS date
    LANGUAGE sql STABLE
    AS $$
  select (now() at time zone 'America/Sao_Paulo')::date;
$$;


--
-- Name: lead_do_cadastro(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lead_do_cadastro() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare tel text;
begin
  tel := regexp_replace(coalesce(new.raw_user_meta_data->>'telefone',''), '\D', '', 'g');
  if tel !~ '^\d{10,13}$' then tel := null; end if;

  insert into lead (usuario_id, email, nome_completo, telefone, origem)
  values (new.id,
          new.email,
          nullif(btrim(coalesce(new.raw_user_meta_data->>'nome','')), ''),
          tel,
          'cadastro')
  on conflict (usuario_id) do nothing;

  return new;
exception when others then
  raise warning 'lead do cadastro falhou para %: %', new.id, sqlerrm;
  return new;
end $_$;


--
-- Name: lead_normaliza(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lead_normaliza() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.cpf      := nullif(regexp_replace(coalesce(new.cpf,''),      '\D','','g'), '');
  new.cep      := nullif(regexp_replace(coalesce(new.cep,''),      '\D','','g'), '');
  new.telefone := nullif(regexp_replace(coalesce(new.telefone,''), '\D','','g'), '');
  new.uf       := upper(nullif(btrim(coalesce(new.uf,'')), ''));
  new.email    := lower(nullif(btrim(coalesce(new.email,'')), ''));
  new.nome_completo := nullif(btrim(coalesce(new.nome_completo,'')), '');
  new.atualizado_em := now();
  return new;
end $$;


--
-- Name: limites_sugeridos(text, real, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.limites_sugeridos(p_ativo text, p_mult_stop real DEFAULT 0.6, p_mult_alvo real DEFAULT 0.6) RETURNS TABLE(stop_pct real, alvo_pct real, amplitude real)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select (f.amplitude * p_mult_stop)::real,
         (f.amplitude * p_mult_alvo)::real,
         f.amplitude
    from faixa_papel f
   where f.ativo = upper(p_ativo);
$$;


--
-- Name: mercado(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mercado() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
  with hoje as (
    select ativo, valor, preco, volume, atualizado_em
      from cotacao_viva
     where preco > 0
       and (atualizado_em at time zone 'America/Sao_Paulo')::date
         = (now() at time zone 'America/Sao_Paulo')::date
  ),
  ontem as (
    select distinct on (b.ativo) b.ativo, b.m1, b.m2, b.m3
      from barra b
     where b.data < (now() at time zone 'America/Sao_Paulo')::date
     order by b.ativo, b.data desc
  )
  select jsonb_build_object(
    'em', (select max(atualizado_em) from hoje),
    'p',  coalesce(jsonb_object_agg(h.ativo, jsonb_build_array(
            round(h.preco::numeric, 4),
            round(h.valor::numeric, 6),
            round((o.m1 * (1 - 2.0/18) + h.preco * (2.0/18))::numeric, 4),
            round((o.m2 * (1 - 2.0/35) + h.preco * (2.0/35))::numeric, 4),
            round((o.m3 * (1 - 2.0/73) + h.preco * (2.0/73))::numeric, 4),
            case when h.ativo ~ '[0-9]$' and h.volume > 0
                 then round((h.volume * h.preco)::numeric, 0) end)),
          '{}'::jsonb))
  from hoje h
  join ontem o on o.ativo = h.ativo
 where o.m1 > 0 and o.m2 > 0 and o.m3 > 0;
$_$;


--
-- Name: montar_carteira_time(bigint, bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.montar_carteira_time(p_ciclo bigint, p_time bigint, p_data date) RETURNS text[]
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ativos    text[];
  v_corte     bigint;
  v_faltam    int;
  v_cands     text[];
  v_auto      text[];
  v_escolha   text[];
  v_min       int := 5;
  v_membros   int;
  v_teto      int;
begin
  select count(*) into v_membros
    from time_ciclo_membro m
   where m.ciclo_id = p_ciclo and m.time_id = p_time
     and m.carteira_id is not null;
  if v_membros < v_min then
    return null;
  end if;
  -- a temp é on commit drop: sem este drop, a segunda chamada dentro da
  -- mesma transação falha com "relation _cont already exists"
  drop table if exists _cont;
  create temp table _cont on commit drop as
    select p.ativo, count(distinct m.usuario_id)::bigint as cabecas,
           coalesce(u.liquidez, 0) as liq
      from time_ciclo_membro m
      join peso_atual p on p.carteira_id = m.carteira_id
      left join universo u on u.ativo = p.ativo
     where m.ciclo_id = p_ciclo and m.time_id = p_time
       and m.carteira_id is not null
       and p.peso > 0
     group by p.ativo, u.liquidez;
  select cabecas into v_corte
    from _cont order by cabecas desc, liq desc offset 9 limit 1;
  if v_corte is null then
    select array_agg(ativo order by cabecas desc, liq desc) into v_ativos from _cont;
    insert into time_carteira_dia (ciclo_id, time_id, data, ativos)
    values (p_ciclo, p_time, p_data, coalesce(v_ativos, '{}'))
    on conflict (ciclo_id, time_id, data) do update set ativos = excluded.ativos,
      montada_em = now();
    return v_ativos;
  end if;
  select array_agg(ativo order by cabecas desc, liq desc) into v_ativos
    from _cont where cabecas > v_corte;
  v_faltam := 10 - coalesce(array_length(v_ativos,1), 0);
  v_teto := greatest(v_faltam * 2, 4);
  select array_agg(ativo order by liq desc, ativo) into v_cands
    from (select ativo, liq from _cont where cabecas = v_corte
           order by liq desc, ativo limit v_teto) x;
  if coalesce(array_length(v_cands,1),0) > v_faltam then
    v_auto := v_cands[1:v_faltam];
    select e.escolha into v_escolha
      from time_empate e
     where e.ciclo_id = p_ciclo and e.time_id = p_time and e.data = p_data;
    if v_escolha is not null
       and array_length(v_escolha,1) = v_faltam
       and v_escolha <@ v_cands then
      v_ativos := v_ativos || v_escolha;
    else
      v_ativos := v_ativos || v_auto;
    end if;
    insert into time_empate (ciclo_id, time_id, data, vagas, candidatos, automatico)
    values (p_ciclo, p_time, p_data, v_faltam, v_cands, v_auto)
    on conflict (ciclo_id, time_id, data) do update
      set vagas = excluded.vagas, candidatos = excluded.candidatos,
          automatico = excluded.automatico;
  else
    v_ativos := v_ativos || coalesce(v_cands, '{}');
  end if;
  insert into time_carteira_dia (ciclo_id, time_id, data, ativos)
  values (p_ciclo, p_time, p_data, v_ativos)
  on conflict (ciclo_id, time_id, data) do update
    set ativos = excluded.ativos, montada_em = now();
  return v_ativos;
end;
$$;


--
-- Name: movimento_da_hora(date, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.movimento_da_hora(p_data date, p_hora integer) RETURNS TABLE(ativo text, preco real, anterior real, variacao real, modulo real, giro_hora real)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select h.ativo, h.preco,
         coalesce(a.preco, case when p_hora = 10 then h.abertura end) as anterior,
         (h.preco / nullif(coalesce(a.preco,
             case when p_hora = 10 then h.abertura end), 0) - 1)::real  as variacao,
         abs(h.preco / nullif(coalesce(a.preco,
             case when p_hora = 10 then h.abertura end), 0) - 1)::real  as modulo,
         (greatest(coalesce(h.volume,0) - coalesce(a.volume,0), 0) * h.preco)::real
                                                                       as giro_hora
    from cotacao_hora h
    left join cotacao_hora a on a.ativo = h.ativo and a.data = h.data
                            and a.hora = h.hora - 1
   where h.data = p_data and h.hora = p_hora
     and coalesce(a.preco, case when p_hora = 10 then h.abertura end) > 0;
$$;


--
-- Name: mt5_gravar(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mt5_gravar(dados jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n_bar int; n_osc int; d_min date; d_max date; papel text;
begin
  papel := coalesce(current_setting('request.jwt.claim.role', true),
                    current_setting('role', true), '');
  if papel <> 'service_role'
     and not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'so admin pode gravar cotacao (papel: %)', papel;
  end if;
  -- ⚠️ As MEDIAS vem prontas do MT5, junto do candle. Calcular no banco
  -- exigia historico suficiente para semear, e com 92 pregoes a media
  -- longa herdava o nivel dos primeiros fechamentos: no IBOV deu 178.257
  -- contra os ~174.500 do terminal — ACIMA do preco em vez de abaixo,
  -- invertendo a fase. O iMA calcula sobre todo o historico do terminal,
  -- entao o numero e IDENTICO ao que o usuario ve no grafico.
  -- Efeito colateral bom: os periodos saem do banco e ficam so no .mq5,
  -- fora do repositorio publico.
  with e as (
    select x.ativo, x.data, x.abre, x.max, x.min, x.fech, x.vol, x.m1, x.m2, x.m3
      from jsonb_to_recordset(dados)
        as x(ativo text, data date, abre real, max real, min real, fech real,
             vol real, m1 real, m2 real, m3 real)
     where x.ativo is not null and x.data is not null and x.fech > 0
  ), g as (
    insert into barra (ativo, data, abertura, maxima, minima, fechamento, volume, m1, m2, m3)
    select ativo, data, nullif(abre,0), nullif(max,0), nullif(min,0), fech,
           nullif(vol,0), nullif(m1,0), nullif(m2,0), nullif(m3,0) from e
    on conflict (ativo, data) do update
       set abertura = coalesce(excluded.abertura, barra.abertura),
           maxima   = coalesce(excluded.maxima,   barra.maxima),
           minima   = coalesce(excluded.minima,   barra.minima),
           volume   = coalesce(excluded.volume,   barra.volume),
           m1       = coalesce(excluded.m1, barra.m1),
           m2       = coalesce(excluded.m2, barra.m2),
           m3       = coalesce(excluded.m3, barra.m3),
           fechamento = excluded.fechamento
    returning 1
  )
  select count(*) into n_bar from g;
  select min(x.data), max(x.data) into d_min, d_max
    from jsonb_to_recordset(dados)
      as x(ativo text, data date, abre real, max real, min real, fech real);
  with a as (
    select distinct x.ativo from jsonb_to_recordset(dados)
      as x(ativo text, data date, abre real, max real, min real, fech real)
  ), p as (
    select b.ativo, b.data, b.fechamento,
           lag(b.fechamento) over (partition by b.ativo order by b.data) as ant
      from barra b where b.ativo in (select ativo from a)
  ), g2 as (
    insert into oscilacao (ativo, data, valor)
    select ativo, data, fechamento/ant - 1 from p
     where ant is not null and ant > 0 and data between d_min and d_max
    on conflict (ativo, data) do update set valor = excluded.valor
    returning 1
  )
  select count(*) into n_osc from g2;
  return jsonb_build_object('barras', n_bar, 'oscilacoes', n_osc);
end $$;


--
-- Name: mt5_papel_resposta(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mt5_papel_resposta(dados jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int; papel text;
begin
  papel := coalesce(current_setting('request.jwt.claim.role', true),
                    current_setting('role', true), '');
  if papel <> 'service_role'
     and not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'so admin pode responder (papel: %)', papel;
  end if;

  update papel_fila f
     set estado = case when x.ok then 'cotando' else 'nao_existe' end,
         motivo = x.motivo,
         respondido_em = now()
    from jsonb_to_recordset(dados) as x(ativo text, ok boolean, motivo text)
   where f.ativo = x.ativo;

  get diagnostics n = row_count;
  return jsonb_build_object('atualizados', n);
end $$;


--
-- Name: mt5_viva(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mt5_viva(dados jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int; papel text;
begin
  papel := coalesce(current_setting('request.jwt.claim.role', true),
                    current_setting('role', true), '');
  if papel <> 'service_role'
     and not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'so admin pode gravar cotacao (papel: %)', papel;
  end if;
  delete from cotacao_viva
   where ativo in (select x.ativo from jsonb_to_recordset(dados)
                     as x(ativo text, preco real, var real, ant real, abre real, vol real));
  insert into cotacao_viva (ativo, valor, preco, abertura, volume, atualizado_em)
  select x.ativo,
         coalesce(x.var, x.preco / nullif(x.ant, 0) - 1),
         x.preco, nullif(x.abre, 0), nullif(x.vol, 0), now()
    from jsonb_to_recordset(dados)
      as x(ativo text, preco real, var real, ant real, abre real, vol real)
   where x.ativo is not null
     and x.preco > 0
     and (x.var is not null or x.ant > 0);
  get diagnostics n = row_count;
  return jsonb_build_object('gravados', n, 'quando', now());
end $$;


--
-- Name: notif_duelo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_duelo() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare quem text;
begin
  select coalesce(p.apelido,'alguém') into quem from perfil p where p.id = new.desafiante;
  insert into notificacao (usuario_id, tipo, texto, rota)
  values (new.desafiado, 'duelo', quem || ' te desafiou para um duelo', '#/duelo');
  return new;
end $$;


--
-- Name: notif_lead(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_lead() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare rotulo text;
begin
  rotulo := case new.origem
    when 'aulas'    then 'Pedido de curso ou palestra'
    when 'contato'  then 'Recado pelo Fale conosco'
    when 'servicos' then 'Pedido de contato com especialista'
    when 'clube'    then 'Interesse no clube'
    else 'Novo pedido de contato' end;
  insert into notificacao (usuario_id, tipo, texto, rota)
  select p.id, 'lead',
         rotulo || coalesce(' — ' || new.nome, ''), '#/leads'
    from perfil p
   where p.admin = true;
  return new;
end $$;


--
-- Name: notif_msg(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_msg() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare quem text;
begin
  select coalesce(p.apelido,'alguém') into quem from perfil p where p.id = new.autor;
  insert into notificacao (usuario_id, tipo, texto, rota)
  select m.usuario_id, 'mensagem',
         quem || ' escreveu no mural do time', '#/meu-time'
    from time_membro m
   where m.time_id = new.time_id and m.usuario_id <> new.autor;
  return new;
end $$;


--
-- Name: notif_rebal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_rebal() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare nome text;
begin
  select c.nome into nome from carteira c where c.id = new.carteira_id;
  insert into notificacao (usuario_id, tipo, texto, rota)
  select s.usuario_id, 'carteira',
         'A carteira ' || coalesce(nome,'que você acompanha') || ' mudou',
         '#/carteira/' || new.carteira_id
    from seguidor s
   where s.carteira_id = new.carteira_id;
  return new;
end $$;


--
-- Name: novo_usuario(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.novo_usuario() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  primeiro boolean;
  pai      uuid;
  ape      text;
begin
  select count(*) = 0 into primeiro from perfil;

  ape := coalesce(nullif(trim(new.raw_user_meta_data->>'apelido'), ''),
                  'usuario_' || substr(new.id::text, 1, 6));
  -- se o apelido já existe, gruda um sufixo em vez de barrar o cadastro
  while exists (select 1 from perfil where apelido = ape) loop
    ape := ape || floor(random() * 10)::text;
  end loop;

  select id into pai from perfil
   where ref_code = upper(new.raw_user_meta_data->>'ref');

  insert into perfil (id, apelido, identidade, credencial, anos_mercado,
                      assinante, admin, ref_code, indicado_por)
  values (new.id, ape,
          coalesce(new.raw_user_meta_data->>'identidade', 'estudante'),
          coalesce(new.raw_user_meta_data->>'credencial', ''),
          coalesce((new.raw_user_meta_data->>'anos')::int, 0),
          primeiro, primeiro,
          upper(substr(md5(random()::text || new.id::text), 1, 6)),
          pai);
  return new;
end $$;


--
-- Name: painel(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.painel() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select jsonb_build_object(
    'carteiras', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'nome', c.nome, 'classe', cc.classe, 'apelido', p.apelido,
        'criada_em', c.criada_em, 'n_ativos', c.n_ativos,
        'bruta', c.bruta, 'liquida', c.liquida, 'caixa', c.caixa,
        'dias', r.dias, 'acumulado', r.acumulado, 'hoje', r.hoje,
        'semana', r.semana, 'mes', r.mes, 'sharpe', r.sharpe,
        'drawdown', r.drawdown, 'vs_ibov', r.vs_ibov))
      from carteira c
      join perfil p on p.id = c.usuario_id
      left join carteira_classe cc on cc.id = c.id
      left join resumo r on r.carteira_id = c.id
      where c.ativa), '[]'::jsonb),
    'pesos', coalesce((
      select jsonb_agg(jsonb_build_array(pa.carteira_id, pa.ativo, pa.peso))
      from peso_atual pa
      join carteira c on c.id = pa.carteira_id and c.ativa), '[]'::jsonb),
    'vivo', coalesce((
      select jsonb_object_agg(v.ativo, round(v.valor::numeric, 5))
      from cotacao_viva v where v.valor is not null), '{}'::jsonb),
    'quando', (select max(atualizado_em) from cotacao_viva)
  );
$$;


--
-- Name: papeis_pendentes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.papeis_pendentes() RETURNS TABLE(ativo text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select f.ativo from papel_fila f
   where f.estado = 'pendente'
   order by f.pedido_em
   limit 20;
$$;


--
-- Name: papel_em_uso(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.papel_em_uso(p_ativo text) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  select count(*)::int from peso_atual where ativo = p_ativo;
$$;


--
-- Name: pode_mexer(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pode_mexer(dono uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  select dono = auth.uid() or sou_admin()
$$;


--
-- Name: pontos(text, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pontos(p_tipo text, p_retorno real) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select case
    when p_tipo in ('alvo','gap_favor')  then  2
    when p_tipo in ('stop','gap_contra') then -2
    when p_retorno > 0                   then  1     -- fechamento ou ambiguo
    when p_retorno < 0                   then -1
    else 0
  end;
$$;


--
-- Name: proximo_pregao(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.proximo_pregao(a_partir date DEFAULT NULL::date) RETURNS date
    LANGUAGE sql STABLE
    AS $$
  select case extract(isodow from coalesce(a_partir, hoje_br()))
           when 5 then coalesce(a_partir, hoje_br()) + 3   -- sexta  → segunda
           when 6 then coalesce(a_partir, hoje_br()) + 2   -- sábado → segunda
           when 7 then coalesce(a_partir, hoje_br()) + 1   -- domingo→ segunda
           else        coalesce(a_partir, hoje_br()) + 1
         end;
$$;


--
-- Name: proximo_pregao_br(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.proximo_pregao_br() RETURNS date
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select proximo_pregao(hoje_br());
$$;


--
-- Name: quant_medias(integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quant_medias(p_curta integer DEFAULT 17, p_media integer DEFAULT 34, p_longa integer DEFAULT 72, p_janela integer DEFAULT 90) RETURNS TABLE(ativo text, pregoes integer, fech real, ema17 real, ema34 real, ema72 real, dist real, amplitude real, liquidez real, serie real[], serie72 real[])
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $_$
declare
  r record; v record;
  e1 real; e2 real; e3 real;
  k1 real; k2 real; k3 real;
  s1 real; s2 real; s3 real;
  n int; amp real; ult real; ser real[]; ser3 real[];
begin
  k1 := 2.0 / (p_curta + 1);
  k2 := 2.0 / (p_media + 1);
  k3 := 2.0 / (p_longa + 1);
  for r in
    select b.ativo as a, count(*) as q,
           case when b.ativo ~ '[0-9]$' then
             (select avg(x.volume * x.fechamento)
                from (select b2.volume, b2.fechamento
                        from barra b2
                       where b2.ativo = b.ativo and b2.volume > 0
                       order by b2.data desc limit 21) x)
           end as liq
      from barra b group by b.ativo
  loop
    if r.q < p_media then continue; end if;
    e1 := null; e2 := null; e3 := null;
    s1 := 0; s2 := 0; s3 := 0;
    n := 0; amp := 0; ult := null; ser := '{}'; ser3 := '{}';
    for v in select b.fechamento as f, b.maxima as mx, b.minima as mn
               from barra b where b.ativo = r.a order by b.data loop
      n := n + 1;
      if n <= p_curta then s1 := s1 + v.f; end if;
      if n =  p_curta then e1 := s1 / p_curta; end if;
      if n >  p_curta then e1 := v.f * k1 + e1 * (1 - k1); end if;
      if n <= p_media then s2 := s2 + v.f; end if;
      if n =  p_media then e2 := s2 / p_media; end if;
      if n >  p_media then e2 := v.f * k2 + e2 * (1 - k2); end if;
      if n <= p_longa then s3 := s3 + v.f; end if;
      if n =  p_longa then e3 := s3 / p_longa; end if;
      if n >  p_longa then e3 := v.f * k3 + e3 * (1 - k3); end if;
      if v.mx is not null and v.mn is not null and v.f > 0 then
        amp := amp + (v.mx - v.mn) / v.f;
      end if;
      ult := v.f;
      ser  := ser  || v.f;
      ser3 := ser3 || e3;
    end loop;
    if e1 is null or e2 is null or e2 = 0 then continue; end if;
    ativo := r.a; pregoes := n; fech := ult;
    ema17 := e1; ema34 := e2; ema72 := e3;
    dist := e1 / e2 - 1;
    amplitude := amp / n;
    liquidez := r.liq;
    serie   := ser [greatest(1, array_length(ser ,1) - p_janela + 1) : array_length(ser ,1)];
    serie72 := ser3[greatest(1, array_length(ser3,1) - p_janela + 1) : array_length(ser3,1)];
    return next;
  end loop;
end $_$;


--
-- Name: recalcular_exposicao(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalcular_exposicao(cid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare l real; s real; marco date;
begin
  select max(valida_de) into marco from posicao where carteira_id = cid;
  select coalesce(sum(peso) filter (where peso > 0), 0),
        -coalesce(sum(peso) filter (where peso < 0), 0)
    into l, s
    from posicao where carteira_id = cid and valida_de = marco;
  update carteira set
    bruta    = l + s,
    liquida  = l - s,
    -- ⚠️ Era `100 - (l - s)`, com a nota "venda a descoberto ENTRA
    -- dinheiro". Entra mesmo — mas fica RETIDO como garantia da posição,
    -- não vira caixa livre. Numa vendida de 88,7% a conta antiga dava
    -- 188,7% de caixa, e numa long × short com vendido maior que
    -- comprado passava de 100 também. Caixa é só o que sobra do
    -- patrimônio depois do que está comprado: nunca acima de 100, nunca
    -- negativo. A tela já contornava na exibição; o banco guardava errado.
    caixa    = greatest(0, least(100, 100 - l)),
    n_ativos = (select count(*) from posicao
                 where carteira_id = cid and valida_de = marco)
  where id = cid;
end $$;


--
-- Name: recalcular_exposicao_atual(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalcular_exposicao_atual(cid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare l real; s real;
begin
  select coalesce(sum(peso) filter (where peso > 0), 0),
        -coalesce(sum(peso) filter (where peso < 0), 0)
    into l, s from peso_atual where carteira_id = cid;
  update carteira set
    bruta = l + s, liquida = l - s,
    -- ⚠️ Era `100 - (l - s)`: numa vendida de 88,7% isso dá 188,7, e a
    -- carteira NÃO tem 188% em caixa. O dinheiro que entra da venda a
    -- descoberto fica retido como garantia, não vira caixa livre. Caixa
    -- é só o que sobra do patrimônio depois do que está comprado — nunca
    -- passa de 100, nunca é negativo. A tela já contornava na exibição;
    -- o banco continuava guardando o número errado.
    caixa = greatest(0, least(100, 100 - l)),
    n_ativos = (select count(*) from peso_atual where carteira_id = cid)
  where id = cid;
end $$;


--
-- Name: recalcular_resumo(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalcular_resumo(cid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  n int; ult date; idx real; ac real; hj real;
  sem real; ms real; an real; sh real; dd real; vl real; vi real;
  md real; dp real; f real[];
  quebrou boolean;
begin
  select count(*), max(data) into n, ult from retorno_dia where carteira_id = cid;
  if n = 0 then
    insert into resumo (carteira_id, dias) values (cid, 0)
    on conflict (carteira_id) do update set dias = 0, atualizado = now();
    return;
  end if;

  select indice, retorno into idx, hj from retorno_dia
   where carteira_id = cid order by data desc limit 1;
  ac := idx/100.0 - 1;

  -- ⚠️ Carteira que perdeu o capital inteiro. Sem esta marca, o filtro
  -- `retorno > -1` logo abaixo descartava o dia da ruína e semana, mês e
  -- ano saíam calculados como se a quebra nunca tivesse acontecido.
  quebrou := exists (select 1 from retorno_dia
                      where carteira_id = cid and indice <= 0);

  -- períodos: composto sobre os últimos N pregões
  select exp(sum(ln(1+retorno))) - 1 into sem from
    (select retorno from retorno_dia where carteira_id = cid and retorno > -1
      order by data desc limit 5) t;
  select exp(sum(ln(1+retorno))) - 1 into ms from
    (select retorno from retorno_dia where carteira_id = cid and retorno > -1
      order by data desc limit 21) t;
  select exp(sum(ln(1+retorno))) - 1 into an from
    (select retorno from retorno_dia where carteira_id = cid and retorno > -1
      and data >= date_trunc('year', ult)) t;

  -- risco: só com histórico suficiente, senão é ruído com cara de número
  if n >= 20 and not quebrou then
    select avg(retorno), stddev_samp(retorno) into md, dp
      from retorno_dia where carteira_id = cid;
    if dp > 0 then
      vl := dp * sqrt(252);
      sh := (md - (power(1 + taxa_rf_ano()/100.0, 1.0/252) - 1)) / dp * sqrt(252);
    end if;
  end if;

  select min(q) into dd from (
    select indice / max(indice) over (order by data) - 1 as q
      from retorno_dia where carteira_id = cid) t;

  -- contra o Ibovespa, no mesmo período da carteira
  select ac - (exp(sum(ln(1+o.valor))) - 1) into vi
    from oscilacao o
   where o.ativo = 'IBOV'
     and o.data >= (select min(data) from retorno_dia where carteira_id = cid)
     and o.data <= ult and o.valor > -1;

  -- ⚠️ Quebrou: perdeu tudo. Todo período que contém o dia da ruína é
  -- −100%, e Sharpe sobre uma série que termina em zero não significa nada.
  if quebrou then
    ac := -1; sem := -1; ms := -1; an := -1; dd := -1; sh := null; vl := null;
  end if;

  select array_agg(retorno order by data) into f from
    (select data, retorno from retorno_dia where carteira_id = cid
      order by data desc limit 24) t;

  insert into resumo (carteira_id, dias, ultima_data, indice, acumulado, hoje,
                      semana, mes, ano, sharpe, drawdown, vol, vs_ibov, fita, atualizado)
  values (cid, n, ult, idx, ac, hj, sem, ms, an, sh, coalesce(dd,0), vl, vi, f, now())
  on conflict (carteira_id) do update set
    dias=excluded.dias, ultima_data=excluded.ultima_data, indice=excluded.indice,
    acumulado=excluded.acumulado, hoje=excluded.hoje, semana=excluded.semana,
    mes=excluded.mes, ano=excluded.ano, sharpe=excluded.sharpe,
    drawdown=excluded.drawdown, vol=excluded.vol, vs_ibov=excluded.vs_ibov,
    fita=excluded.fita, atualizado=now();
end $$;


--
-- Name: refazer_pesos(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refazer_pesos(cid bigint, ate date) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  m date; d date; r real;
begin
  select max(valida_de) into m
    from posicao where carteira_id = cid and valida_de <= ate;
  if m is null then return; end if;

  -- volta ao declarado do marco vigente
  delete from peso_atual where carteira_id = cid;
  insert into peso_atual (carteira_id, ativo, peso, marco)
  select carteira_id, ativo, sum(peso), m
    from posicao where carteira_id = cid and valida_de = m
   group by carteira_id, ativo;

  -- e reaplica pregão a pregão, na ordem, usando o retorno já gravado
  for d, r in
    select data, retorno from retorno_dia
     where carteira_id = cid and data >= m and data < ate
     order by data
  loop
    update peso_atual pa
       set peso = pa.peso * (1 + coalesce(o.valor, 0)) / (1 + r)
      from (select ativo, valor from oscilacao where data = d) o
     where pa.carteira_id = cid and pa.ativo = o.ativo and (1 + r) <> 0;

    -- reproduz o rebalanceamento daquele dia, se houve
    if exists (select 1 from rebalanceamento where carteira_id = cid and data = d) then
      delete from peso_atual where carteira_id = cid;
      insert into peso_atual (carteira_id, ativo, peso, marco)
      select carteira_id, ativo, sum(peso), m
        from posicao where carteira_id = cid and valida_de = m
       group by carteira_id, ativo;
    end if;
  end loop;
end $$;


--
-- Name: regra_em(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.regra_em(cid bigint, dia date) RETURNS TABLE(rebalancear text, banda_pct real)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select r.rebalancear, r.banda_pct from regra r
   where r.carteira_id = cid and r.valida_de <= dia
   order by r.valida_de desc limit 1;
$$;


--
-- Name: renomear_carteira(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.renomear_carteira(cid bigint, novo_nome text, nova_desc text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not exists (select 1 from carteira where id = cid and usuario_id = auth.uid()) then
    raise exception 'essa carteira não é sua';
  end if;
  if exists (select 1 from carteira
              where usuario_id = auth.uid() and ativa and id <> cid
                and lower(trim(nome)) = lower(trim(novo_nome))) then
    raise exception 'você já tem uma carteira com esse nome';
  end if;
  update carteira set nome = trim(novo_nome), descricao = coalesce(nova_desc,'')
   where id = cid;
  return true;
end $$;


--
-- Name: retorno_periodo(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retorno_periodo(p_carteira bigint, p_de date, p_ate date) RETURNS real
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with base as (
    select indice from retorno_dia
     where carteira_id = p_carteira and data < p_de
     order by data desc limit 1),
  fim as (
    select indice from retorno_dia
     where carteira_id = p_carteira and data between p_de and p_ate
     order by data desc limit 1),
  ini as (
    select indice from retorno_dia
     where carteira_id = p_carteira and data between p_de and p_ate
     order by data asc limit 1)
  select ((select indice from fim)
        / nullif(coalesce((select indice from base), (select indice from ini)), 0)
        - 1)::real;
$$;


--
-- Name: robo_fechar_dia(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_fechar_dia(d date DEFAULT NULL::date) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_dia   date;
  v_saida text; v_times int; v_intra text; v_duelo int; v_copa text;
  v_agora timestamp := (now() at time zone 'America/Sao_Paulo');
begin
  -- O MT5 exporta DURANTE o pregão, então a oscilacao do dia corrente já
  -- existe desde cedo, com preço intradiário. Sem esta trava, max(data)
  -- apontava para hoje e o robô da manhã fechava o dia que nem começou —
  -- e o `jafechou` do fechar_dia impedia qualquer correção depois.
  -- Só apura o dia corrente depois das 18h; antes disso, o último anterior.
  v_dia := coalesce(d, (
    select max(o.data) from oscilacao o
     where o.data < v_agora::date
        or (o.data = v_agora::date and extract(hour from v_agora) >= 18)));
  if v_dia is null then return 'não há pregão encerrado para apurar'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin
                              order by criado_em limit 1))::text, true);
  v_saida := fechar_dia(v_dia);
  begin v_times := fechar_dia_times(v_dia);
  exception when others then v_times := -1; end;
  begin
    perform abrir_rodadas();
    v_intra := apurar_rodadas_vencidas();
  exception when others then v_intra := 'FALHOU'; end;
  begin v_copa := tocar_copa();
  exception when others then v_copa := 'FALHOU'; end;
  begin v_duelo := encerrar_duelos();
  exception when others then v_duelo := -1; end;
  return v_saida
       || case when v_times >= 0 then ' · times: ' || v_times else ' · times: FALHOU' end
       || ' · intraday: ' || coalesce(v_intra, '—')
       || ' · copa: ' || coalesce(v_copa, '—')
       || case when v_duelo >= 0 then ' · duelos: ' || v_duelo else ' · duelos: FALHOU' end;
end;
$$;


--
-- Name: robo_gravar_barra(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_gravar_barra(dados jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int := 0;
begin
  insert into barra (ativo, data, abertura, maxima, minima, fechamento)
  select upper(x->>'ativo'), (x->>'data')::date,
         (x->>'abertura')::real, (x->>'maxima')::real,
         (x->>'minima')::real,   (x->>'fechamento')::real
    from jsonb_array_elements(dados) x
   where x->>'abertura' is not null and x->>'fechamento' is not null
  on conflict (ativo, data) do update
     set abertura = excluded.abertura, maxima = excluded.maxima,
         minima   = excluded.minima,   fechamento = excluded.fechamento;

  get diagnostics n = row_count;
  return n;
end $$;


--
-- Name: robo_gravar_oscilacao(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_gravar_oscilacao(dados jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  perform gravar_oscilacao(dados);
end $$;


--
-- Name: robo_gravar_universo(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_gravar_universo(dados jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  perform gravar_universo(dados);
end $$;


--
-- Name: robo_gravar_viva(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_gravar_viva(dados jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int := 0;
begin
  insert into cotacao_viva (ativo, valor, preco, atualizado_em)
  select upper(x->>'ativo'), (x->>'valor')::real,
         nullif(x->>'preco','')::real, now()
    from jsonb_array_elements(dados) x
   where x->>'valor' is not null
  on conflict (ativo) do update
     set valor = excluded.valor, preco = excluded.preco,
         atualizado_em = excluded.atualizado_em;

  get diagnostics n = row_count;
  return n;
end $$;


--
-- Name: sair_da_copa(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sair_da_copa() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  agora  timestamp := (now() at time zone 'America/Sao_Paulo');
  hoje   date := agora::date;
  v_copa bigint; v_data date;
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  -- só dá para sair enquanto a inscrição está aberta: depois do sorteio a
  -- chave já está montada e sair deixaria um confronto sem adversário
  select id, data into v_copa, v_data
    from copa
   where situacao = 'inscricoes'
     and (data > hoje or (data = hoje and extract(hour from agora) < 10))
   order by data limit 1;
  if v_copa is null then return 'não há inscrição aberta para cancelar'; end if;
  delete from copa_vaga
   where copa_id = v_copa and usuario_id = auth.uid();
  if not found then return 'você não estava nessa chave'; end if;
  -- as vagas seguintes sobem, para a ordem não ficar com buraco.
  -- copa_vaga não tem coluna id: a linha é identificada por copa_id + usuario_id
  with fila as (
    select usuario_id, row_number() over (order by ordem) as nova
      from copa_vaga where copa_id = v_copa)
  update copa_vaga v set ordem = f.nova
    from fila f
   where v.copa_id = v_copa and v.usuario_id = f.usuario_id;
  return 'inscrição de ' || to_char(v_data, 'DD/MM') || ' cancelada';
end $$;


--
-- Name: salvar_lead(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.salvar_lead(dados jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare em text;
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  select u.email into em from auth.users u where u.id = auth.uid();

  insert into lead (usuario_id, email, nome_completo, telefone, cpf,
                    cep, logradouro, numero, complemento, bairro, cidade, uf, origem)
  values (auth.uid(), em,
          dados->>'nome_completo', dados->>'telefone', dados->>'cpf',
          dados->>'cep', dados->>'logradouro', dados->>'numero',
          dados->>'complemento', dados->>'bairro', dados->>'cidade', dados->>'uf',
          coalesce(dados->>'origem','assinatura'))
  on conflict (usuario_id) do update set
    nome_completo = coalesce(excluded.nome_completo, lead.nome_completo),
    telefone      = coalesce(excluded.telefone,      lead.telefone),
    cpf           = coalesce(excluded.cpf,           lead.cpf),
    cep           = coalesce(excluded.cep,           lead.cep),
    logradouro    = coalesce(excluded.logradouro,    lead.logradouro),
    numero        = coalesce(excluded.numero,        lead.numero),
    complemento   = coalesce(excluded.complemento,   lead.complemento),
    bairro        = coalesce(excluded.bairro,        lead.bairro),
    cidade        = coalesce(excluded.cidade,        lead.cidade),
    uf            = coalesce(excluded.uf,            lead.uf),
    origem        = excluded.origem;
exception
  when unique_violation then raise exception 'esse CPF já está em outra conta';
  when check_violation  then raise exception 'CPF, CEP, UF ou telefone inválido';
end $$;


--
-- Name: seguidores_por_carteira(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seguidores_por_carteira() RETURNS TABLE(carteira_id bigint, n bigint)
    LANGUAGE sql
    AS $$
  SELECT carteira_id, COUNT(*)::bigint
  FROM seguidor
  GROUP BY carteira_id;
$$;


--
-- Name: seguir(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seguir(cid bigint, valor boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  if valor then
    -- a exigência de assinante saiu daqui: não existem assinantes
    if not exists (select 1 from carteira c where c.id = cid and c.ativa) then
      raise exception 'carteira não encontrada';
    end if;
    insert into seguidor (usuario_id, carteira_id)
    values (auth.uid(), cid) on conflict do nothing;
  else
    delete from seguidor where usuario_id = auth.uid() and carteira_id = cid;
  end if;
end $$;


--
-- Name: sincronizar_assinantes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sincronizar_assinantes() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int;
begin
  with vigente as (
    select distinct usuario_id from assinatura
     where hoje_br() between inicio and fim
  ), mudou as (
    update perfil p
       set assinante = (p.id in (select usuario_id from vigente))
     where p.assinante is distinct from (p.id in (select usuario_id from vigente))
       and not p.bloqueado
    returning 1
  )
  select count(*) into n from mudou;
  return n;
end $$;


--
-- Name: somar_intraday(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.somar_intraday(p_rodada bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r     record;
  p     record;
  v_seq int;
  v_mul numeric;
  n     int := 0;
begin
  select * into r from rodada where id = p_rodada;

  for p in
    select v.usuario_id,
           count(*) filter (where v.acertou)     as acertos,
           sum(coalesce(v.pontos,0))::int        as bruto
      from voto v where v.rodada_id = p_rodada
     group by v.usuario_id
  loop
    -- a sequência sobe com pelo menos um acerto na rodada, e zera sem nenhum
    select coalesce(sequencia, 0) into v_seq
      from intraday_sequencia where usuario_id = p.usuario_id;
    v_seq := coalesce(v_seq, 0);
    v_seq := case when p.acertos > 0 then least(v_seq + 1, 6) else 0 end;

    -- 1,0 · 1,2 · 1,4 · 1,6 · 1,8 · 2,0 — teto em 2x para o ranking não travar
    v_mul := 1.0 + 0.2 * greatest(v_seq - 1, 0);

    insert into intraday_sequencia (usuario_id, sequencia, maior, ultima_rodada)
    values (p.usuario_id, v_seq, v_seq, p_rodada)
    on conflict (usuario_id) do update
      set sequencia = v_seq,
          maior = greatest(intraday_sequencia.maior, v_seq),
          ultima_rodada = p_rodada;

    insert into intraday_pessoa (usuario_id, data, rodadas, acertos, pontos, sequencia)
    values (p.usuario_id, r.data, 1, p.acertos,
            round(p.bruto * v_mul)::int, v_seq)
    on conflict (usuario_id, data) do update
      set rodadas = intraday_pessoa.rodadas + 1,
          acertos = intraday_pessoa.acertos + p.acertos,
          pontos  = intraday_pessoa.pontos + round(p.bruto * v_mul)::int,
          sequencia = v_seq;

    n := n + 1;
  end loop;
  return n;
end;
$$;


--
-- Name: sou_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select p.admin from perfil p where p.id = auth.uid()), false)
$$;


--
-- Name: sou_capitao(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_capitao(p_time bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (select 1 from time_ t
                 where t.id = p_time and t.capitao = auth.uid()
                   and t.encerrado_em is null);
$$;


--
-- Name: sou_do_time(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_do_time(p_time bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (select 1 from time_membro m
                 where m.time_id = p_time and m.usuario_id = auth.uid()
                   and m.situacao = 'ativo');
$$;


--
-- Name: taxa_rf_ano(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.taxa_rf_ano() RETURNS real
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce((select valor from parametro where chave = 'cdi_ano'), 15.0);
$$;


--
-- Name: FUNCTION taxa_rf_ano(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.taxa_rf_ano() IS 'Taxa da renda fixa ao ano, em pontos percentuais. Fonte única: parametro.cdi_ano. Para mudar: update parametro set valor = X where chave = ''cdi_ano''; Ninguém mais deve cravar essa taxa.';


--
-- Name: taxa_rf_dia(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.taxa_rf_dia() RETURNS real
    LANGUAGE sql STABLE
    AS $$
  select (power(1 + taxa_rf_ano()/100.0, 1.0/252) - 1)::real;
$$;


--
-- Name: tirar_assinatura(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tirar_assinatura(p_apelido text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare uid uuid;
begin
  if not sou_admin() then raise exception 'só admin'; end if;
  select id into uid from perfil where lower(apelido) = lower(p_apelido);
  if uid is null then return 'não achei ' || p_apelido; end if;
  update assinatura set fim = hoje_br() - 1
   where usuario_id = uid and fim >= hoje_br();
  perform sincronizar_assinantes();
  return p_apelido || ' deixou de ser assinante';
end $$;


--
-- Name: tocar_copa(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tocar_copa() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  agora  timestamp := (now() at time zone 'America/Sao_Paulo');
  d      date := agora::date;
  v_copa bigint;
begin
  -- Sempre deixa a próxima aberta, antes de qualquer outra coisa: quem chega
  -- depois das 10h se inscreve para o pregão seguinte em vez de ficar sem
  -- lugar nenhum. Vem antes do 'fim de semana' de propósito, senão sábado e
  -- domingo ninguém consegue entrar na de segunda.
  perform abrir_copa(d + 1);

  v_copa := abrir_copa(d);
  if v_copa is null then return 'fim de semana'; end if;
  -- às 10h a inscrição fecha e a chave é sorteada, uma hora antes das
  -- quartas. Antes disso não há o que fazer: a copa está recebendo gente.
  if extract(hour from agora) >= 10
     and exists (select 1 from copa where id = v_copa and situacao = 'inscricoes')
  then
    return chavear_copa(v_copa);
  end if;
  return apurar_copa(v_copa);
end;
$$;


--
-- Name: trava_aposta(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trava_aposta() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int;
begin
  if new.data <> proximo_pregao() then
    raise exception 'aposta vale para o próximo pregão (%), não para %',
      proximo_pregao(), new.data;
  end if;

  if not exists (select 1 from universo u where u.ativo = upper(new.ativo)) then
    raise exception 'papel % não está no universo', upper(new.ativo);
  end if;

  select count(*) into n from aposta
   where usuario_id = new.usuario_id and data = new.data;
  if n >= 10 then
    raise exception 'máximo de 10 papéis por pregão';
  end if;

  new.ativo := upper(new.ativo);
  return new;
end $$;


--
-- Name: trava_classe(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trava_classe() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if not sou_admin() then
    if old.classe is not null and new.classe is distinct from old.classe then
      raise exception 'a classe da carteira não muda. Crie outra carteira com a classe nova.';
    end if;
  end if;
  return new;
end $$;


--
-- Name: trava_privilegio(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trava_privilegio() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not sou_admin() then
    new.id           := old.id;
    new.admin        := old.admin;
    new.assinante    := old.assinante;
    new.bloqueado    := old.bloqueado;
    new.indicado_por := old.indicado_por;
    new.criado_em    := old.criado_em;
  end if;
  return new;
end $$;


--
-- Name: trava_saida_membro(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trava_saida_membro() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.situacao is distinct from old.situacao
     and not sou_capitao(old.time_id) and not sou_admin() then
    raise exception 'Quem inclui e quem remove do time é o capitão.';
  end if;
  return new;
end;
$$;


--
-- Name: trava_voto(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trava_voto() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare r record;
begin
  select * into r from rodada where id = new.rodada_id;
  if r is null then raise exception 'rodada não existe'; end if;
  -- o voto fecha quando a hora começa a correr, nao quando ela termina:
  -- a rodada das 11h cobre 10h→11h, entao o palpite tem de estar dado
  -- as 10h. abre_em e esse instante, e e tambem quando os votos dos
  -- outros ficam visiveis.
  if now() >= r.abre_em then
    raise exception 'o voto da rodada das %h fechou às %',
      r.hora, to_char(r.abre_em at time zone 'America/Sao_Paulo', 'HH24:MI');
  end if;
  if new.jogo not in ('sobe','cai','volume','petr') then
    raise exception 'jogo desconhecido: %', new.jogo;
  end if;
  if new.jogo <> 'petr' and not exists (
       select 1 from rodada_papel p
        where p.rodada_id = new.rodada_id and p.jogo = new.jogo
          and p.ativo = new.palpite) then
    raise exception '% não está entre os papéis sorteados deste jogo', new.palpite;
  end if;
  if new.jogo = 'petr' and new.palpite not in ('acima','abaixo') then
    raise exception 'o palpite da PETR4 é acima ou abaixo';
  end if;
  return new;
end;
$$;


--
-- Name: trocar_apelido(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trocar_apelido(novo text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  if not apelido_livre(novo) then
    raise exception 'apelido inválido ou já em uso';
  end if;
  update perfil set apelido = btrim(novo) where id = auth.uid();
exception when unique_violation then
  raise exception 'apelido já em uso';
end $$;


--
-- Name: valida_classe(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valida_classe(cid bigint, quando date) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  cl text; n int; bruta real; liq real; pos int; neg int;
begin
  select classe into cl from carteira where id = cid;
  if cl is null then return; end if;
  select count(*), coalesce(sum(abs(peso)),0), coalesce(sum(peso),0),
         count(*) filter (where peso > 0),
         count(*) filter (where peso < 0)
    into n, bruta, liq, pos, neg
    from posicao where carteira_id = cid and valida_de = quando;
  if n = 0 then return; end if;

  if cl = 'diversificada' then
    if neg > 0 then raise exception 'esta carteira só compra: tire os pesos negativos.'; end if;
    if n <> 10 then raise exception 'Comprada exige exatamente 10 papéis (está com %).', n; end if;
    if abs(bruta - 100) > 0.51 then
      raise exception 'Comprada não deixa caixa: a soma tem que dar 100 por cento (está em %).', round(bruta); end if;

  elsif cl = 'sessenta_quarenta' then
    if neg > 0 then raise exception 'esta carteira só compra: tire os pesos negativos.'; end if;
    if bruta < 19.99 or bruta > 50.01 then
      raise exception 'em ações a soma tem que ficar entre 20 e 50 por cento (está em %).', round(bruta); end if;

  elsif cl = 'long_short' then
    if pos = 0 or neg = 0 then
      raise exception 'long & short precisa de pelo menos uma compra e uma venda.'; end if;
    if bruta > 200.01 then
      raise exception 'a soma dos pesos é % por cento; o teto é 200.', round(bruta); end if;
    if abs(liq) > 100.01 then
      raise exception 'a diferença entre compras e vendas é % por cento; o limite é 100.', round(abs(liq)); end if;

  elsif cl = 'vendida' then
    if pos > 0 then raise exception 'esta carteira só vende: tire os pesos positivos.'; end if;
    if bruta > 100.01 then
      raise exception 'a soma vendida é % por cento; o limite é 100 do patrimônio.', round(bruta); end if;
  end if;
end $$;


--
-- Name: vivo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vivo() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with viva as (
    select ativo, valor, atualizado_em
      from cotacao_viva
     where valor is not null
       and (atualizado_em at time zone 'America/Sao_Paulo')::date
         = (now()         at time zone 'America/Sao_Paulo')::date
  ),
  parcial as (
    select p.carteira_id,
           sum(p.peso / 100.0 * v.valor) as retorno,
           count(v.valor)                as com_cotacao,
           count(*)                      as papeis
      from peso_atual p
      left join viva v on v.ativo = p.ativo
     group by p.carteira_id
  )
  select jsonb_build_object(
    'em', (select max(atualizado_em) from viva),
    'c',  coalesce(jsonb_agg(jsonb_build_array(
            pa.carteira_id, round(pa.retorno::numeric, 6),
            pa.com_cotacao, pa.papeis)) filter (where pa.com_cotacao > 0),
          '[]'::jsonb))
  from parcial pa
  join carteira c on c.id = pa.carteira_id and c.ativa;
$$;


--
-- Name: aposta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.aposta (
    id bigint NOT NULL,
    usuario_id uuid DEFAULT auth.uid() NOT NULL,
    data date NOT NULL,
    ativo text NOT NULL,
    direcao character(1) NOT NULL,
    criada_em timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT aposta_direcao_check CHECK ((direcao = ANY (ARRAY['C'::bpchar, 'V'::bpchar])))
);


--
-- Name: aposta_apurada; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.aposta_apurada AS
 SELECT a.id,
    a.usuario_id,
    a.data,
    a.ativo,
    a.direcao,
    r.tipo,
    r.entrada,
    r.stop,
    r.alvo,
    r.saida,
    r.retorno,
    r.pts
   FROM (public.aposta a
     CROSS JOIN LATERAL public.apurar_aposta(a.ativo, a.data, (a.direcao)::text) r(tipo, entrada, stop, alvo, saida, retorno, pts));


--
-- Name: aposta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.aposta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: aposta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.aposta_id_seq OWNED BY public.aposta.id;


--
-- Name: assinatura; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assinatura (
    id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    inicio date DEFAULT public.hoje_br() NOT NULL,
    fim date NOT NULL,
    valor real,
    meio text,
    obs text,
    criada_em timestamp with time zone DEFAULT now()
);


--
-- Name: assinatura_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assinatura_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assinatura_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assinatura_id_seq OWNED BY public.assinatura.id;


--
-- Name: barra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.barra (
    ativo text NOT NULL,
    data date NOT NULL,
    abertura real NOT NULL,
    maxima real NOT NULL,
    minima real NOT NULL,
    fechamento real NOT NULL,
    volume real,
    m1 real,
    m2 real,
    m3 real
);


--
-- Name: carteira; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.carteira (
    id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    nome text NOT NULL,
    descricao text DEFAULT ''::text,
    bruta real DEFAULT 0,
    liquida real DEFAULT 0,
    caixa real DEFAULT 0,
    n_ativos integer DEFAULT 0,
    criada_em date DEFAULT CURRENT_DATE,
    ativa boolean DEFAULT true,
    classe text,
    rebalancear text DEFAULT 'nunca'::text NOT NULL,
    banda_pct real DEFAULT 5 NOT NULL,
    encerrada_em date,
    CONSTRAINT carteira_banda_valida CHECK (((banda_pct > (0)::double precision) AND (banda_pct <= (100)::double precision))),
    CONSTRAINT carteira_classe_valida CHECK (((classe IS NULL) OR (classe = ANY (ARRAY['all_in'::text, 'diversificada'::text, 'sessenta_quarenta'::text, 'long_short'::text, 'vendida'::text])))),
    CONSTRAINT carteira_rebalancear_valido CHECK ((rebalancear = ANY (ARRAY['nunca'::text, 'semanal'::text, 'mensal'::text, 'anual'::text, 'banda'::text])))
);


--
-- Name: perfil; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.perfil (
    id uuid NOT NULL,
    apelido text NOT NULL,
    identidade text DEFAULT 'estudante'::text,
    credencial text DEFAULT ''::text,
    anos_mercado integer DEFAULT 0,
    assinante boolean DEFAULT false,
    admin boolean DEFAULT false,
    ref_code text,
    indicado_por uuid,
    criado_em timestamp with time zone DEFAULT now(),
    bloqueado boolean DEFAULT false NOT NULL,
    nome_publico text,
    exibir text DEFAULT 'apelido'::text NOT NULL,
    CONSTRAINT apelido_formato CHECK (((apelido ~ '^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$'::text) AND ((char_length(apelido) >= 3) AND (char_length(apelido) <= 24)))),
    CONSTRAINT apelido_reservado CHECK ((lower(apelido) <> ALL (ARRAY['admin'::text, 'administrador'::text, 'adm'::text, 'root'::text, 'sistema'::text, 'suporte'::text, 'moderador'::text, 'contato'::text, 'oficial'::text, 'saldopositivo'::text, 'saldo-positivo'::text, 'ranking'::text]))),
    CONSTRAINT perfil_exibir_valido CHECK ((exibir = ANY (ARRAY['apelido'::text, 'nome'::text, 'anonimo'::text])))
);


--
-- Name: carteira_classe; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.carteira_classe AS
 SELECT c.id,
    c.classe,
    c.rebalancear,
    c.banda_pct,
    c.criada_em,
    c.ativa,
    c.encerrada_em,
        CASE p.exibir
            WHEN 'anonimo'::text THEN 'anônimo'::text
            WHEN 'nome'::text THEN COALESCE(NULLIF(btrim(p.nome_publico), ''::text), p.apelido)
            ELSE p.apelido
        END AS autor
   FROM (public.carteira c
     JOIN public.perfil p ON ((p.id = c.usuario_id)));


--
-- Name: oscilacao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oscilacao (
    ativo text NOT NULL,
    data date NOT NULL,
    valor real NOT NULL,
    data_cot date
);


--
-- Name: referencia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referencia (
    ativo text NOT NULL,
    nome text NOT NULL,
    ordem integer DEFAULT 0 NOT NULL
);


--
-- Name: retorno_dia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retorno_dia (
    carteira_id bigint NOT NULL,
    data date NOT NULL,
    retorno real NOT NULL,
    indice real NOT NULL
);


--
-- Name: carteira_contra_referencia; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.carteira_contra_referencia AS
 WITH janela AS (
         SELECT retorno_dia.carteira_id,
            min(retorno_dia.data) AS de,
            max(retorno_dia.data) AS ate,
            count(*) AS dias
           FROM public.retorno_dia
          GROUP BY retorno_dia.carteira_id
        ), fim AS (
         SELECT j.carteira_id,
            j.de,
            j.ate,
            j.dias,
            ( SELECT x.indice
                   FROM public.retorno_dia x
                  WHERE ((x.carteira_id = j.carteira_id) AND (x.data = j.ate))) AS indice
           FROM janela j
        )
 SELECT f.carteira_id,
    f.de,
    f.ate,
    f.dias,
    r.ativo,
    r.nome,
    ((f.indice / (100.0)::double precision) - (1)::double precision) AS carteira,
    (exp(COALESCE(sum(ln(((1)::numeric + (o.valor)::numeric))), (0)::numeric)) - (1)::numeric) AS referencia,
    (((f.indice / (100.0)::double precision) - (1)::double precision) - ((exp(COALESCE(sum(ln(((1)::numeric + (o.valor)::numeric))), (0)::numeric)) - (1)::numeric))::double precision) AS excedente
   FROM ((fim f
     CROSS JOIN public.referencia r)
     LEFT JOIN public.oscilacao o ON (((o.ativo = r.ativo) AND ((o.data >= f.de) AND (o.data <= f.ate)) AND (((1)::double precision + o.valor) > (0)::double precision))))
  GROUP BY f.carteira_id, f.de, f.ate, f.dias, f.indice, r.ativo, r.nome, r.ordem
  ORDER BY f.carteira_id, r.ordem;


--
-- Name: carteira_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.carteira_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: carteira_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.carteira_id_seq OWNED BY public.carteira.id;


--
-- Name: ciclo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ciclo (
    id bigint NOT NULL,
    tipo text NOT NULL,
    inicio date NOT NULL,
    fim date NOT NULL,
    situacao text DEFAULT 'aberto'::text NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    encerrado_em timestamp with time zone,
    CONSTRAINT ciclo_situacao_check CHECK ((situacao = ANY (ARRAY['inscricoes'::text, 'aberto'::text, 'encerrado'::text]))),
    CONSTRAINT ciclo_tipo_check CHECK ((tipo = ANY (ARRAY['mensal'::text, 'trimestral'::text])))
);


--
-- Name: TABLE ciclo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ciclo IS 'Temporadas. O mensal vai do 1º ao último dia do mês; o trimestral começa em
   janeiro, abril, julho e outubro. A regra do ciclo é fixada antes de ele
   começar e não muda no meio.';


--
-- Name: ciclo_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ciclo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ciclo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ciclo_id_seq OWNED BY public.ciclo.id;


--
-- Name: conquista; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conquista (
    id bigint NOT NULL,
    usuario_id uuid,
    time_id bigint,
    ciclo_id bigint,
    papel text NOT NULL,
    regua text NOT NULL,
    posicao integer NOT NULL,
    criada_em timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conquista_papel_check CHECK ((papel = ANY (ARRAY['time'::text, 'membro'::text, 'capitao'::text, 'individual'::text]))),
    CONSTRAINT conquista_regua_check CHECK ((regua = ANY (ARRAY['rentabilidade'::text, 'sharpe'::text, 'queda'::text, 'geral'::text])))
);


--
-- Name: TABLE conquista; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.conquista IS 'O totem. Uma linha por reconhecimento — vira selo no perfil, moldura no
   apelido do ranking e certificado impresso.';


--
-- Name: conquista_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conquista_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conquista_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conquista_id_seq OWNED BY public.conquista.id;


--
-- Name: conta_arquivada; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conta_arquivada (
    usuario_id uuid NOT NULL,
    apelido text,
    nome text,
    telefone text,
    email text,
    criado_em timestamp with time zone,
    encerrada_em timestamp with time zone DEFAULT now(),
    motivo text
);


--
-- Name: copa; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copa (
    id bigint NOT NULL,
    data date NOT NULL,
    situacao text DEFAULT 'inscricoes'::text NOT NULL,
    campeao uuid,
    criada_em timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT copa_situacao_check CHECK ((situacao = ANY (ARRAY['inscricoes'::text, 'andamento'::text, 'encerrada'::text])))
);


--
-- Name: copa_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.copa_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: copa_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.copa_id_seq OWNED BY public.copa.id;


--
-- Name: copa_jogo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copa_jogo (
    id bigint NOT NULL,
    copa_id bigint NOT NULL,
    fase text NOT NULL,
    posicao integer NOT NULL,
    rodada_id bigint,
    jogador_a uuid,
    jogador_b uuid,
    pontos_a integer,
    pontos_b integer,
    vencedor uuid,
    CONSTRAINT copa_jogo_fase_check CHECK ((fase = ANY (ARRAY['quartas'::text, 'semi'::text, 'final'::text])))
);


--
-- Name: copa_jogo_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.copa_jogo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: copa_jogo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.copa_jogo_id_seq OWNED BY public.copa_jogo.id;


--
-- Name: copa_vaga; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copa_vaga (
    copa_id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    ordem integer NOT NULL
);


--
-- Name: cotacao_hora; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotacao_hora (
    ativo text NOT NULL,
    data date NOT NULL,
    hora integer NOT NULL,
    preco real NOT NULL,
    abertura real,
    fech_ant real,
    volume real,
    atualizado_em timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cotacao_hora_hora_check CHECK (((hora >= 0) AND (hora <= 23)))
);


--
-- Name: TABLE cotacao_hora; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cotacao_hora IS 'Fechamento de cada papel na virada de cada hora do pregão. A linha da hora H
   guarda o último preço visto dentro de H — ou seja, o preço às H+1:00.';


--
-- Name: cotacao_viva; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotacao_viva (
    ativo text NOT NULL,
    valor real NOT NULL,
    preco real,
    atualizado_em timestamp with time zone DEFAULT now() NOT NULL,
    abertura real,
    volume real
);


--
-- Name: dt_dia; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.dt_dia AS
 SELECT usuario_id,
    data,
    count(*) AS papeis,
    (avg(pts))::real AS nota_dia
   FROM public.aposta_apurada
  GROUP BY usuario_id, data;


--
-- Name: duelo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.duelo (
    id bigint NOT NULL,
    desafiante uuid NOT NULL,
    desafiado uuid NOT NULL,
    carteira_a bigint NOT NULL,
    carteira_b bigint,
    classe text NOT NULL,
    inicio date NOT NULL,
    fim date NOT NULL,
    recado text,
    situacao text DEFAULT 'convidado'::text NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    respondido_em timestamp with time zone,
    ret_a real,
    ret_b real,
    vencedor uuid,
    encerrado_em timestamp with time zone,
    CONSTRAINT duelo_check CHECK ((desafiante <> desafiado)),
    CONSTRAINT duelo_check1 CHECK ((fim > inicio)),
    CONSTRAINT duelo_situacao_check CHECK ((situacao = ANY (ARRAY['convidado'::text, 'aceito'::text, 'recusado'::text, 'cancelado'::text, 'encerrado'::text])))
);


--
-- Name: TABLE duelo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.duelo IS 'Desafio direto entre duas pessoas, com prazo combinado. Vence quem rendeu
   mais no período. Sem dinheiro: o que está em jogo é o nome.';


--
-- Name: duelo_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.duelo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duelo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.duelo_id_seq OWNED BY public.duelo.id;


--
-- Name: faixa_papel; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.faixa_papel AS
 SELECT ativo,
    count(*) AS dias,
    (avg(((maxima - minima) / abertura)))::real AS amplitude
   FROM public.barra
  WHERE (abertura > (0)::double precision)
  GROUP BY ativo;


--
-- Name: faixa_volume; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.faixa_volume (
    id smallint NOT NULL,
    ordem integer NOT NULL,
    rotulo text NOT NULL,
    de real,
    ate real
);


--
-- Name: faixa_volume_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.faixa_volume_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: faixa_volume_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.faixa_volume_id_seq OWNED BY public.faixa_volume.id;


--
-- Name: fechamento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fechamento (
    ativo text NOT NULL,
    data date NOT NULL,
    fech real NOT NULL
);


--
-- Name: fila_email; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fila_email (
    id bigint NOT NULL,
    destino text NOT NULL,
    assunto text NOT NULL,
    corpo text NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    enviado_em timestamp with time zone,
    tentativas integer DEFAULT 0 NOT NULL,
    erro text
);


--
-- Name: fila_email_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fila_email ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fila_email_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: indice_referencia; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.indice_referencia AS
 SELECT o.ativo,
    r.nome,
    o.data,
    ((100)::numeric * exp(sum(ln(((1)::numeric + (o.valor)::numeric))) OVER (PARTITION BY o.ativo ORDER BY o.data))) AS indice
   FROM (public.oscilacao o
     JOIN public.referencia r ON ((r.ativo = o.ativo)))
  WHERE (((1)::double precision + o.valor) > (0)::double precision);


--
-- Name: intraday_pessoa; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intraday_pessoa (
    usuario_id uuid NOT NULL,
    data date NOT NULL,
    rodadas integer DEFAULT 0 NOT NULL,
    acertos integer DEFAULT 0 NOT NULL,
    pontos integer DEFAULT 0 NOT NULL,
    sequencia integer DEFAULT 0 NOT NULL
);


--
-- Name: intraday_sequencia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intraday_sequencia (
    usuario_id uuid NOT NULL,
    sequencia integer DEFAULT 0 NOT NULL,
    maior integer DEFAULT 0 NOT NULL,
    ultima_rodada bigint
);


--
-- Name: lead_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lead ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lead_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lead_nota; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_nota (
    id bigint NOT NULL,
    lead_id bigint NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    autor uuid,
    texto text NOT NULL
);


--
-- Name: lead_nota_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lead_nota ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lead_nota_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: nota; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nota (
    id bigint NOT NULL,
    carteira_id bigint NOT NULL,
    data date DEFAULT CURRENT_DATE,
    texto text
);


--
-- Name: nota_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.nota_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nota_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.nota_id_seq OWNED BY public.nota.id;


--
-- Name: notificacao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notificacao (
    id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    tipo text NOT NULL,
    texto text NOT NULL,
    rota text,
    criada_em timestamp with time zone DEFAULT now() NOT NULL,
    vista_em timestamp with time zone,
    CONSTRAINT notificacao_tipo_check CHECK ((tipo = ANY (ARRAY['mensagem'::text, 'carteira'::text, 'duelo'::text, 'lead'::text])))
);


--
-- Name: notificacao_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notificacao_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notificacao_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notificacao_id_seq OWNED BY public.notificacao.id;


--
-- Name: oscilacao_foto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oscilacao_foto (
    data date NOT NULL,
    ativo text NOT NULL,
    valor real,
    tirada_em timestamp with time zone DEFAULT now()
);


--
-- Name: painel_assinatura; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.painel_assinatura AS
 SELECT id,
    apelido,
    assinante,
    ( SELECT max(a.fim) AS max
           FROM public.assinatura a
          WHERE (a.usuario_id = p.id)) AS vence_em,
    ( SELECT count(*) AS count
           FROM public.assinatura a
          WHERE (a.usuario_id = p.id)) AS pagamentos,
    ( SELECT COALESCE(sum(a.valor), (0)::real) AS "coalesce"
           FROM public.assinatura a
          WHERE (a.usuario_id = p.id)) AS total_pago
   FROM public.perfil p;


--
-- Name: peso_atual; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.peso_atual (
    carteira_id bigint NOT NULL,
    ativo text NOT NULL,
    peso real NOT NULL,
    marco date
);


--
-- Name: posicao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posicao (
    id bigint NOT NULL,
    carteira_id bigint NOT NULL,
    ativo text NOT NULL,
    peso real NOT NULL,
    valida_de date DEFAULT public.proximo_pregao(),
    declarada_em timestamp with time zone DEFAULT now()
);


--
-- Name: universo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.universo (
    ativo text NOT NULL,
    cotacao real,
    liquidez real,
    tipo text DEFAULT 'acao'::text NOT NULL,
    nome text,
    cotacao_em date,
    acoes real
);


--
-- Name: COLUMN universo.acoes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.universo.acoes IS 'Ações totais da companhia. Do Fundamentus: P/VP × Patrimônio Líquido ÷ Cotação.';


--
-- Name: papeis_do_dia; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.papeis_do_dia AS
 SELECT peso_atual.ativo
   FROM public.peso_atual
UNION
 SELECT p.ativo
   FROM (public.posicao p
     JOIN public.carteira c ON ((c.id = p.carteira_id)))
  WHERE (c.ativa AND (p.valida_de <= public.hoje_br()))
UNION
 SELECT a.ativo
   FROM public.aposta a
  WHERE (a.data >= (public.hoje_br() - 45))
UNION
 SELECT referencia.ativo
   FROM public.referencia
UNION
 SELECT u.ativo
   FROM public.universo u;


--
-- Name: papel_fila; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.papel_fila (
    ativo text NOT NULL,
    estado text DEFAULT 'pendente'::text NOT NULL,
    motivo text,
    pedido_em timestamp with time zone DEFAULT now() NOT NULL,
    respondido_em timestamp with time zone,
    CONSTRAINT papel_fila_estado_check CHECK ((estado = ANY (ARRAY['pendente'::text, 'cotando'::text, 'nao_existe'::text])))
);


--
-- Name: TABLE papel_fila; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.papel_fila IS 'Papéis que precisam entrar no Observador do MT5. pendente = o EA ainda não olhou; cotando = SymbolSelect deu certo e já vem cotação; nao_existe = a corretora não tem esse código.';


--
-- Name: parametro; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parametro (
    chave text NOT NULL,
    valor real NOT NULL,
    nome text,
    atualizado_em timestamp with time zone DEFAULT now()
);


--
-- Name: perfil_publico; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.perfil_publico WITH (security_invoker='false') AS
 SELECT id,
    apelido,
    exibir,
    nome_publico,
    credencial,
    anos_mercado
   FROM public.perfil
  WHERE (NOT COALESCE(bloqueado, false));


--
-- Name: peso_atual_backup; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.peso_atual_backup (
    carteira_id bigint,
    ativo text,
    peso real,
    marco date
);


--
-- Name: placar_intraday; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.placar_intraday AS
 SELECT p.usuario_id,
    pf.apelido,
    (sum(p.rodadas))::integer AS rodadas,
    (sum(p.acertos))::integer AS acertos,
    (sum(p.pontos))::integer AS pontos,
    ((sum(p.pontos))::real / (NULLIF(sum(p.rodadas), 0))::double precision) AS media,
    (((sum(p.pontos))::real / (NULLIF(sum(p.rodadas), 0))::double precision) * ((sum(p.rodadas))::real / ((sum(p.rodadas) + 20))::double precision)) AS nota,
    COALESCE(s.sequencia, 0) AS sequencia,
    COALESCE(s.maior, 0) AS maior_sequencia
   FROM ((public.intraday_pessoa p
     JOIN public.perfil_publico pf ON ((pf.id = p.usuario_id)))
     LEFT JOIN public.intraday_sequencia s ON ((s.usuario_id = p.usuario_id)))
  GROUP BY p.usuario_id, pf.apelido, s.sequencia, s.maior;


--
-- Name: posicao_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.posicao_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: posicao_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.posicao_id_seq OWNED BY public.posicao.id;


--
-- Name: ranking; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ranking AS
 SELECT c.id,
    c.nome,
    c.descricao,
    c.bruta,
    c.liquida,
    c.caixa,
    c.n_ativos,
    c.criada_em,
    p.apelido,
    p.identidade,
    p.credencial,
    p.anos_mercado,
    r.indice,
    r.data AS ultima_data,
    ((r.indice / (100.0)::double precision) - (1)::double precision) AS acumulado,
    ( SELECT count(*) AS count
           FROM public.retorno_dia x
          WHERE (x.carteira_id = c.id)) AS dias,
    ( SELECT x.retorno
           FROM public.retorno_dia x
          WHERE (x.carteira_id = c.id)
          ORDER BY x.data DESC
         LIMIT 1) AS hoje
   FROM ((public.carteira c
     JOIN public.perfil p ON ((p.id = c.usuario_id)))
     LEFT JOIN LATERAL ( SELECT retorno_dia.indice,
            retorno_dia.data
           FROM public.retorno_dia
          WHERE (retorno_dia.carteira_id = c.id)
          ORDER BY retorno_dia.data DESC
         LIMIT 1) r ON (true))
  WHERE c.ativa;


--
-- Name: ranking_dt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ranking_dt AS
 SELECT d.usuario_id,
    p.apelido,
    count(*) AS dias,
    sum(d.papeis) AS operacoes,
    (avg(d.nota_dia))::real AS media_dia,
    (((avg(d.nota_dia) * (count(*))::double precision) / (((count(*))::numeric + 20.0))::double precision))::real AS nota,
    max(d.data) AS ultimo_dia
   FROM (public.dt_dia d
     JOIN public.perfil p ON ((p.id = d.usuario_id)))
  WHERE (NOT p.bloqueado)
  GROUP BY d.usuario_id, p.apelido
  ORDER BY ((((avg(d.nota_dia) * (count(*))::double precision) / (((count(*))::numeric + 20.0))::double precision))::real) DESC, (count(*)) DESC;


--
-- Name: rebalanceamento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rebalanceamento (
    carteira_id bigint NOT NULL,
    data date NOT NULL,
    motivo text NOT NULL,
    ajuste jsonb
);


--
-- Name: referencia_viva; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.referencia_viva AS
 SELECT r.ativo,
    r.nome,
    v.valor,
    v.atualizado_em
   FROM (public.referencia r
     JOIN public.cotacao_viva v ON ((v.ativo = r.ativo)));


--
-- Name: regra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regra (
    carteira_id bigint NOT NULL,
    valida_de date NOT NULL,
    rebalancear text DEFAULT 'nunca'::text NOT NULL,
    banda_pct real DEFAULT 5 NOT NULL,
    declarada_em timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: resumo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resumo (
    carteira_id bigint NOT NULL,
    dias integer DEFAULT 0 NOT NULL,
    ultima_data date,
    indice real,
    acumulado real,
    hoje real,
    semana real,
    mes real,
    ano real,
    sharpe real,
    drawdown real,
    vol real,
    vs_ibov real,
    fita real[],
    atualizado timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: retorno_parcial; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.retorno_parcial AS
 WITH expo AS (
         SELECT peso_atual.carteira_id,
            COALESCE(sum(peso_atual.peso) FILTER (WHERE (peso_atual.peso > (0)::double precision)), (0)::real) AS l,
            (- COALESCE(sum(peso_atual.peso) FILTER (WHERE (peso_atual.peso < (0)::double precision)), (0)::real)) AS s
           FROM public.peso_atual
          GROUP BY peso_atual.carteira_id
        )
 SELECT pa.carteira_id,
    ((sum(((pa.peso / (100.0)::double precision) * COALESCE(v.valor, (0)::real))) + ((LEAST(((100.0)::double precision - (e.l - e.s)), (100.0)::double precision) / (100.0)::double precision) * public.taxa_rf_dia())))::real AS retorno,
    max(v.atualizado_em) AS atualizado_em,
    count(v.valor) AS com_cotacao,
    count(*) AS papeis
   FROM ((public.peso_atual pa
     JOIN expo e ON ((e.carteira_id = pa.carteira_id)))
     LEFT JOIN public.cotacao_viva v ON (((v.ativo = pa.ativo) AND (((v.atualizado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date = public.hoje_br()))))
  GROUP BY pa.carteira_id, e.l, e.s;


--
-- Name: rodada; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rodada (
    id bigint NOT NULL,
    data date NOT NULL,
    hora integer NOT NULL,
    abre_em timestamp with time zone NOT NULL,
    fecha_em timestamp with time zone NOT NULL,
    situacao text DEFAULT 'aberta'::text NOT NULL,
    apurada_em timestamp with time zone,
    corte_petr real,
    CONSTRAINT rodada_hora_check CHECK (((hora >= 11) AND (hora <= 16))),
    CONSTRAINT rodada_situacao_check CHECK ((situacao = ANY (ARRAY['aberta'::text, 'fechada'::text, 'apurada'::text])))
);


--
-- Name: rodada_gabarito; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rodada_gabarito (
    rodada_id bigint NOT NULL,
    jogo text NOT NULL,
    resposta text NOT NULL,
    detalhe text
);


--
-- Name: rodada_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rodada_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rodada_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rodada_id_seq OWNED BY public.rodada.id;


--
-- Name: rodada_papel; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rodada_papel (
    rodada_id bigint NOT NULL,
    jogo text NOT NULL,
    ativo text NOT NULL,
    CONSTRAINT rodada_papel_jogo_check CHECK ((jogo = ANY (ARRAY['sobe'::text, 'cai'::text, 'volume'::text])))
);


--
-- Name: seguidor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seguidor (
    usuario_id uuid NOT NULL,
    carteira_id bigint NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: seguindo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seguindo (
    usuario_id uuid NOT NULL,
    carteira_id bigint NOT NULL
);


--
-- Name: time_; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_ (
    id bigint NOT NULL,
    nome text NOT NULL,
    tema text DEFAULT 'outros'::text NOT NULL,
    descricao text,
    capitao uuid NOT NULL,
    codigo text NOT NULL,
    criado_em timestamp with time zone DEFAULT now() NOT NULL,
    encerrado_em timestamp with time zone,
    encerrado_por uuid,
    CONSTRAINT time__tema_check CHECK ((tema = ANY (ARRAY['escola'::text, 'faculdade'::text, 'amigos'::text, 'empresa'::text, 'associacao'::text, 'outros'::text])))
);


--
-- Name: TABLE time_; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.time_ IS 'O nome tem sublinhado porque "time" é palavra reservada do Postgres.';


--
-- Name: time__id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.time__id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: time__id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.time__id_seq OWNED BY public.time_.id;


--
-- Name: time_carteira_dia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_carteira_dia (
    ciclo_id bigint NOT NULL,
    time_id bigint NOT NULL,
    data date NOT NULL,
    ativos text[] NOT NULL,
    montada_em timestamp with time zone DEFAULT now() NOT NULL,
    retorno real,
    indice real
);


--
-- Name: time_ciclo_membro; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_ciclo_membro (
    ciclo_id bigint NOT NULL,
    time_id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    carteira_id bigint
);


--
-- Name: time_ciclo_resultado; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_ciclo_resultado (
    ciclo_id bigint NOT NULL,
    time_id bigint NOT NULL,
    dias integer DEFAULT 0 NOT NULL,
    acumulado real,
    sharpe real,
    drawdown real,
    pos_acum integer,
    pos_sharpe integer,
    pos_dd integer,
    pos_geral integer,
    apurado_em timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: time_empate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_empate (
    ciclo_id bigint NOT NULL,
    time_id bigint NOT NULL,
    data date NOT NULL,
    vagas integer NOT NULL,
    candidatos text[] NOT NULL,
    automatico text[] NOT NULL,
    escolha text[],
    escolhido_em timestamp with time zone,
    escolhido_por uuid
);


--
-- Name: time_inscricao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_inscricao (
    time_id bigint NOT NULL,
    ciclo_id bigint NOT NULL,
    inscrito_em timestamp with time zone DEFAULT now() NOT NULL,
    elenco_hash text
);


--
-- Name: COLUMN time_inscricao.elenco_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.time_inscricao.elenco_hash IS 'md5 do conjunto ordenado de carteiras do elenco congelado. Dois times com o
   mesmo conjunto no mesmo ciclo produziriam a mesma carteira — o segundo não
   pontua.';


--
-- Name: time_membro; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_membro (
    id bigint NOT NULL,
    time_id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    carteira_id bigint,
    situacao text DEFAULT 'pedido'::text NOT NULL,
    pediu_em timestamp with time zone DEFAULT now() NOT NULL,
    aprovado_em timestamp with time zone,
    saiu_em timestamp with time zone,
    silenciado boolean DEFAULT false NOT NULL,
    CONSTRAINT time_membro_situacao_check CHECK ((situacao = ANY (ARRAY['pedido'::text, 'ativo'::text, 'recusado'::text, 'saiu'::text])))
);


--
-- Name: time_membro_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.time_membro_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: time_membro_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.time_membro_id_seq OWNED BY public.time_membro.id;


--
-- Name: time_msg; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_msg (
    id bigint NOT NULL,
    time_id bigint NOT NULL,
    autor uuid NOT NULL,
    texto text NOT NULL,
    criada_em timestamp with time zone DEFAULT now() NOT NULL,
    apagada_em timestamp with time zone,
    apagada_por uuid,
    CONSTRAINT time_msg_texto_check CHECK (((length(btrim(texto)) >= 1) AND (length(btrim(texto)) <= 1200)))
);


--
-- Name: time_msg_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.time_msg_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: time_msg_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.time_msg_id_seq OWNED BY public.time_msg.id;


--
-- Name: universo_estado; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.universo_estado WITH (security_invoker='true') AS
 SELECT u.ativo,
    u.tipo,
    u.nome,
    u.cotacao,
    u.liquidez,
    COALESCE(b.pregoes, (0)::bigint) AS pregoes,
    b.ultimo
   FROM (public.universo u
     LEFT JOIN ( SELECT barra.ativo,
            count(*) AS pregoes,
            max(barra.data) AS ultimo
           FROM public.barra
          GROUP BY barra.ativo) b ON ((b.ativo = u.ativo)));


--
-- Name: voto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voto (
    id bigint NOT NULL,
    rodada_id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    jogo text NOT NULL,
    palpite text NOT NULL,
    votado_em timestamp with time zone DEFAULT now() NOT NULL,
    acertou boolean,
    pontos integer,
    CONSTRAINT voto_jogo_check CHECK ((jogo = ANY (ARRAY['sobe'::text, 'cai'::text, 'volume'::text, 'petr'::text, 'tiro'::text, 'mexe'::text, 'gira'::text])))
);


--
-- Name: voto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.voto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: voto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.voto_id_seq OWNED BY public.voto.id;


--
-- Name: aposta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta ALTER COLUMN id SET DEFAULT nextval('public.aposta_id_seq'::regclass);


--
-- Name: assinatura id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assinatura ALTER COLUMN id SET DEFAULT nextval('public.assinatura_id_seq'::regclass);


--
-- Name: carteira id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carteira ALTER COLUMN id SET DEFAULT nextval('public.carteira_id_seq'::regclass);


--
-- Name: ciclo id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ciclo ALTER COLUMN id SET DEFAULT nextval('public.ciclo_id_seq'::regclass);


--
-- Name: conquista id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conquista ALTER COLUMN id SET DEFAULT nextval('public.conquista_id_seq'::regclass);


--
-- Name: copa id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa ALTER COLUMN id SET DEFAULT nextval('public.copa_id_seq'::regclass);


--
-- Name: copa_jogo id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo ALTER COLUMN id SET DEFAULT nextval('public.copa_jogo_id_seq'::regclass);


--
-- Name: duelo id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo ALTER COLUMN id SET DEFAULT nextval('public.duelo_id_seq'::regclass);


--
-- Name: faixa_volume id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faixa_volume ALTER COLUMN id SET DEFAULT nextval('public.faixa_volume_id_seq'::regclass);


--
-- Name: nota id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nota ALTER COLUMN id SET DEFAULT nextval('public.nota_id_seq'::regclass);


--
-- Name: notificacao id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notificacao ALTER COLUMN id SET DEFAULT nextval('public.notificacao_id_seq'::regclass);


--
-- Name: posicao id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posicao ALTER COLUMN id SET DEFAULT nextval('public.posicao_id_seq'::regclass);


--
-- Name: rodada id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada ALTER COLUMN id SET DEFAULT nextval('public.rodada_id_seq'::regclass);


--
-- Name: time_ id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ ALTER COLUMN id SET DEFAULT nextval('public.time__id_seq'::regclass);


--
-- Name: time_membro id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro ALTER COLUMN id SET DEFAULT nextval('public.time_membro_id_seq'::regclass);


--
-- Name: time_msg id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_msg ALTER COLUMN id SET DEFAULT nextval('public.time_msg_id_seq'::regclass);


--
-- Name: voto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voto ALTER COLUMN id SET DEFAULT nextval('public.voto_id_seq'::regclass);


--
-- Name: aposta aposta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta
    ADD CONSTRAINT aposta_pkey PRIMARY KEY (id);


--
-- Name: aposta aposta_usuario_id_data_ativo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta
    ADD CONSTRAINT aposta_usuario_id_data_ativo_key UNIQUE (usuario_id, data, ativo);


--
-- Name: assinatura assinatura_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assinatura
    ADD CONSTRAINT assinatura_pkey PRIMARY KEY (id);


--
-- Name: barra barra_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.barra
    ADD CONSTRAINT barra_pkey PRIMARY KEY (ativo, data);


--
-- Name: carteira carteira_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carteira
    ADD CONSTRAINT carteira_pkey PRIMARY KEY (id);


--
-- Name: ciclo ciclo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ciclo
    ADD CONSTRAINT ciclo_pkey PRIMARY KEY (id);


--
-- Name: ciclo ciclo_tipo_inicio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ciclo
    ADD CONSTRAINT ciclo_tipo_inicio_key UNIQUE (tipo, inicio);


--
-- Name: conquista conquista_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conquista
    ADD CONSTRAINT conquista_pkey PRIMARY KEY (id);


--
-- Name: conta_arquivada conta_arquivada_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conta_arquivada
    ADD CONSTRAINT conta_arquivada_pkey PRIMARY KEY (usuario_id);


--
-- Name: copa copa_data_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa
    ADD CONSTRAINT copa_data_key UNIQUE (data);


--
-- Name: copa_jogo copa_jogo_copa_id_fase_posicao_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_copa_id_fase_posicao_key UNIQUE (copa_id, fase, posicao);


--
-- Name: copa_jogo copa_jogo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_pkey PRIMARY KEY (id);


--
-- Name: copa copa_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa
    ADD CONSTRAINT copa_pkey PRIMARY KEY (id);


--
-- Name: copa_vaga copa_vaga_copa_id_ordem_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_vaga
    ADD CONSTRAINT copa_vaga_copa_id_ordem_key UNIQUE (copa_id, ordem);


--
-- Name: copa_vaga copa_vaga_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_vaga
    ADD CONSTRAINT copa_vaga_pkey PRIMARY KEY (copa_id, usuario_id);


--
-- Name: cotacao_hora cotacao_hora_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotacao_hora
    ADD CONSTRAINT cotacao_hora_pkey PRIMARY KEY (ativo, data, hora);


--
-- Name: cotacao_viva cotacao_viva_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotacao_viva
    ADD CONSTRAINT cotacao_viva_pkey PRIMARY KEY (ativo);


--
-- Name: duelo duelo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo
    ADD CONSTRAINT duelo_pkey PRIMARY KEY (id);


--
-- Name: faixa_volume faixa_volume_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faixa_volume
    ADD CONSTRAINT faixa_volume_pkey PRIMARY KEY (id);


--
-- Name: fechamento fechamento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fechamento
    ADD CONSTRAINT fechamento_pkey PRIMARY KEY (ativo, data);


--
-- Name: fila_email fila_email_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fila_email
    ADD CONSTRAINT fila_email_pkey PRIMARY KEY (id);


--
-- Name: intraday_pessoa intraday_pessoa_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intraday_pessoa
    ADD CONSTRAINT intraday_pessoa_pkey PRIMARY KEY (usuario_id, data);


--
-- Name: intraday_sequencia intraday_sequencia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intraday_sequencia
    ADD CONSTRAINT intraday_sequencia_pkey PRIMARY KEY (usuario_id);


--
-- Name: lead lead_cpf_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead
    ADD CONSTRAINT lead_cpf_key UNIQUE (cpf);


--
-- Name: lead_nota lead_nota_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_nota
    ADD CONSTRAINT lead_nota_pkey PRIMARY KEY (id);


--
-- Name: lead lead_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead
    ADD CONSTRAINT lead_pkey PRIMARY KEY (id);


--
-- Name: lead lead_usuario_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead
    ADD CONSTRAINT lead_usuario_id_key UNIQUE (usuario_id);


--
-- Name: nota nota_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nota
    ADD CONSTRAINT nota_pkey PRIMARY KEY (id);


--
-- Name: notificacao notificacao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notificacao
    ADD CONSTRAINT notificacao_pkey PRIMARY KEY (id);


--
-- Name: oscilacao_foto oscilacao_foto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oscilacao_foto
    ADD CONSTRAINT oscilacao_foto_pkey PRIMARY KEY (data, ativo);


--
-- Name: oscilacao oscilacao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oscilacao
    ADD CONSTRAINT oscilacao_pkey PRIMARY KEY (ativo, data);


--
-- Name: papel_fila papel_fila_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.papel_fila
    ADD CONSTRAINT papel_fila_pkey PRIMARY KEY (ativo);


--
-- Name: parametro parametro_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parametro
    ADD CONSTRAINT parametro_pkey PRIMARY KEY (chave);


--
-- Name: perfil perfil_apelido_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil
    ADD CONSTRAINT perfil_apelido_key UNIQUE (apelido);


--
-- Name: perfil perfil_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil
    ADD CONSTRAINT perfil_pkey PRIMARY KEY (id);


--
-- Name: perfil perfil_ref_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil
    ADD CONSTRAINT perfil_ref_code_key UNIQUE (ref_code);


--
-- Name: peso_atual peso_atual_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.peso_atual
    ADD CONSTRAINT peso_atual_pkey PRIMARY KEY (carteira_id, ativo);


--
-- Name: posicao posicao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posicao
    ADD CONSTRAINT posicao_pkey PRIMARY KEY (id);


--
-- Name: rebalanceamento rebalanceamento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rebalanceamento
    ADD CONSTRAINT rebalanceamento_pkey PRIMARY KEY (carteira_id, data);


--
-- Name: referencia referencia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referencia
    ADD CONSTRAINT referencia_pkey PRIMARY KEY (ativo);


--
-- Name: regra regra_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regra
    ADD CONSTRAINT regra_pkey PRIMARY KEY (carteira_id, valida_de);


--
-- Name: resumo resumo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resumo
    ADD CONSTRAINT resumo_pkey PRIMARY KEY (carteira_id);


--
-- Name: retorno_dia retorno_dia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retorno_dia
    ADD CONSTRAINT retorno_dia_pkey PRIMARY KEY (carteira_id, data);


--
-- Name: rodada rodada_data_hora_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada
    ADD CONSTRAINT rodada_data_hora_key UNIQUE (data, hora);


--
-- Name: rodada_gabarito rodada_gabarito_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada_gabarito
    ADD CONSTRAINT rodada_gabarito_pkey PRIMARY KEY (rodada_id, jogo);


--
-- Name: rodada_papel rodada_papel_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada_papel
    ADD CONSTRAINT rodada_papel_pkey PRIMARY KEY (rodada_id, jogo, ativo);


--
-- Name: rodada rodada_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada
    ADD CONSTRAINT rodada_pkey PRIMARY KEY (id);


--
-- Name: seguidor seguidor_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguidor
    ADD CONSTRAINT seguidor_pkey PRIMARY KEY (usuario_id, carteira_id);


--
-- Name: seguindo seguindo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguindo
    ADD CONSTRAINT seguindo_pkey PRIMARY KEY (usuario_id, carteira_id);


--
-- Name: time_ time__codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_
    ADD CONSTRAINT time__codigo_key UNIQUE (codigo);


--
-- Name: time_ time__pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_
    ADD CONSTRAINT time__pkey PRIMARY KEY (id);


--
-- Name: time_carteira_dia time_carteira_dia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_carteira_dia
    ADD CONSTRAINT time_carteira_dia_pkey PRIMARY KEY (ciclo_id, time_id, data);


--
-- Name: time_ciclo_membro time_ciclo_membro_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_membro
    ADD CONSTRAINT time_ciclo_membro_pkey PRIMARY KEY (ciclo_id, time_id, usuario_id);


--
-- Name: time_ciclo_resultado time_ciclo_resultado_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_resultado
    ADD CONSTRAINT time_ciclo_resultado_pkey PRIMARY KEY (ciclo_id, time_id);


--
-- Name: time_empate time_empate_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_empate
    ADD CONSTRAINT time_empate_pkey PRIMARY KEY (ciclo_id, time_id, data);


--
-- Name: time_inscricao time_inscricao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_inscricao
    ADD CONSTRAINT time_inscricao_pkey PRIMARY KEY (time_id, ciclo_id);


--
-- Name: time_membro time_membro_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro
    ADD CONSTRAINT time_membro_pkey PRIMARY KEY (id);


--
-- Name: time_membro time_membro_time_id_usuario_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro
    ADD CONSTRAINT time_membro_time_id_usuario_id_key UNIQUE (time_id, usuario_id);


--
-- Name: time_msg time_msg_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_msg
    ADD CONSTRAINT time_msg_pkey PRIMARY KEY (id);


--
-- Name: universo universo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.universo
    ADD CONSTRAINT universo_pkey PRIMARY KEY (ativo);


--
-- Name: voto voto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voto
    ADD CONSTRAINT voto_pkey PRIMARY KEY (id);


--
-- Name: voto voto_rodada_id_usuario_id_jogo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voto
    ADD CONSTRAINT voto_rodada_id_usuario_id_jogo_key UNIQUE (rodada_id, usuario_id, jogo);


--
-- Name: aposta_data; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX aposta_data ON public.aposta USING btree (data);


--
-- Name: assinatura_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assinatura_usuario ON public.assinatura USING btree (usuario_id, fim DESC);


--
-- Name: barra_ativo_data_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX barra_ativo_data_uk ON public.barra USING btree (ativo, data);


--
-- Name: carteira_nome_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX carteira_nome_unico ON public.carteira USING btree (usuario_id, lower(TRIM(BOTH FROM nome))) WHERE ativa;


--
-- Name: ch_por_dia; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ch_por_dia ON public.cotacao_hora USING btree (data, hora);


--
-- Name: ciclo_janela; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ciclo_janela ON public.ciclo USING btree (inicio, fim);


--
-- Name: conquista_por_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conquista_por_usuario ON public.conquista USING btree (usuario_id);


--
-- Name: copa_jogo_rodada; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX copa_jogo_rodada ON public.copa_jogo USING btree (rodada_id) WHERE (vencedor IS NULL);


--
-- Name: duelo_aberto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX duelo_aberto ON public.duelo USING btree (fim) WHERE (situacao = 'aceito'::text);


--
-- Name: duelo_de; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX duelo_de ON public.duelo USING btree (desafiante, situacao);


--
-- Name: duelo_para; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX duelo_para ON public.duelo USING btree (desafiado, situacao);


--
-- Name: fila_email_pendente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fila_email_pendente ON public.fila_email USING btree (criado_em) WHERE (enviado_em IS NULL);


--
-- Name: inscricao_elenco_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX inscricao_elenco_unico ON public.time_inscricao USING btree (ciclo_id, elenco_hash) WHERE (elenco_hash IS NOT NULL);


--
-- Name: lead_nota_lead; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lead_nota_lead ON public.lead_nota USING btree (lead_id, criado_em DESC);


--
-- Name: membro_ativo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX membro_ativo ON public.time_membro USING btree (time_id) WHERE (situacao = 'ativo'::text);


--
-- Name: membro_por_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX membro_por_usuario ON public.time_membro USING btree (usuario_id);


--
-- Name: msg_do_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX msg_do_time ON public.time_msg USING btree (time_id, criada_em DESC);


--
-- Name: notificacao_dono; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notificacao_dono ON public.notificacao USING btree (usuario_id, vista_em, criada_em DESC);


--
-- Name: oscilacao_ativo_data_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oscilacao_ativo_data_uk ON public.oscilacao USING btree (ativo, data);


--
-- Name: perfil_apelido_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX perfil_apelido_unico ON public.perfil USING btree (lower(apelido));


--
-- Name: posicao_carteira_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posicao_carteira_id_idx ON public.posicao USING btree (carteira_id);


--
-- Name: rodada_aberta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rodada_aberta ON public.rodada USING btree (data, hora) WHERE (situacao <> 'apurada'::text);


--
-- Name: rp_por_rodada; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rp_por_rodada ON public.rodada_papel USING btree (rodada_id);


--
-- Name: tcd_por_data; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tcd_por_data ON public.time_carteira_dia USING btree (ciclo_id, data);


--
-- Name: time_capitao; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX time_capitao ON public.time_ USING btree (capitao);


--
-- Name: time_nome_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX time_nome_unico ON public.time_ USING btree (lower(nome)) WHERE (encerrado_em IS NULL);


--
-- Name: voto_por_pessoa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX voto_por_pessoa ON public.voto USING btree (usuario_id, rodada_id);


--
-- Name: aposta aposta_trava; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aposta_trava BEFORE INSERT ON public.aposta FOR EACH ROW EXECUTE FUNCTION public.trava_aposta();


--
-- Name: barra barra_universo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER barra_universo AFTER INSERT OR UPDATE ON public.barra FOR EACH ROW EXECUTE FUNCTION public.barra_atualiza_universo();


--
-- Name: carteira carteira_trava_classe; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER carteira_trava_classe BEFORE UPDATE ON public.carteira FOR EACH ROW EXECUTE FUNCTION public.trava_classe();


--
-- Name: lead lead_avisa; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lead_avisa AFTER INSERT ON public.lead FOR EACH ROW EXECUTE FUNCTION public.avisar_lead();


--
-- Name: lead lead_norm; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lead_norm BEFORE INSERT OR UPDATE ON public.lead FOR EACH ROW EXECUTE FUNCTION public.lead_normaliza();


--
-- Name: perfil perfil_trava; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perfil_trava BEFORE UPDATE ON public.perfil FOR EACH ROW EXECUTE FUNCTION public.trava_privilegio();


--
-- Name: posicao tg_declarar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_declarar AFTER INSERT ON public.posicao FOR EACH ROW EXECUTE FUNCTION public.ao_declarar_posicao();


--
-- Name: retorno_dia tg_encerrar_se_zerou; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_encerrar_se_zerou AFTER INSERT OR UPDATE ON public.retorno_dia FOR EACH ROW EXECUTE FUNCTION public.encerrar_se_zerou();


--
-- Name: aposta tg_fila_aposta; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_fila_aposta AFTER INSERT ON public.aposta FOR EACH ROW EXECUTE FUNCTION public.enfileirar_papel();


--
-- Name: posicao tg_fila_posicao; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_fila_posicao AFTER INSERT ON public.posicao FOR EACH ROW EXECUTE FUNCTION public.enfileirar_papel();


--
-- Name: cotacao_viva tg_fotografar_hora; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_fotografar_hora AFTER INSERT OR UPDATE ON public.cotacao_viva FOR EACH ROW EXECUTE FUNCTION public.fotografar_hora();


--
-- Name: duelo tg_notif_duelo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_notif_duelo AFTER INSERT ON public.duelo FOR EACH ROW EXECUTE FUNCTION public.notif_duelo();


--
-- Name: lead tg_notif_lead; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_notif_lead AFTER INSERT ON public.lead FOR EACH ROW EXECUTE FUNCTION public.notif_lead();


--
-- Name: time_msg tg_notif_msg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_notif_msg AFTER INSERT ON public.time_msg FOR EACH ROW EXECUTE FUNCTION public.notif_msg();


--
-- Name: rebalanceamento tg_notif_rebal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_notif_rebal AFTER INSERT ON public.rebalanceamento FOR EACH ROW EXECUTE FUNCTION public.notif_rebal();


--
-- Name: time_membro tg_trava_saida; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_trava_saida BEFORE UPDATE ON public.time_membro FOR EACH ROW EXECUTE FUNCTION public.trava_saida_membro();


--
-- Name: voto tg_trava_voto; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tg_trava_voto BEFORE INSERT OR UPDATE OF rodada_id, usuario_id, jogo, palpite ON public.voto FOR EACH ROW EXECUTE FUNCTION public.trava_voto();


--
-- Name: aposta aposta_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta
    ADD CONSTRAINT aposta_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: assinatura assinatura_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assinatura
    ADD CONSTRAINT assinatura_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: carteira carteira_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carteira
    ADD CONSTRAINT carteira_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: conquista conquista_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conquista
    ADD CONSTRAINT conquista_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: conquista conquista_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conquista
    ADD CONSTRAINT conquista_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: conquista conquista_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conquista
    ADD CONSTRAINT conquista_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: copa copa_campeao_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa
    ADD CONSTRAINT copa_campeao_fkey FOREIGN KEY (campeao) REFERENCES public.perfil(id);


--
-- Name: copa_jogo copa_jogo_copa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_copa_id_fkey FOREIGN KEY (copa_id) REFERENCES public.copa(id) ON DELETE CASCADE;


--
-- Name: copa_jogo copa_jogo_jogador_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_jogador_a_fkey FOREIGN KEY (jogador_a) REFERENCES public.perfil(id);


--
-- Name: copa_jogo copa_jogo_jogador_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_jogador_b_fkey FOREIGN KEY (jogador_b) REFERENCES public.perfil(id);


--
-- Name: copa_jogo copa_jogo_rodada_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_rodada_id_fkey FOREIGN KEY (rodada_id) REFERENCES public.rodada(id);


--
-- Name: copa_jogo copa_jogo_vencedor_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_jogo
    ADD CONSTRAINT copa_jogo_vencedor_fkey FOREIGN KEY (vencedor) REFERENCES public.perfil(id);


--
-- Name: copa_vaga copa_vaga_copa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_vaga
    ADD CONSTRAINT copa_vaga_copa_id_fkey FOREIGN KEY (copa_id) REFERENCES public.copa(id) ON DELETE CASCADE;


--
-- Name: copa_vaga copa_vaga_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copa_vaga
    ADD CONSTRAINT copa_vaga_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: duelo duelo_carteira_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo
    ADD CONSTRAINT duelo_carteira_a_fkey FOREIGN KEY (carteira_a) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: duelo duelo_carteira_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo
    ADD CONSTRAINT duelo_carteira_b_fkey FOREIGN KEY (carteira_b) REFERENCES public.carteira(id) ON DELETE SET NULL;


--
-- Name: duelo duelo_desafiado_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo
    ADD CONSTRAINT duelo_desafiado_fkey FOREIGN KEY (desafiado) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: duelo duelo_desafiante_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duelo
    ADD CONSTRAINT duelo_desafiante_fkey FOREIGN KEY (desafiante) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: intraday_pessoa intraday_pessoa_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intraday_pessoa
    ADD CONSTRAINT intraday_pessoa_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: intraday_sequencia intraday_sequencia_ultima_rodada_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intraday_sequencia
    ADD CONSTRAINT intraday_sequencia_ultima_rodada_fkey FOREIGN KEY (ultima_rodada) REFERENCES public.rodada(id);


--
-- Name: intraday_sequencia intraday_sequencia_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intraday_sequencia
    ADD CONSTRAINT intraday_sequencia_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: lead_nota lead_nota_lead_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_nota
    ADD CONSTRAINT lead_nota_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.lead(id) ON DELETE CASCADE;


--
-- Name: lead lead_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead
    ADD CONSTRAINT lead_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: nota nota_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nota
    ADD CONSTRAINT nota_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: notificacao notificacao_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notificacao
    ADD CONSTRAINT notificacao_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: perfil perfil_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil
    ADD CONSTRAINT perfil_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: perfil perfil_indicado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil
    ADD CONSTRAINT perfil_indicado_por_fkey FOREIGN KEY (indicado_por) REFERENCES public.perfil(id);


--
-- Name: peso_atual peso_atual_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.peso_atual
    ADD CONSTRAINT peso_atual_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: posicao posicao_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posicao
    ADD CONSTRAINT posicao_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: rebalanceamento rebalanceamento_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rebalanceamento
    ADD CONSTRAINT rebalanceamento_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: regra regra_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regra
    ADD CONSTRAINT regra_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: resumo resumo_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resumo
    ADD CONSTRAINT resumo_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: retorno_dia retorno_dia_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retorno_dia
    ADD CONSTRAINT retorno_dia_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: rodada_gabarito rodada_gabarito_rodada_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada_gabarito
    ADD CONSTRAINT rodada_gabarito_rodada_id_fkey FOREIGN KEY (rodada_id) REFERENCES public.rodada(id) ON DELETE CASCADE;


--
-- Name: rodada_papel rodada_papel_rodada_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rodada_papel
    ADD CONSTRAINT rodada_papel_rodada_id_fkey FOREIGN KEY (rodada_id) REFERENCES public.rodada(id) ON DELETE CASCADE;


--
-- Name: seguidor seguidor_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguidor
    ADD CONSTRAINT seguidor_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: seguidor seguidor_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguidor
    ADD CONSTRAINT seguidor_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: seguindo seguindo_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguindo
    ADD CONSTRAINT seguindo_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


--
-- Name: seguindo seguindo_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seguindo
    ADD CONSTRAINT seguindo_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: time_ time__capitao_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_
    ADD CONSTRAINT time__capitao_fkey FOREIGN KEY (capitao) REFERENCES public.perfil(id) ON DELETE RESTRICT;


--
-- Name: time_ time__encerrado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_
    ADD CONSTRAINT time__encerrado_por_fkey FOREIGN KEY (encerrado_por) REFERENCES public.perfil(id);


--
-- Name: time_carteira_dia time_carteira_dia_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_carteira_dia
    ADD CONSTRAINT time_carteira_dia_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: time_carteira_dia time_carteira_dia_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_carteira_dia
    ADD CONSTRAINT time_carteira_dia_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_ciclo_membro time_ciclo_membro_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_membro
    ADD CONSTRAINT time_ciclo_membro_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE SET NULL;


--
-- Name: time_ciclo_membro time_ciclo_membro_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_membro
    ADD CONSTRAINT time_ciclo_membro_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: time_ciclo_membro time_ciclo_membro_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_membro
    ADD CONSTRAINT time_ciclo_membro_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_ciclo_membro time_ciclo_membro_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_membro
    ADD CONSTRAINT time_ciclo_membro_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: time_ciclo_resultado time_ciclo_resultado_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_resultado
    ADD CONSTRAINT time_ciclo_resultado_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: time_ciclo_resultado time_ciclo_resultado_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_ciclo_resultado
    ADD CONSTRAINT time_ciclo_resultado_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_empate time_empate_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_empate
    ADD CONSTRAINT time_empate_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: time_empate time_empate_escolhido_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_empate
    ADD CONSTRAINT time_empate_escolhido_por_fkey FOREIGN KEY (escolhido_por) REFERENCES public.perfil(id);


--
-- Name: time_empate time_empate_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_empate
    ADD CONSTRAINT time_empate_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_inscricao time_inscricao_ciclo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_inscricao
    ADD CONSTRAINT time_inscricao_ciclo_id_fkey FOREIGN KEY (ciclo_id) REFERENCES public.ciclo(id) ON DELETE CASCADE;


--
-- Name: time_inscricao time_inscricao_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_inscricao
    ADD CONSTRAINT time_inscricao_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_membro time_membro_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro
    ADD CONSTRAINT time_membro_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE SET NULL;


--
-- Name: time_membro time_membro_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro
    ADD CONSTRAINT time_membro_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: time_membro time_membro_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_membro
    ADD CONSTRAINT time_membro_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: time_msg time_msg_apagada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_msg
    ADD CONSTRAINT time_msg_apagada_por_fkey FOREIGN KEY (apagada_por) REFERENCES public.perfil(id);


--
-- Name: time_msg time_msg_autor_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_msg
    ADD CONSTRAINT time_msg_autor_fkey FOREIGN KEY (autor) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: time_msg time_msg_time_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_msg
    ADD CONSTRAINT time_msg_time_id_fkey FOREIGN KEY (time_id) REFERENCES public.time_(id) ON DELETE CASCADE;


--
-- Name: voto voto_rodada_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voto
    ADD CONSTRAINT voto_rodada_id_fkey FOREIGN KEY (rodada_id) REFERENCES public.rodada(id) ON DELETE CASCADE;


--
-- Name: voto voto_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voto
    ADD CONSTRAINT voto_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: aposta; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.aposta ENABLE ROW LEVEL SECURITY;

--
-- Name: aposta aposta_apaga; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY aposta_apaga ON public.aposta FOR DELETE USING (((usuario_id = auth.uid()) AND (data > public.hoje_br())));


--
-- Name: aposta aposta_cria; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY aposta_cria ON public.aposta FOR INSERT WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: aposta aposta_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY aposta_le ON public.aposta FOR SELECT USING (((usuario_id = auth.uid()) OR (data <= public.hoje_br())));


--
-- Name: assinatura assin_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY assin_ler ON public.assinatura FOR SELECT USING (((usuario_id = auth.uid()) OR public.sou_admin()));


--
-- Name: assinatura; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.assinatura ENABLE ROW LEVEL SECURITY;

--
-- Name: barra; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.barra ENABLE ROW LEVEL SECURITY;

--
-- Name: barra barra_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY barra_le ON public.barra FOR SELECT USING (true);


--
-- Name: carteira c_alt; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY c_alt ON public.carteira FOR UPDATE USING ((auth.uid() = usuario_id));


--
-- Name: carteira c_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY c_del ON public.carteira FOR DELETE USING ((auth.uid() = usuario_id));


--
-- Name: carteira c_ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY c_ins ON public.carteira FOR INSERT WITH CHECK ((auth.uid() = usuario_id));


--
-- Name: carteira c_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY c_le ON public.carteira FOR SELECT USING (true);


--
-- Name: carteira; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.carteira ENABLE ROW LEVEL SECURITY;

--
-- Name: cotacao_hora ch_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ch_ler ON public.cotacao_hora FOR SELECT TO authenticated USING (true);


--
-- Name: ciclo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ciclo ENABLE ROW LEVEL SECURITY;

--
-- Name: ciclo ciclo_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ciclo_ler ON public.ciclo FOR SELECT TO authenticated USING (true);


--
-- Name: copa_jogo cj_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cj_ler ON public.copa_jogo FOR SELECT TO authenticated USING (true);


--
-- Name: conquista conq_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY conq_ler ON public.conquista FOR SELECT TO authenticated USING (true);


--
-- Name: conquista; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conquista ENABLE ROW LEVEL SECURITY;

--
-- Name: conta_arquivada; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conta_arquivada ENABLE ROW LEVEL SECURITY;

--
-- Name: copa; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.copa ENABLE ROW LEVEL SECURITY;

--
-- Name: copa_jogo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.copa_jogo ENABLE ROW LEVEL SECURITY;

--
-- Name: copa copa_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY copa_ler ON public.copa FOR SELECT TO authenticated USING (true);


--
-- Name: copa_vaga; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.copa_vaga ENABLE ROW LEVEL SECURITY;

--
-- Name: cotacao_hora; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cotacao_hora ENABLE ROW LEVEL SECURITY;

--
-- Name: cotacao_viva; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cotacao_viva ENABLE ROW LEVEL SECURITY;

--
-- Name: cotacao_viva cotacao_viva_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cotacao_viva_le ON public.cotacao_viva FOR SELECT USING (true);


--
-- Name: copa_vaga cv_entrar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cv_entrar ON public.copa_vaga FOR INSERT TO authenticated WITH CHECK (((usuario_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.copa c
  WHERE ((c.id = copa_vaga.copa_id) AND (c.situacao = 'inscricoes'::text))))));


--
-- Name: copa_vaga cv_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cv_ler ON public.copa_vaga FOR SELECT TO authenticated USING (true);


--
-- Name: duelo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.duelo ENABLE ROW LEVEL SECURITY;

--
-- Name: duelo duelo_criar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY duelo_criar ON public.duelo FOR INSERT TO authenticated WITH CHECK (((desafiante = auth.uid()) AND (situacao = 'convidado'::text) AND (EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = duelo.carteira_a) AND (c.usuario_id = auth.uid()) AND c.ativa AND (c.classe = duelo.classe)))) AND (fim >= (inicio + 5))));


--
-- Name: duelo duelo_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY duelo_ler ON public.duelo FOR SELECT TO authenticated USING (true);


--
-- Name: duelo duelo_mudar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY duelo_mudar ON public.duelo FOR UPDATE TO authenticated USING ((((desafiado = auth.uid()) AND (situacao = 'convidado'::text)) OR ((desafiante = auth.uid()) AND (situacao = 'convidado'::text)) OR public.sou_admin())) WITH CHECK ((((desafiado = auth.uid()) AND (situacao = ANY (ARRAY['aceito'::text, 'recusado'::text]))) OR ((desafiante = auth.uid()) AND (situacao = 'cancelado'::text)) OR public.sou_admin()));


--
-- Name: faixa_volume; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.faixa_volume ENABLE ROW LEVEL SECURITY;

--
-- Name: fechamento; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fechamento ENABLE ROW LEVEL SECURITY;

--
-- Name: fila_email; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fila_email ENABLE ROW LEVEL SECURITY;

--
-- Name: faixa_volume fx_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fx_ler ON public.faixa_volume FOR SELECT TO authenticated USING (true);


--
-- Name: rodada_gabarito gab_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY gab_ler ON public.rodada_gabarito FOR SELECT TO authenticated USING (true);


--
-- Name: intraday_pessoa; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.intraday_pessoa ENABLE ROW LEVEL SECURITY;

--
-- Name: intraday_sequencia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.intraday_sequencia ENABLE ROW LEVEL SECURITY;

--
-- Name: intraday_pessoa ip_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ip_ler ON public.intraday_pessoa FOR SELECT TO authenticated USING (true);


--
-- Name: intraday_sequencia is_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY is_ler ON public.intraday_sequencia FOR SELECT TO authenticated USING (true);


--
-- Name: lead; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lead ENABLE ROW LEVEL SECURITY;

--
-- Name: lead lead_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_apagar ON public.lead FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.perfil p
  WHERE ((p.id = auth.uid()) AND p.admin))));


--
-- Name: lead lead_deixar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_deixar ON public.lead FOR INSERT TO authenticated, anon WITH CHECK (true);


--
-- Name: lead lead_dono; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_dono ON public.lead TO authenticated USING ((usuario_id = auth.uid())) WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: lead lead_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_ler ON public.lead FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin))));


--
-- Name: lead lead_marcar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_marcar ON public.lead FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin))));


--
-- Name: lead_nota; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lead_nota ENABLE ROW LEVEL SECURITY;

--
-- Name: lead_nota lead_nota_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_nota_apagar ON public.lead_nota FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.perfil p
  WHERE ((p.id = auth.uid()) AND p.admin))));


--
-- Name: time_msg msg_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY msg_apagar ON public.time_msg FOR UPDATE TO authenticated USING (((autor = auth.uid()) OR public.sou_capitao(time_id) OR public.sou_admin())) WITH CHECK (((autor = auth.uid()) OR public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_msg msg_escrever; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY msg_escrever ON public.time_msg FOR INSERT TO authenticated WITH CHECK (((autor = auth.uid()) AND (public.sou_do_time(time_id) OR public.sou_capitao(time_id)) AND (NOT (EXISTS ( SELECT 1
   FROM public.time_membro m
  WHERE ((m.time_id = time_msg.time_id) AND (m.usuario_id = auth.uid()) AND m.silenciado))))));


--
-- Name: time_msg msg_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY msg_ler ON public.time_msg FOR SELECT TO authenticated USING ((public.sou_do_time(time_id) OR public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_msg msg_sumir; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY msg_sumir ON public.time_msg FOR DELETE TO authenticated USING ((public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: nota n_ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY n_ins ON public.nota FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = nota.carteira_id) AND (c.usuario_id = auth.uid())))));


--
-- Name: nota n_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY n_le ON public.nota FOR SELECT USING ((auth.uid() IS NOT NULL));


--
-- Name: nota; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.nota ENABLE ROW LEVEL SECURITY;

--
-- Name: lead_nota nota_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nota_admin ON public.lead_nota TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin))));


--
-- Name: notificacao notif_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notif_apagar ON public.notificacao FOR DELETE USING ((usuario_id = auth.uid()));


--
-- Name: notificacao notif_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notif_ler ON public.notificacao FOR SELECT USING ((usuario_id = auth.uid()));


--
-- Name: notificacao notif_marcar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notif_marcar ON public.notificacao FOR UPDATE USING ((usuario_id = auth.uid())) WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: notificacao; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notificacao ENABLE ROW LEVEL SECURITY;

--
-- Name: oscilacao o_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY o_le ON public.oscilacao FOR SELECT USING (true);


--
-- Name: oscilacao; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.oscilacao ENABLE ROW LEVEL SECURITY;

--
-- Name: oscilacao_foto; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.oscilacao_foto ENABLE ROW LEVEL SECURITY;

--
-- Name: perfil p_alt; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_alt ON public.perfil FOR UPDATE USING ((auth.uid() = id));


--
-- Name: perfil p_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_le ON public.perfil FOR SELECT TO authenticated USING (((id = auth.uid()) OR (indicado_por = auth.uid()) OR public.sou_admin()));


--
-- Name: peso_atual pa_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pa_le ON public.peso_atual FOR SELECT USING ((auth.uid() IS NOT NULL));


--
-- Name: papel_fila; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.papel_fila ENABLE ROW LEVEL SECURITY;

--
-- Name: papel_fila papel_fila_leitura; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY papel_fila_leitura ON public.papel_fila FOR SELECT USING (true);


--
-- Name: parametro; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parametro ENABLE ROW LEVEL SECURITY;

--
-- Name: perfil; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.perfil ENABLE ROW LEVEL SECURITY;

--
-- Name: peso_atual; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.peso_atual ENABLE ROW LEVEL SECURITY;

--
-- Name: peso_atual_backup; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.peso_atual_backup ENABLE ROW LEVEL SECURITY;

--
-- Name: posicao pos_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_del ON public.posicao FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = posicao.carteira_id) AND (c.usuario_id = auth.uid())))));


--
-- Name: posicao pos_ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_ins ON public.posicao FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = posicao.carteira_id) AND (c.usuario_id = auth.uid())))));


--
-- Name: posicao pos_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_le ON public.posicao FOR SELECT USING ((auth.uid() IS NOT NULL));


--
-- Name: posicao; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.posicao ENABLE ROW LEVEL SECURITY;

--
-- Name: retorno_dia r_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY r_le ON public.retorno_dia FOR SELECT USING (true);


--
-- Name: rebalanceamento rebal_grava; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rebal_grava ON public.rebalanceamento FOR INSERT WITH CHECK (public.sou_admin());


--
-- Name: rebalanceamento rebal_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rebal_le ON public.rebalanceamento FOR SELECT USING (true);


--
-- Name: rebalanceamento; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rebalanceamento ENABLE ROW LEVEL SECURITY;

--
-- Name: regra; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.regra ENABLE ROW LEVEL SECURITY;

--
-- Name: regra regra_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY regra_ler ON public.regra FOR SELECT TO authenticated, anon USING (true);


--
-- Name: regra regra_minha; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY regra_minha ON public.regra TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = regra.carteira_id) AND (c.usuario_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = regra.carteira_id) AND (c.usuario_id = auth.uid())))));


--
-- Name: resumo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resumo ENABLE ROW LEVEL SECURITY;

--
-- Name: resumo resumo_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY resumo_ler ON public.resumo FOR SELECT TO authenticated, anon USING (true);


--
-- Name: retorno_dia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retorno_dia ENABLE ROW LEVEL SECURITY;

--
-- Name: rodada rod_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rod_ler ON public.rodada FOR SELECT TO authenticated USING (true);


--
-- Name: rodada; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rodada ENABLE ROW LEVEL SECURITY;

--
-- Name: rodada_gabarito; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rodada_gabarito ENABLE ROW LEVEL SECURITY;

--
-- Name: rodada_papel; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rodada_papel ENABLE ROW LEVEL SECURITY;

--
-- Name: rodada_papel rp_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rp_ler ON public.rodada_papel FOR SELECT TO authenticated USING (true);


--
-- Name: seguindo s_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY s_del ON public.seguindo FOR DELETE USING ((auth.uid() = usuario_id));


--
-- Name: seguindo s_ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY s_ins ON public.seguindo FOR INSERT WITH CHECK ((auth.uid() = usuario_id));


--
-- Name: seguindo s_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY s_le ON public.seguindo FOR SELECT USING ((auth.uid() = usuario_id));


--
-- Name: seguidor; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seguidor ENABLE ROW LEVEL SECURITY;

--
-- Name: seguidor seguidor_meu; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seguidor_meu ON public.seguidor TO authenticated USING (((usuario_id = auth.uid()) OR public.sou_admin())) WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: seguindo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seguindo ENABLE ROW LEVEL SECURITY;

--
-- Name: time_carteira_dia tcd_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tcd_ler ON public.time_carteira_dia FOR SELECT TO authenticated USING (true);


--
-- Name: time_ciclo_membro tcm_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tcm_ler ON public.time_ciclo_membro FOR SELECT TO authenticated USING (true);


--
-- Name: time_ciclo_resultado tcr_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tcr_ler ON public.time_ciclo_resultado FOR SELECT TO authenticated USING (true);


--
-- Name: time_empate temp_escolher; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY temp_escolher ON public.time_empate FOR UPDATE TO authenticated USING ((public.sou_capitao(time_id) OR public.sou_admin())) WITH CHECK ((public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_empate temp_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY temp_ler ON public.time_empate FOR SELECT TO authenticated USING (true);


--
-- Name: time_; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_ ENABLE ROW LEVEL SECURITY;

--
-- Name: time_carteira_dia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_carteira_dia ENABLE ROW LEVEL SECURITY;

--
-- Name: time_ciclo_membro; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_ciclo_membro ENABLE ROW LEVEL SECURITY;

--
-- Name: time_ciclo_resultado; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_ciclo_resultado ENABLE ROW LEVEL SECURITY;

--
-- Name: time_ time_criar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY time_criar ON public.time_ FOR INSERT TO authenticated WITH CHECK (((capitao = auth.uid()) AND (NOT (EXISTS ( SELECT 1
   FROM public.perfil p
  WHERE ((p.id = auth.uid()) AND p.bloqueado))))));


--
-- Name: time_empate; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_empate ENABLE ROW LEVEL SECURITY;

--
-- Name: time_inscricao; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_inscricao ENABLE ROW LEVEL SECURITY;

--
-- Name: time_ time_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY time_ler ON public.time_ FOR SELECT TO authenticated USING (true);


--
-- Name: time_membro; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_membro ENABLE ROW LEVEL SECURITY;

--
-- Name: time_ time_mexer; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY time_mexer ON public.time_ FOR UPDATE TO authenticated USING (((capitao = auth.uid()) OR public.sou_admin())) WITH CHECK (((capitao = auth.uid()) OR public.sou_admin()));


--
-- Name: time_msg; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_msg ENABLE ROW LEVEL SECURITY;

--
-- Name: time_inscricao tins_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tins_apagar ON public.time_inscricao FOR DELETE TO authenticated USING ((public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_inscricao tins_criar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tins_criar ON public.time_inscricao FOR INSERT TO authenticated WITH CHECK (public.sou_capitao(time_id));


--
-- Name: time_inscricao tins_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tins_ler ON public.time_inscricao FOR SELECT TO authenticated USING (true);


--
-- Name: time_membro tm_apagar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tm_apagar ON public.time_membro FOR DELETE TO authenticated USING ((public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_membro tm_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tm_ler ON public.time_membro FOR SELECT TO authenticated USING (true);


--
-- Name: time_membro tm_mexer; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tm_mexer ON public.time_membro FOR UPDATE TO authenticated USING (((usuario_id = auth.uid()) OR public.sou_capitao(time_id) OR public.sou_admin())) WITH CHECK (((usuario_id = auth.uid()) OR public.sou_capitao(time_id) OR public.sou_admin()));


--
-- Name: time_membro tm_pedir; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tm_pedir ON public.time_membro FOR INSERT TO authenticated WITH CHECK (((usuario_id = auth.uid()) AND (situacao = 'pedido'::text)));


--
-- Name: universo u_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY u_le ON public.universo FOR SELECT USING (true);


--
-- Name: universo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.universo ENABLE ROW LEVEL SECURITY;

--
-- Name: universo universo_mexer; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY universo_mexer ON public.universo TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.perfil
  WHERE ((perfil.id = auth.uid()) AND perfil.admin))));


--
-- Name: voto; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.voto ENABLE ROW LEVEL SECURITY;

--
-- Name: voto voto_ler; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voto_ler ON public.voto FOR SELECT TO authenticated USING (((usuario_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM public.rodada r
  WHERE ((r.id = voto.rodada_id) AND (r.situacao = 'apurada'::text))))));


--
-- Name: voto voto_mudar; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voto_mudar ON public.voto FOR UPDATE TO authenticated USING (((usuario_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.rodada r
  WHERE ((r.id = voto.rodada_id) AND (r.situacao = 'aberta'::text) AND (now() < r.fecha_em)))))) WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: voto voto_por; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voto_por ON public.voto FOR INSERT TO authenticated WITH CHECK (((usuario_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.rodada r
  WHERE ((r.id = voto.rodada_id) AND (r.situacao = 'aberta'::text) AND (now() < r.fecha_em))))));


--
-- PostgreSQL database dump complete
--

\unrestrict Uk0EYjE4FurP1Rc7Qn7Q1gsJxMOOM4HObR28ZcVffdHreVVFvQXOp8pHSA7aBvl

