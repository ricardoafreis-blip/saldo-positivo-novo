--
-- PostgreSQL database dump
--

\restrict nBdydjUCH1UHRIVGO3WDasF1Npx5U8BlvfXYMlKUBtopsyV2p9668DH4siQrW6X

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Ubuntu 17.10-1.pgdg24.04+1)

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
    CONSTRAINT lead_cep_ok CHECK (((cep IS NULL) OR (cep ~ '^\d{8}$'::text))),
    CONSTRAINT lead_cpf_ok CHECK (((cpf IS NULL) OR public.cpf_valido(cpf))),
    CONSTRAINT lead_origem_ok CHECK ((origem = ANY (ARRAY['cadastro'::text, 'assinatura'::text, 'manual'::text, 'importado'::text]))),
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
-- Name: fechar_dia(date, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fechar_dia(d date DEFAULT NULL::date, refazer boolean DEFAULT false) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare
  c        record;
  cdi_dia  real;
  fallback real := power(1.145, 1.0/252) - 1;   -- só se o LFTS11 faltar
  ret      real;
  l real; s real; caixa real; rende real;
  idx_ant  real;
  n        int := 0;
  m_novo   date; m_atual date;
  dia      date := coalesce(d, (select max(data) from oscilacao), hoje_br());
  vira_sem boolean; vira_mes boolean; vira_ano boolean;
  fora     boolean; jafechou boolean; motivo text;
begin
  if not coalesce((select admin from perfil where id = auth.uid()), false)
     and coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'só admin';
  end if;

  -- O caixa rende o que a RENDA FIXA rendeu de verdade naquele pregão,
  -- medido pelo LFTS11 (ETF de LFT, acompanha a Selic). Antes era uma
  -- constante de 10,5% ao ano escrita aqui dentro — e o CDI está em
  -- 14,5%, ou seja, o caixa vinha rendendo 4 pontos a menos ao ano sem
  -- ninguém ter onde corrigir. Se o LFTS11 faltar no dia, cai no
  -- fallback e o aviso sai no log.
  select valor into cdi_dia from oscilacao where ativo = 'LFTS11' and data = dia;
  if cdi_dia is null then
    cdi_dia := fallback;
    raise notice 'sem LFTS11 em % — caixa remunerado pela taxa de reserva', dia;
  end if;

  jafechou := exists (select 1 from retorno_dia where data = dia);
  if not refazer and jafechou then
    raise notice 'pregão % já fechado', dia;
    return 0;
  end if;

  vira_sem := date_trunc('week',  proximo_pregao(dia)) <> date_trunc('week',  dia);
  vira_mes := date_trunc('month', proximo_pregao(dia)) <> date_trunc('month', dia);
  vira_ano := date_trunc('year',  proximo_pregao(dia)) <> date_trunc('year',  dia);

  for c in select id, rebalancear, banda_pct from carteira where ativa loop

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
    caixa := 100 - (l - s);
    rende := least(caixa, 100.0);

    select coalesce(sum((pa.peso/100.0) * coalesce(o.valor, 0)), 0)
      into ret
      from peso_atual pa
      left join oscilacao o on o.ativo = pa.ativo and o.data = dia
     where pa.carteira_id = c.id;
    ret := ret + (rende/100.0) * cdi_dia;

    select indice into idx_ant from retorno_dia
     where carteira_id = c.id and data < dia order by data desc limit 1;
    idx_ant := coalesce(idx_ant, 100.0);

    insert into retorno_dia (carteira_id, data, retorno, indice)
    values (c.id, dia, ret, idx_ant * (1 + ret))
    on conflict (carteira_id, data) do update
       set retorno = excluded.retorno, indice = excluded.indice;

    update peso_atual pa
       set peso = pa.peso * (1 + coalesce(o.valor, 0)) / (1 + ret)
      from (select ativo, valor from oscilacao where data = dia) o
     where pa.carteira_id = c.id and pa.ativo = o.ativo and (1 + ret) <> 0;

    fora := false;
    if c.rebalancear = 'banda' and m_atual is not null then
      select exists (
        select 1 from peso_atual pa
          left join (select ativo, sum(peso) as dec from posicao
                      where carteira_id = c.id and valida_de = m_atual group by ativo) q
            on q.ativo = pa.ativo
         where pa.carteira_id = c.id
           and abs(abs(pa.peso) - abs(coalesce(q.dec, 0))) > c.banda_pct) into fora;
    end if;

    motivo := null;
    if m_atual is not null then
      if    c.rebalancear = 'semanal' and vira_sem then motivo := 'semanal';
      elsif c.rebalancear = 'mensal'  and vira_mes then motivo := 'mensal';
      elsif c.rebalancear = 'anual'   and vira_ano then motivo := 'anual';
      elsif c.rebalancear = 'banda'   and fora     then
        motivo := 'banda de ' || round(c.banda_pct) || ' p.p. estourada';
      end if;
    end if;

    if motivo is not null then
      delete from peso_atual where carteira_id = c.id;
      insert into peso_atual (carteira_id, ativo, peso, marco)
      select carteira_id, ativo, sum(peso), m_atual
        from posicao where carteira_id = c.id and valida_de = m_atual
       group by carteira_id, ativo;
      insert into rebalanceamento (carteira_id, data, motivo)
      values (c.id, dia, motivo)
      on conflict (carteira_id, data) do update set motivo = excluded.motivo;
    end if;

    perform recalcular_exposicao_atual(c.id);
    n := n + 1;
  end loop;

  return n;
end $$;


--
-- Name: fora_da_banda(bigint, date, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fora_da_banda(cid bigint, marco date, banda real) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
declare cl text; b_atual real; b_decl real;
begin
  select classe into cl from carteira where id = cid;

  -- Na 60/40 o que deriva é a PROPORÇÃO entre renda fixa e ações, não
  -- cada papel. Dez ações de 4% nunca se afastam 5 pontos sozinhas, mas
  -- o bloco todo vai de 40 para 50 e descaracteriza a carteira.
  if cl = 'sessenta_quarenta' then
    select coalesce(sum(abs(peso)),0) into b_atual from peso_atual where carteira_id = cid;
    select coalesce(sum(abs(peso)),0) into b_decl  from posicao
     where carteira_id = cid and valida_de = marco;
    return abs(b_atual - b_decl) > banda;
  end if;

  return exists (
    select 1
      from peso_atual pa
      left join (select ativo, sum(peso) as dec from posicao
                  where carteira_id = cid and valida_de = marco group by ativo) q
        on q.ativo = pa.ativo
     where pa.carteira_id = cid
       and abs(abs(pa.peso) - abs(coalesce(q.dec, 0))) > banda);
end $$;


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
-- Name: mt5_gravar(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mt5_gravar(dados jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n_fech int; n_osc int; d_min date; d_max date; papel text;
begin
  -- Quem pode gravar: a service_role (chave-mestra, so o dono tem) ou
  -- uma conta marcada como admin. A service_role nao tem auth.uid(),
  -- entao perguntar "quem e voce" nao funciona para ela — o que
  -- funciona e perguntar o PAPEL da conexao.
  papel := coalesce(current_setting('request.jwt.claim.role', true),
                    current_setting('role', true), '');
  if papel <> 'service_role'
     and not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'so admin pode gravar cotacao (papel: %)', papel;
  end if;

  with e as (
    select x.ativo, x.data, x.fech
      from jsonb_to_recordset(dados) as x(ativo text, data date, fech real)
     where x.ativo is not null and x.data is not null and x.fech > 0
  ), g as (
    insert into fechamento (ativo, data, fech)
    select ativo, data, fech from e
    on conflict (ativo, data) do update set fech = excluded.fech
    returning 1
  )
  select count(*) into n_fech from g;

  select min(x.data), max(x.data) into d_min, d_max
    from jsonb_to_recordset(dados) as x(ativo text, data date, fech real);

  with a as (
    select distinct x.ativo from jsonb_to_recordset(dados) as x(ativo text, data date, fech real)
  ), p as (
    select f.ativo, f.data, f.fech,
           lag(f.fech) over (partition by f.ativo order by f.data) as ant
      from fechamento f where f.ativo in (select ativo from a)
  ), g2 as (
    insert into oscilacao (ativo, data, valor)
    select ativo, data, fech/ant - 1 from p
     where ant is not null and ant > 0 and data between d_min and d_max
    on conflict (ativo, data) do update set valor = excluded.valor
    returning 1
  )
  select count(*) into n_osc from g2;

  return jsonb_build_object('fechamentos', n_fech, 'oscilacoes', n_osc);
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
                     as x(ativo text, preco real, ant real, abre real));

  insert into cotacao_viva (ativo, valor, preco, abertura, atualizado_em)
  select x.ativo, x.preco/x.ant - 1, x.preco, nullif(x.abre, 0), now()
    from jsonb_to_recordset(dados) as x(ativo text, preco real, ant real, abre real)
   where x.ativo is not null and x.preco > 0 and x.ant > 0;

  get diagnostics n = row_count;
  return jsonb_build_object('gravados', n, 'quando', now());
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
-- Name: recalcular_exposicao(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalcular_exposicao(cid bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  l real; s real; marco date;
begin
  select max(valida_de) into marco from posicao where carteira_id = cid;
  select coalesce(sum(peso) filter (where peso > 0), 0),
        -coalesce(sum(peso) filter (where peso < 0), 0)
    into l, s
    from posicao where carteira_id = cid and valida_de = marco;

  update carteira set
    bruta    = l + s,
    liquida  = l - s,
    caixa    = 100 - (l - s),      -- venda a descoberto ENTRA dinheiro
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
    bruta = l + s, liquida = l - s, caixa = 100 - (l - s),
    n_ativos = (select count(*) from peso_atual where carteira_id = cid)
  where id = cid;
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
-- Name: robo_fechar_dia(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.robo_fechar_dia(d date DEFAULT NULL::date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  return fechar_dia(coalesce(d, (select max(data) from oscilacao)));
end $$;


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
-- Name: seguir(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seguir(cid bigint, valor boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;

  if valor then
    if not coalesce((select p.assinante from perfil p where p.id = auth.uid()), false) then
      raise exception 'acompanhar por e-mail é para assinantes';
    end if;
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
-- Name: sou_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sou_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select p.admin from perfil p where p.id = auth.uid()), false)
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
-- Name: barra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.barra (
    ativo text NOT NULL,
    data date NOT NULL,
    abertura real NOT NULL,
    maxima real NOT NULL,
    minima real NOT NULL,
    fechamento real NOT NULL
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
-- Name: cotacao_viva; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotacao_viva (
    ativo text NOT NULL,
    valor real NOT NULL,
    preco real,
    atualizado_em timestamp with time zone DEFAULT now() NOT NULL,
    abertura real
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
 SELECT referencia.ativo
   FROM public.referencia;


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
-- Name: peso_atual_backup; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.peso_atual_backup (
    carteira_id bigint,
    ativo text,
    peso real,
    marco date
);


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
    motivo text NOT NULL
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
    ((sum(((pa.peso / (100.0)::double precision) * COALESCE(v.valor, (0)::real))) + ((LEAST(((100)::double precision - (e.l - e.s)), (100.0)::double precision) / (100.0)::double precision) * ((power(1.105, (1.0 / (252)::numeric)) - (1)::numeric))::double precision)))::real AS retorno,
    max(v.atualizado_em) AS atualizado_em,
    count(v.ativo) AS com_cotacao,
    count(*) AS papeis
   FROM ((public.peso_atual pa
     JOIN expo e ON ((e.carteira_id = pa.carteira_id)))
     LEFT JOIN public.cotacao_viva v ON ((v.ativo = pa.ativo)))
  GROUP BY pa.carteira_id, e.l, e.s;


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
-- Name: universo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.universo (
    ativo text NOT NULL,
    cotacao real,
    liquidez real
);


--
-- Name: aposta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta ALTER COLUMN id SET DEFAULT nextval('public.aposta_id_seq'::regclass);


--
-- Name: carteira id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carteira ALTER COLUMN id SET DEFAULT nextval('public.carteira_id_seq'::regclass);


--
-- Name: nota id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nota ALTER COLUMN id SET DEFAULT nextval('public.nota_id_seq'::regclass);


--
-- Name: posicao id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posicao ALTER COLUMN id SET DEFAULT nextval('public.posicao_id_seq'::regclass);


--
-- Name: perfil apelido_formato; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.perfil
    ADD CONSTRAINT apelido_formato CHECK ((apelido ~ '^[A-Za-z0-9._-]{3,24}$'::text)) NOT VALID;


--
-- Name: perfil apelido_reservado; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.perfil
    ADD CONSTRAINT apelido_reservado CHECK ((lower(apelido) <> ALL (ARRAY['admin'::text, 'administrador'::text, 'adm'::text, 'root'::text, 'sistema'::text, 'suporte'::text, 'moderador'::text, 'contato'::text, 'oficial'::text, 'saldopositivo'::text, 'saldo-positivo'::text, 'ranking'::text]))) NOT VALID;


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
-- Name: cotacao_viva cotacao_viva_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotacao_viva
    ADD CONSTRAINT cotacao_viva_pkey PRIMARY KEY (ativo);


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
-- Name: lead lead_cpf_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead
    ADD CONSTRAINT lead_cpf_key UNIQUE (cpf);


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
-- Name: oscilacao oscilacao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oscilacao
    ADD CONSTRAINT oscilacao_pkey PRIMARY KEY (ativo, data);


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
-- Name: retorno_dia retorno_dia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retorno_dia
    ADD CONSTRAINT retorno_dia_pkey PRIMARY KEY (carteira_id, data);


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
-- Name: universo universo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.universo
    ADD CONSTRAINT universo_pkey PRIMARY KEY (ativo);


--
-- Name: aposta_data; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX aposta_data ON public.aposta USING btree (data);


--
-- Name: carteira_nome_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX carteira_nome_unico ON public.carteira USING btree (usuario_id, lower(TRIM(BOTH FROM nome))) WHERE ativa;


--
-- Name: fila_email_pendente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fila_email_pendente ON public.fila_email USING btree (criado_em) WHERE (enviado_em IS NULL);


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
-- Name: aposta aposta_trava; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aposta_trava BEFORE INSERT ON public.aposta FOR EACH ROW EXECUTE FUNCTION public.trava_aposta();


--
-- Name: carteira carteira_trava_classe; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER carteira_trava_classe BEFORE UPDATE ON public.carteira FOR EACH ROW EXECUTE FUNCTION public.trava_classe();


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
-- Name: aposta aposta_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.aposta
    ADD CONSTRAINT aposta_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


--
-- Name: carteira carteira_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carteira
    ADD CONSTRAINT carteira_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.perfil(id) ON DELETE CASCADE;


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
-- Name: retorno_dia retorno_dia_carteira_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retorno_dia
    ADD CONSTRAINT retorno_dia_carteira_id_fkey FOREIGN KEY (carteira_id) REFERENCES public.carteira(id) ON DELETE CASCADE;


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
-- Name: cotacao_viva; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cotacao_viva ENABLE ROW LEVEL SECURITY;

--
-- Name: cotacao_viva cotacao_viva_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cotacao_viva_le ON public.cotacao_viva FOR SELECT USING (true);


--
-- Name: fechamento; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fechamento ENABLE ROW LEVEL SECURITY;

--
-- Name: fila_email; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fila_email ENABLE ROW LEVEL SECURITY;

--
-- Name: lead; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lead ENABLE ROW LEVEL SECURITY;

--
-- Name: lead lead_dono; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_dono ON public.lead TO authenticated USING ((usuario_id = auth.uid())) WITH CHECK ((usuario_id = auth.uid()));


--
-- Name: nota n_ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY n_ins ON public.nota FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = nota.carteira_id) AND (c.usuario_id = auth.uid())))));


--
-- Name: nota n_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY n_le ON public.nota FOR SELECT USING ((public.eh_assinante() OR (EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = nota.carteira_id) AND (c.usuario_id = auth.uid()))))));


--
-- Name: nota; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.nota ENABLE ROW LEVEL SECURITY;

--
-- Name: oscilacao o_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY o_le ON public.oscilacao FOR SELECT USING (true);


--
-- Name: oscilacao; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.oscilacao ENABLE ROW LEVEL SECURITY;

--
-- Name: perfil p_alt; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_alt ON public.perfil FOR UPDATE USING ((auth.uid() = id));


--
-- Name: perfil p_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_le ON public.perfil FOR SELECT USING (true);


--
-- Name: peso_atual pa_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pa_le ON public.peso_atual FOR SELECT USING ((public.eh_assinante() OR (EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = peso_atual.carteira_id) AND (c.usuario_id = auth.uid()))))));


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

CREATE POLICY pos_le ON public.posicao FOR SELECT USING ((public.eh_assinante() OR (EXISTS ( SELECT 1
   FROM public.carteira c
  WHERE ((c.id = posicao.carteira_id) AND (c.usuario_id = auth.uid()))))));


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
-- Name: retorno_dia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.retorno_dia ENABLE ROW LEVEL SECURITY;

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
-- Name: universo u_le; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY u_le ON public.universo FOR SELECT USING (true);


--
-- Name: universo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.universo ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict nBdydjUCH1UHRIVGO3WDasF1Npx5U8BlvfXYMlKUBtopsyV2p9668DH4siQrW6X

