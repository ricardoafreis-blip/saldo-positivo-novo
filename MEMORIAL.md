[MEMORIAL.md](https://github.com/user-attachments/files/30511005/MEMORIAL.md)

# Saldo Positivo — onde parou

Abra num chat novo, anexe este arquivo e cole o parágrafo do fim.

---

## O que é

Site onde cada pessoa publica carteiras de estudo de ações da B3. Desempenho e
risco são públicos; os papéis e os pesos são de quem assina. Publicar é grátis.

**No ar:** ainda não, mas o repositório existe e o robô roda.
**Banco:** Supabase, projeto "Saldo Positivo", plano grátis, região ca-central-1.
**Repositório:** `ricardoafreis-blip/saldo-positivo-novo` (público).
**Fonte de cotação:** Yahoo Finance na prática, brapi.dev no desenho — veja
"Quem está entregando o dado hoje". O Fundamentus **morreu**.

---

## Arquivos

| Arquivo | O que é |
|---|---|
| `MEMORIAL.md` | este arquivo — **commitar no repo**, ele é o mecanismo de recuperação |
| `index.html` | o site inteiro — um arquivo, já com a chave publishable dentro |
| `robo/robo.mjs` | o robô diário, roda no GitHub Actions |
| `.github/workflows/*.yml` | agenda do robô |
| `banco.sql` … `banco7.sql` | **PERDIDOS.** Já rodados, o efeito está vivo no banco. Recuperáveis — veja "Como recuperar o SQL perdido" |
| `carteira.py` | motor de referência em Python (o site usa a versão em SQL) |

---

## Como recuperar o SQL perdido

Os `banco*.sql` sumiram, mas o código que eles criaram está de pé dentro do
Postgres e ele devolve o fonte. **Nenhum item deste memorial está bloqueado por
falta desses arquivos.** No SQL Editor do Supabase:

```sql
-- todas as funções, corpo inteiro
select p.proname, pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;

-- uma função específica
select pg_get_functiondef(oid) from pg_proc where proname = 'declarar';

-- uma view
select pg_get_viewdef('ranking'::regclass, true);

-- colunas de todas as tabelas
select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns where table_schema = 'public' order by 1, 2;

-- políticas RLS
select tablename, policyname, cmd, qual, with_check
from pg_policies where schemaname = 'public';

-- gatilhos
select event_object_table, trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers where trigger_schema = 'public';
```

**Salvar a saída como `sql/schema.sql` e commitar.** O painel do Supabase mostra
*No migrations* e *No backups*, e o plano é o gratuito: hoje o SQL existe num
lugar só, que é o banco vivo.

---

## Decisões que não se discutem mais

**Oscilação, nunca preço.** O retorno de cada ativo vem da variação diária da
fonte. Split e grupamento já vêm resolvidos.

**Caixa = 100 − líquida.** Venda a descoberto entra dinheiro: 130 comprado e
40 vendido dá caixa de +10%, não −30%. Caixa positivo rende CDI até 100%.
Caixa negativo é margem e custa CDI sempre.

**Peso anda sozinho.** Depois de declarado, `peso × (1+osc) / (1+retorno)` todo
dia. Só volta ao declarado quando o dono declara de novo.

**Estratégia e alavancagem são derivadas dos pesos**, nunca declaradas.
O `tags()` no `index.html` faz isso.

**Teto de 200%** na soma de compras e vendas.

**Sem histórico retroativo.** A carteira começa a contar no dia da publicação.

**O lacre é do banco, não da tela.** A regra `pos_le` só devolve posição para o
dono ou para assinante.

**O e-mail de aviso é sino, não entrega.** Ele diz que mudou e dá o link. Nunca
leva peso no corpo — posição lacrada não pode ficar em caixa de entrada, nem de
quem cancelou depois.

**Etiqueta que o site exibe é etiqueta que o site atesta.** Por isso nada de
credencial não verificada em destaque.

---

## O Fundamentus morreu como fonte

Evidência dos dois lados:

- Pelo navegador: os quatro intermediários de CORS falharam juntos
  ("nenhum intermediário funcionou"). O `thingproxy` está morto; os outros
  saem de datacenter.
- Pelo GitHub Actions: primeiro devolveu página que não era a do Fundamentus
  (nem a palavra "Dia" aparecia), depois passou a aceitar a conexão e não
  responder, e por fim `fetch failed` nos 7 papéis, ~11s cada.

Diagnóstico: ele recusa conexão de IP de datacenter. Nenhum cabeçalho resolve.
**Não tente voltar a raspar o Fundamentus.** Já foi tentado com User-Agent de
navegador, Referer, Accept-Language e redirect follow.

Efeito colateral bom: sumiu a corrente de quatro intermediários gratuitos, que
era a peça mais frágil do projeto.

⚠️ **O painel admin do `index.html` ainda tem a versão antiga**, que raspa o
Fundamentus pelo navegador (`rodarDia()`, `atualizarUniverso()`). Está morta.
Ou apagar, ou apontar para as mesmas RPCs que o robô usa.

---

## Como o dado entra

O robô tenta a **brapi** em lotes de 20 papéis; o que não vier — um papel ou a
API inteira — cai no **Yahoo**, um papel por chamada. Um caminho só cobre os
dois casos, então a resiliência não depende de qual vem primeiro.

**brapi.dev**, plano grátis, 15.000 requisições/mês. Token em `BRAPI_TOKEN`.

- Fechamento: `GET /api/quote/{até 20 tickers}` → `regularMarketChangePercent`
  e `regularMarketTime`.
- Universo: `GET /api/quote/list?type=stock&limit=500&page=N`, filtrando
  `subType === "stock"`, ticker `AAAA9`, e `close × volume >= 200000`.

**Yahoo Finance**, sem token:
`query1.finance.yahoo.com/v8/finance/chart/PETR4.SA?range=5d&interval=1d`.
**Exige User-Agent de navegador**: com o padrão do Node ele recusa. Não devolve
variação pronta; sai de `meta.regularMarketPrice / meta.previousClose − 1`.
Data de `meta.regularMarketTime`, unix em segundos.

Nos dois casos a data do pregão é convertida para America/Sao_Paulo.

`BRAPI_TOKEN` é opcional — sem ele o robô pula a brapi e vai direto de Yahoo.

### Quem está entregando o dado hoje

O robô fecha o dia **verde no GitHub Actions puxando do Yahoo**. Isso significa
que a brapi entregou zero: ou o `BRAPI_TOKEN` saiu dos secrets, ou o token está
lá e a API não responde.

**A conferir no log da rodada verde:** se aparecer `brapi entregou 0 de N`, o
token existe e a brapi está fora; se a linha não aparecer, o token sumiu e o
robô nem tentou. O log imprime `brapi entregou X de Y` toda rodada — é por ali
que se acompanha degradação ao longo das semanas em vez de descobrir no dia da
queda.

**Se a brapi seguir entregando zero, inverter a ordem é só oficializar o que já
acontece.** Custo hoje: N/20 requisições que falham antes de o Yahoo assumir.
Contra: o Yahoo às vezes devolve 429 para IP de datacenter, que é exatamente o
que o Actions é — manter a brapi na frente é o seguro contra isso.

---

## Estado do GitHub

Repositório `saldo-positivo-novo`, público, 13 commits. Três pastas/arquivos:
`.github/workflows`, `robo`, `index.html`.

Secrets configurados: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `BRAPI_TOKEN`
(**confirmar se ainda está lá** — veja acima).

Workflows: `fechar-dia.yml` (19h BRT = 22h UTC, dias úteis) e `recuperar.yml`
(8h, 9h, 10h BRT, dias úteis). O `atualizar-universo.yml` foi escrito mas
**ainda não foi criado no repositório**.

O robô roda verde. As quatro falhas antigas foram todas da versão Fundamentus.

---

## Como o robô entra no banco

As funções `robo_gravar_oscilacao`, `robo_fechar_dia` e `robo_gravar_universo`
são casquinhas `security definer` que fazem
`set_config('request.jwt.claims', ...)` com o id do primeiro perfil admin e
chamam as originais `gravar_oscilacao`, `fechar_dia`, `gravar_universo`. O robô
entra por elas com a service key; o front chama as antigas direto.

⚠️ **Conferir privilégio.** Função nova em `public` nasce com EXECUTE liberado
para `anon` e `authenticated`. Como as `robo_*` se autopromovem a admin e a
chave publishable está dentro do `index.html`, isso seria um buraco aberto:

```sql
select p.proname,
       has_function_privilege('anon', p.oid, 'execute')         as anon_pode,
       has_function_privilege('authenticated', p.oid, 'execute') as logado_pode
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'robo\_%';
```

Se vier `true`, o conserto não afeta a `service_role`:

```sql
revoke execute on function
  robo_gravar_oscilacao(jsonb), robo_fechar_dia(), robo_gravar_universo(jsonb)
from anon, authenticated;
```

---

## Armadilhas já pagas — não repita

**`carteira.id` é `bigint`, não `uuid`.** `perfil.id` é `uuid` (vem do
`auth.users`). Errar isso quebra chave estrangeira e assinatura de função.
Já custou um `banco6` inteiro rolando para trás.

**RLS do Postgres não restringe coluna, só linha.** Sem o gatilho
`trava_privilegio`, qualquer pessoa se marcaria `assinante = true` pelo console
e o lacre abriria de graça. O gatilho veio no `banco5.sql`.

**`sou_admin()` precisa ser SECURITY DEFINER.** Ela lê `perfil`, que tem RLS.
Sem DEFINER, qualquer policy que a chame entra em recursão infinita.

**E-mail repetido não dá erro no Supabase.** Ele devolve usuário falso com
`identities` vazio, de propósito, contra enumeração. O `index.html` já trata.

**O editor do GitHub não apaga com Ctrl+A confiável.** Colar por cima duplica o
arquivo. Para trocar arquivo: Delete file, depois Create new file.

**Arquivo que mora só na pasta de Downloads é arquivo perdido.** Foi assim com
os `banco*.sql`. Um `robo__6_.mjs` na mão não prova o que está no repo — o nome
com sufixo é sinal de cópia velha. Conferir sempre pelo GitHub.

---

## O que funciona hoje

Cadastro com nome e telefone · apelido único conferido antes de criar ·
login · recuperação de senha · publicar quantas carteiras quiser · grade de
posições com escolha de ativo, peso e compra/venda, com resumo vivo de
bruta/líquida/caixa · editar · histórico dia a dia · histórico de declarações ·
ranking ordenável · lacre · duelo · comparador · indicação · seguir carteira
com aviso na fila · contador de seguidores · admin com apagar/renomear
carteira, trocar apelido, bloquear conta e ver a fila de e-mail · apagar a
própria carteira em um clique · robô fechando o dia sozinho no Actions.

---

## URGENTE: declaração retroativa

Hoje `declarar()` grava `valida_de = hoje`. Quem declara depois do fechamento
entra no cálculo do dia que já viu acontecer. É acertar sabendo o resultado, e
invalida o ranking inteiro. Uma pessoa esperta descobre isso na primeira semana.

Horário de corte (16h, 17h) **não resolve** — só encolhe: quem declara às 15h já
viu cinco horas de pregão, e ainda cria caso de borda às 16h59.

**Regra correta: declaração vale a partir do próximo pregão, sempre.** Sem
relógio, sem borda. Quem declarou de manhã e quem declarou à noite entram
juntos amanhã — o mesmo "todo mundo parte junto" que já valia para publicação.

Trocar `valida_de` em `declarar()` de hoje para o próximo dia útil.
**Não depende de arquivo perdido:**
`select pg_get_functiondef(oid) from pg_proc where proname = 'declarar';`

Consequência boa: com isso, atualizar cotação de hora em hora vira enfeite de
tela, sem risco de contaminar o apurado.

---

## A CONFIRMAR: fonte devolvendo dado velho

A brapi já entregou o pregão de anteontem em vez do de ontem. O risco é real e
está registrado.

**A proteção pode não existir.** No `robo.mjs`, a checagem contra `retorno_dia`
está só dentro de `recuperar()`. No modo `dia` — o das 19h, o que fecha de
verdade — o código junta as datas distintas, **imprime** (`pregão: ...`) e grava
assim mesmo. Nenhuma recusa, nenhum grito.

Ou a recusa está dentro da `gravar_oscilacao` no SQL, ou não existe em lugar
nenhum. Conferir antes de confiar:
`select pg_get_functiondef(oid) from pg_proc where proname = 'gravar_oscilacao';`

Se não estiver lá, o conserto é no `robo.mjs`: comparar `data_cot` com o último
`retorno_dia` e abortar se já estiver fechado, e abortar se o lote trouxer mais
de uma data.

---

## O que falta

1. ~~Testar o robô.~~ Feito: roda verde no Actions pelo Yahoo.
2. ~~Fonte reserva.~~ Feita: Yahoo tapando buraco da brapi, escrita e em
   produção.
3. **Commitar `MEMORIAL.md` e `sql/schema.sql` no repo.** Enquanto isso não for
   feito, a recuperação do projeto depende da pasta de Downloads.
4. **Publicar.** Settings → Pages → branch `main`, pasta root.
5. **URLs no Supabase.** Authentication → URL Configuration: pôr o endereço
   real em *Site URL* e em *Redirect URLs*. Sem isso, recuperar senha por
   e-mail não volta para lugar nenhum. Aberto desde o começo do projeto.
6. **Trocar `SEU-DOMINIO`** dentro de `avisar_seguidores()` — rodar o bloco
   daquela função com o endereço real. (Vinha do `banco7.sql`; recuperável pelo
   `pg_get_functiondef`.)
7. **`and not p.bloqueado`** na view `ranking`. Destravado:
   `select pg_get_viewdef('ranking'::regclass, true);`
8. **Conferir privilégio das `robo_*`** — veja "Como o robô entra no banco".
9. **Criar `atualizar-universo.yml`** no repositório.
10. **Limpar o admin do `index.html`**, que ainda raspa Fundamentus.
11. **Envio de e-mail.** Falta conta na Resend e os secrets `RESEND_API_KEY` e
    `EMAIL_DE`. Sem eles a fila enche e não esvazia — nada quebra.
12. **Pagamento.** `/assinar` é só a tela. Kiwify ou Asaas; o webhook só precisa
    fazer `assinante = true` e gravar o lead com `origem = 'assinatura'`.
13. **ETFs.** A brapi cobre. Falta decidir a lista (regex não serve: `AAAA11`
    pega ETF, FII, unit e BDR juntos) e ampliar o filtro do universo.
14. **Termômetro de palpites.** Desenhado, nunca construído. Todo palpite tem
    prazo e é apurado; duas agulhas (multidão e quem vem acertando, peso
    `[n/(n+20)] × máx(0, acerto−0,45)`); consenso escondido até votar; alvo é
    mediana com faixa interquartil à mostra.

---

## Decisões em aberto, esperando o dono

**Variação em tempo real.** Atualizar a cotação de meia em meia hora ou de hora
em hora durante o pregão, e parar em algum momento. Com a regra do próximo
pregão em vigor, isso é puro enfeite de tela e não contamina o apurado — vira
decisão de produto. Antes dela, não. Pontos por decidir: frequência, hora de
encerrar, e se o número ao vivo aparece no ranking ou só na carteira.
Custo: cada rodada intradiária é mais uma passada na cota da fonte.

**A variação é ajustada por provento?** Se for variação crua de fechamento,
carteira de dividendo afunda no dia "ex" sem ter perdido nada. Vale tanto para
o `regularMarketChangePercent` da brapi quanto para o cálculo por
`previousClose` do Yahoo. Teste barato que ninguém fez: no dia em que um papel
ficar "ex", comparar a variação marcada com o dividendo pago. Se não for
ajustada, ou se aceita o viés contra carteira de dividendo, ou se soma o
provento por fora — e aí falta fonte de proventos.

**As etiquetas de identidade.** `identidade`, `credencial` e `anos_mercado` são
autodeclarados e contradizem a regra de que atributo se deriva, nunca se
declara. Argumento levantado e não fechado: etiqueta profissional espanta
justamente quem tem mais a perder com um mês ruim, enviesando quem aparece no
ranking. Proposta em pé: apagar as três da tela, derivar ritmo de declaração,
concentração e tempo de estrada, e criar ranking por vários eixos em vez de
classificar gente. Os campos continuam no banco.

**Quando pedir CPF e endereço.** Hoje o cadastro pede só nome e telefone, e a
ficha completa fica para o `/assinar` — Kiwify e Asaas já coletam no checkout e
devolvem por webhook. A tabela `lead` aceita os dois caminhos pelo campo
`origem`.

---

## Parágrafo para colar no chat novo

> Estou construindo o Saldo Positivo, site onde cada pessoa publica carteiras de
> estudo de ações da B3 — desempenho público, papéis e pesos só para assinantes,
> publicar é grátis. Banco no Supabase, site num HTML único, robô diário em
> GitHub Actions que já roda verde puxando do Yahoo. O MEMORIAL.md anexado tem
> todas as decisões tomadas, as armadilhas já pagas e o que falta — leia antes
> de responder. Os `banco*.sql` se perderam, mas **não peça por eles**: o SQL
> está vivo no banco e o memorial traz as consultas que o devolvem. Nesta
> conversa quero trabalhar em [X].
