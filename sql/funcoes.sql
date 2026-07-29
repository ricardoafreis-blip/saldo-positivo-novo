-- ═══════════════════════════════════════════════════════════════════
-- Saldo Positivo — funções do banco
-- Extraído de pg_get_functiondef em 29/07/2026, já com banco8 e banco9.
--
-- ⚠️ ISTO NÃO RECONSTRÓI O BANCO SOZINHO.
-- Aqui só há funções. Faltam tabelas, colunas, chaves, índices,
-- políticas RLS e gatilhos. Sem essas peças o arquivo não roda do zero.
-- Ver o rodapé para as consultas que completam o dump.
--
-- Ordem: dependência primeiro. Rodando de cima para baixo, nenhuma
-- função chama outra que ainda não existe.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. datas ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.hoje_br()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  select (now() at time zone 'America/Sao_Paulo')::date;
$function$;

CREATE OR REPLACE FUNCTION public.proximo_pregao(a_partir date DEFAULT NULL::date)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  select case extract(isodow from coalesce(a_partir, hoje_br()))
           when 5 then coalesce(a_partir, hoje_br()) + 3   -- sexta  → segunda
           when 6 then coalesce(a_partir, hoje_br()) + 2   -- sábado → segunda
           when 7 then coalesce(a_partir, hoje_br()) + 1   -- domingo→ segunda
           else        coalesce(a_partir, hoje_br()) + 1
         end;
$function$;


-- ─── 2. validação ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.cpf_valido(t text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
end $function$;


-- ─── 3. quem é quem ────────────────────────────────────────────────
-- sou_admin PRECISA ser SECURITY DEFINER: lê perfil, que tem RLS.
-- Sem DEFINER, qualquer policy que a chame entra em recursão infinita.

CREATE OR REPLACE FUNCTION public.sou_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select p.admin from perfil p where p.id = auth.uid()), false)
$function$;

CREATE OR REPLACE FUNCTION public.eh_assinante()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select assinante or admin from perfil where id = auth.uid()), false);
$function$;

CREATE OR REPLACE FUNCTION public.pode_mexer(dono uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select dono = auth.uid() or sou_admin()
$function$;

CREATE OR REPLACE FUNCTION public.apelido_livre(t text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select btrim(coalesce(t,'')) ~ '^[A-Za-z0-9._-]{3,24}$'
     and lower(btrim(t)) <> all (array[
       'admin','administrador','adm','root','sistema','suporte','moderador',
       'contato','oficial','saldopositivo','saldo-positivo','ranking'])
     and not exists (
       select 1 from perfil p where lower(p.apelido) = lower(btrim(t)))
$function$;


-- ─── 4. funções de gatilho ─────────────────────────────────────────
-- Os gatilhos em si não estão aqui — são objetos de tabela.
-- novo_usuario e lead_do_cadastro penduram em auth.users.
-- trava_privilegio: BEFORE UPDATE em perfil. É ela que impede alguém
-- de se marcar assinante pelo console — RLS restringe linha, não coluna.

CREATE OR REPLACE FUNCTION public.novo_usuario()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.lead_do_cadastro()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.lead_normaliza()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.cpf      := nullif(regexp_replace(coalesce(new.cpf,''),      '\D','','g'), '');
  new.cep      := nullif(regexp_replace(coalesce(new.cep,''),      '\D','','g'), '');
  new.telefone := nullif(regexp_replace(coalesce(new.telefone,''), '\D','','g'), '');
  new.uf       := upper(nullif(btrim(coalesce(new.uf,'')), ''));
  new.email    := lower(nullif(btrim(coalesce(new.email,'')), ''));
  new.nome_completo := nullif(btrim(coalesce(new.nome_completo,'')), '');
  new.atualizado_em := now();
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.trava_privilegio()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;


-- ─── 5. exposição ──────────────────────────────────────────────────
-- As duas escrevem NAS MESMAS COLUNAS de carteira. A diferença é a
-- fonte: recalcular_exposicao lê posicao (o declarado),
-- recalcular_exposicao_atual lê peso_atual (o declarado + a deriva).
-- Quem roda por último manda.
-- Caixa = 100 − líquida: venda a descoberto ENTRA dinheiro.

CREATE OR REPLACE FUNCTION public.recalcular_exposicao(cid bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.recalcular_exposicao_atual(cid bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l real; s real;
begin
  select coalesce(sum(peso) filter (where peso > 0), 0),
        -coalesce(sum(peso) filter (where peso < 0), 0)
    into l, s from peso_atual where carteira_id = cid;

  update carteira set
    bruta = l + s, liquida = l - s, caixa = 100 - (l - s),
    n_ativos = (select count(*) from peso_atual where carteira_id = cid)
  where id = cid;
end $function$;


-- ─── 6. declaração ─────────────────────────────────────────────────
-- banco8 + banco9: declaração vale a partir do próximo pregão.
-- posicao guarda o histórico com valida_de; peso_atual é a foto de
-- agora, com marco dizendo qual declaração está carregada.

CREATE OR REPLACE FUNCTION public.ao_declarar_posicao()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

CREATE OR REPLACE FUNCTION public.declarar(cid bigint, pesos jsonb, nota_txt text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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


-- ─── 7. o dia ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.gravar_oscilacao(dados jsonb, d date DEFAULT CURRENT_DATE)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int := 0;
begin
  if not coalesce((select admin from perfil where id = auth.uid()), false) then
    raise exception 'só admin';
  end if;

  insert into oscilacao (ativo, data, valor, data_cot)
  select upper(x->>'ativo'), d, (x->>'valor')::real,
         nullif(x->>'data_cot','')::date
    from jsonb_array_elements(dados) x
  on conflict (ativo, data) do update
     set valor = excluded.valor, data_cot = excluded.data_cot;

  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.fechar_dia(d date DEFAULT CURRENT_DATE)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- ⚠️ NÃO É IDEMPOTENTE. Rodar duas vezes para o mesmo dia aplica
    -- a deriva duas vezes. Ver "pendências conhecidas" no rodapé.
    update peso_atual pa
       set peso = pa.peso * (1 + coalesce(o.valor, 0)) / (1 + ret)
      from (select ativo, valor from oscilacao where data = d) o
     where pa.carteira_id = c.id and pa.ativo = o.ativo and (1 + ret) <> 0;

    perform recalcular_exposicao_atual(c.id);
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.gravar_universo(dados jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;


-- ─── 8. porta do robô ──────────────────────────────────────────────
-- O robô entra com a service key, que não tem auth.uid(). Estas três
-- fingem ser o primeiro admin e chamam as de cima.
-- ⚠️ CONFERIR PRIVILÉGIO: função nova em public nasce com EXECUTE
-- liberado para anon e authenticated. Como estas se autopromovem a
-- admin e a chave publishable está dentro do index.html, isso seria
-- um buraco aberto. Ver rodapé.

CREATE OR REPLACE FUNCTION public.robo_gravar_oscilacao(dados jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  perform gravar_oscilacao(dados);
end $function$;

CREATE OR REPLACE FUNCTION public.robo_fechar_dia()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  return fechar_dia();
end $function$;

CREATE OR REPLACE FUNCTION public.robo_gravar_universo(dados jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from perfil where admin order by criado_em limit 1))::text, true);
  perform gravar_universo(dados);
end $function$;


-- ─── 9. carteira, apelido, seguir ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.apagar_carteira(cid bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from carteira where id = cid and usuario_id = auth.uid()) then
    raise exception 'essa carteira não é sua';
  end if;
  update carteira set ativa = false,
                      nome = nome || ' (apagada ' || current_date || ')'
   where id = cid;
  delete from peso_atual where carteira_id = cid;
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.renomear_carteira(cid bigint, novo_nome text, nova_desc text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.trocar_apelido(novo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  if not apelido_livre(novo) then
    raise exception 'apelido inválido ou já em uso';
  end if;
  update perfil set apelido = btrim(novo) where id = auth.uid();
exception when unique_violation then
  raise exception 'apelido já em uso';
end $function$;

CREATE OR REPLACE FUNCTION public.seguir(cid bigint, valor boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

-- ⚠️ SEU-DOMINIO ainda está aqui. Trocar quando o site for publicado.
-- O e-mail é sino, não entrega: avisa que mudou e dá o link, nunca
-- leva peso no corpo.

CREATE OR REPLACE FUNCTION public.avisar_seguidores(cid bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
end $function$;


-- ─── 10. lead e assinatura ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.salvar_lead(dados jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.definir_assinante(quem uuid, valor boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin() then
    raise exception 'só admin pode mexer em assinatura';
  end if;
  update perfil set assinante = valor where id = quem;
  return valor;
end $function$;


-- ─── 11. admin ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_contas()
 RETURNS TABLE(id uuid, apelido text, email text, identidade text, assinante boolean, admin boolean, bloqueado boolean, criado_em timestamp with time zone, n_carteiras bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_bloquear(quem uuid, valor boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin()  then raise exception 'sem permissão'; end if;
  if quem = auth.uid() then raise exception 'não dá para bloquear a própria conta'; end if;
  update perfil set bloqueado = valor where id = quem;
  if not found then raise exception 'conta não encontrada'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_trocar_apelido(quem uuid, novo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  if btrim(novo) !~ '^[A-Za-z0-9._-]{3,24}$' then
    raise exception 'apelido inválido: 3 a 24 caracteres';
  end if;
  update perfil set apelido = btrim(novo) where id = quem;
  if not found then raise exception 'conta não encontrada'; end if;
exception when unique_violation then
  raise exception 'apelido já em uso';
end $function$;

CREATE OR REPLACE FUNCTION public.admin_apagar_carteira(cid bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  update carteira set ativa = false where id = cid;
  if not found then raise exception 'carteira não encontrada'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_renomear_carteira(cid bigint, novo_nome text, nova_desc text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  if btrim(coalesce(novo_nome,'')) = '' then raise exception 'nome vazio'; end if;
  update carteira
     set nome = btrim(novo_nome), descricao = coalesce(nova_desc,'')
   where id = cid;
  if not found then raise exception 'carteira não encontrada'; end if;
exception when unique_violation then
  raise exception 'essa pessoa já tem carteira com esse nome';
end $function$;

CREATE OR REPLACE FUNCTION public.admin_leads(busca text DEFAULT NULL::text)
 RETURNS SETOF lead
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_editar_lead(lid bigint, dados jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_apagar_lead(lid bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not sou_admin() then raise exception 'sem permissão'; end if;
  delete from lead where id = lid;
  if not found then raise exception 'lead não encontrado'; end if;
end $function$;


-- ═══════════════════════════════════════════════════════════════════
-- O QUE FALTA PARA O DUMP FICAR COMPLETO
--
-- Rodar cada uma no SQL Editor, exportar CSV e guardar junto:
--
--   -- tabelas e colunas
--   select table_name, ordinal_position, column_name, data_type,
--          is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'public' order by 1, 2;
--
--   -- chaves, unicidade, checks
--   select conrelid::regclass as tabela, conname, pg_get_constraintdef(oid)
--   from pg_constraint
--   where connamespace = 'public'::regnamespace order by 1;
--
--   -- índices
--   select tablename, indexname, indexdef from pg_indexes
--   where schemaname = 'public' order by 1;
--
--   -- políticas RLS  (o lacre mora aqui: pos_le)
--   select tablename, policyname, cmd, qual, with_check
--   from pg_policies where schemaname = 'public' order by 1;
--
--   -- gatilhos (o objeto, não a função)
--   select event_object_table, trigger_name, action_timing,
--          event_manipulation, action_statement
--   from information_schema.triggers order by 1;
--
--   -- views (ranking)
--   select table_name, view_definition from information_schema.views
--   where table_schema = 'public';
--
--   -- quem pode executar o quê
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'execute')          as anon,
--          has_function_privilege('authenticated', p.oid, 'execute') as logado
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' order by 1;
--
--
-- PENDÊNCIAS CONHECIDAS (29/07/2026)
--
-- 1. gravar_oscilacao arquiva por CURRENT_DATE, não pelo pregão.
--    A coluna data_cot guarda a data real da cotação, mas quem manda
--    é `data`, que vem de CURRENT_DATE. No fechamento das 19h dá no
--    mesmo. No modo `recuperar` do robô, que roda de manhã para salvar
--    o pregão de ONTEM, o dado de ontem é arquivado como o de hoje —
--    o dia perdido continua perdido e o robô tenta de novo toda manhã.
--
-- 2. fechar_dia não é idempotente. retorno_dia tem upsert e dá a
--    impressão de que é, mas a deriva de peso_atual é aplicada de novo
--    a cada chamada. Rodar duas vezes para o mesmo dia deforma os
--    pesos. Junto com o item 1, o `recuperar` às 8h, 9h e 10h aplicaria
--    a deriva três vezes.
--
-- 3. Não existe recusa de pregão já fechado em lugar nenhum — nem no
--    robô (só no modo `recuperar`), nem em gravar_oscilacao. A brapi já
--    devolveu o pregão de anteontem uma vez.
--
-- 4. Privilégio das robo_* não conferido — ver consulta acima.
--
-- 5. avisar_seguidores não aparece sendo chamada por nenhuma função
--    daqui. Se nenhum gatilho a chamar, o sino nunca toca. Conferir na
--    lista de gatilhos.
-- ═══════════════════════════════════════════════════════════════════
