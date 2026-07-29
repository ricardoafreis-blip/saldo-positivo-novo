# Saldo Positivo — onde parou

Abra um chat novo, anexe este arquivo e cole o parágrafo do fim.
Última revisão: **29/07/2026, fim do dia.**

---

## O que é

Site onde cada pessoa publica carteiras de estudo de ações da B3. Desempenho e
risco são públicos; os papéis e os pesos são de quem assina. Publicar é grátis.

**O site tem duas metades**, e a separação é deliberada:

| Metade | Quem | O que mede | Placar |
|---|---|---|---|
| **Investidores** | quem publica carteira | retorno apurado de fechamento a fechamento, por classe | ranking de carteiras |
| **Especuladores** | quem aposta em papel do dia | acerto de direção em um pregão, com stop e alvo | ranking de pontos |

**A ponte entre os dois placares não existe, e é para continuar assim.** O valor
do site está em o número apurado ser confiável. Misturar placar de jogo com
placar de carteira contamina os dois.

---

## Estado em 29/07/2026

**No ar:** `https://ricardoafreis-blip.github.io/saldo-positivo-novo/`
**Domínio:** `saldopositivo.com.br` ainda serve o **Duelo B3**, em Cloudflare
Workers (`duelo-b3` e `duelo-b3-proxy`). DNS na Cloudflare. O site novo ainda
não aponta para lá.
**Banco:** Supabase, projeto "Saldo Positivo", plano grátis, ca-central-1.
**Sem migrations e sem backups** — o SQL só existe no banco vivo e em `sql/`.
**Repositório:** `ricardoafreis-blip/saldo-positivo-novo` (público).

### Arquivos

| Onde | O que é |
|---|---|
| `MEMORIAL.md` | este arquivo |
| `index.html` | o site inteiro, um arquivo, com a chave publishable dentro |
| `robo/robo.mjs` | robô diário: busca cotação e fecha o dia |
| `robo/historico.mjs` | **laboratório**: carrega meses de pregão real do Yahoo |
| `.github/workflows/` | `fechar-dia.yml` (19h BRT), `recuperar.yml` (**desligado**), `historico.yml` (manual) |
| `sql/funcoes.sql` | dump das funções às 11h de 29/07 — **já desatualizado** |
| `sql/banco8..17.sql` | as migrações do dia, na ordem |
| `sql/simular.sql` | gerador de dado falso — distorce renda fixa e índice, ver abaixo |

Os `banco.sql` a `banco7.sql` originais **se perderam**. Não peça por eles: o SQL
está vivo no Postgres e as consultas para extraí-lo estão na seção
"Como recuperar o SQL".

---

## ⚠️ O banco está com DADO DE LABORATÓRIO

`retorno_dia`, `oscilacao`, `barra` e `peso_atual` têm **64 pregões reais de
29/04 a 29/07/2026**, carregados retroativamente pelo `historico.mjs`. As
carteiras não existiam nessas datas. Isso viola de propósito a regra "sem
histórico retroativo" e serviu para provar o motor.

**Apagar antes de entrar gente:**

```sql
delete from retorno_dia;
delete from oscilacao;
delete from barra;
delete from peso_atual;
update posicao set valida_de = proximo_pregao();
```

O `simular.sql` gera dado aleatório e é pior que isso: ele trata todo papel
igual, então distorce justamente renda fixa e índice (deu Sharpe 13,69 e ETF de
Selic oscilando 2% ao dia). O `historico.mjs` com dado real substituiu ele.

---

## Decisões que não se discutem mais

**Oscilação, nunca preço** (no motor de carteira). Split e grupamento já vêm
resolvidos pela fonte. Preço só existe no jogo de especulação, em `barra`.

**Caixa = 100 − líquida.** Venda a descoberto entra dinheiro: 130 comprado e 40
vendido dá caixa de +10%, não −30%. Caixa positivo rende CDI até 100%; negativo
é margem e custa CDI. Confirmado funcionando: a alavancada com caixa −59% paga
o arrasto.

**Peso anda sozinho.** `peso × (1+osc) / (1+retorno)` todo dia. Só volta ao
declarado quando o dono declara de novo. É por isso que `peso_atual` não pode
ser recalculado de `posicao` — perderia a deriva. Daí a coluna `marco`.

**Declaração vale a partir do próximo pregão, sempre.** Sem relógio, sem corte,
sem caso de borda. Era o furo mais grave do projeto: quem declarava às 17h30 já
sabendo o resultado do dia entrava no cálculo dele. Consertado no `banco8`
(`declarar()`), no `banco9` (adoção no fechamento) e no `banco11` (default da
coluna, que fechava a estreia de carteira nova).

**Teto de 200%** na soma de compras e vendas.

**Sem histórico retroativo.** A carteira começa a contar no pregão seguinte à
publicação.

**O lacre é do banco, não da tela.** A regra `pos_le` só devolve posição para o
dono ou para assinante. Vale igual para aposta de especulação (`aposta_le`).

**O e-mail de aviso é sino, não entrega.** Diz que mudou e dá o link, nunca leva
peso no corpo.

**Atributo se deriva, nunca se declara** — com **uma exceção justificada: a
classe da carteira.** "Sou long only" quer dizer "eu me proíbo de vender", e isso
é compromisso, não característica. Se fosse deduzido dos pesos de hoje, a
carteira migraria de ranking conforme o resultado — a declaração retroativa com
outra roupa. Por isso: escolhida no nascimento, imutável, e o banco recusa
declaração que a viole.

**Identidade autodeclarada saiu da tela** (29/07). `identidade`, `credencial` e
`anos_mercado` continuam no banco mas não aparecem em lugar nenhum: o site não
tem como atestar, e etiqueta profissional espanta quem tem mais a perder com um
mês ruim.

---

## As quatro classes de carteira

Escolhidas na criação, imutáveis, validadas pelo banco (`valida_classe`).

| Classe | O que o banco impõe |
|---|---|
| `all_in` | só compra · bruta de 100% a 200% — sem caixa, pode alavancar |
| `diversificada` | só compra · bruta abaixo de 100% · 5 a 15 papéis |
| `long_short` | ao menos uma compra e uma venda · bruta até 200% · é aqui que entra o hedge |
| `vendida` | só venda · bruta até 200% |

As quatro não se sobrepõem: o divisor entre `all_in` e `diversificada` é o
caixa. All in é estar todo dentro.

**Vão conhecido:** comprada com caixa e menos de 5 ou mais de 15 papéis não tem
classe. Quem quiser 3 papéis a 30% cada precisa ir a 100% ou abrir para 5 nomes.
Se isso aparecer com frequência, a saída é baixar o mínimo da diversificada de 5
para 2. Hoje uma carteira está sem classe: "Minha carteira 2", 4 papéis, bruta 99.

**Neutra saiu** — long & short já cobre o hedge. **Ampla saiu.** Day trade **não
é classe de carteira**: virou a metade de especulação.

---

## O jogo de especulação

**Como funciona.** O jogador escolhe **papel e direção** para o próximo pregão,
até 10 papéis por dia, sem obrigação de jogar todo dia. Entrada na abertura.
Stop e alvo o sistema propõe. Saída por stop, por alvo ou pelo fechamento.

**Por que a entrada é na abertura e não às 10h30:** o candle diário não tem o
preço das 10h30. Apurar por um preço que não se conhece seria chute.

**Stop e alvo em múltiplos da amplitude média do papel**, não em porcentagem
fixa. Sem isso, 2% em MGLU3 é dia comum e em VALE3 é dia grande — o volátil bate
alvo por ruído e o parado não bate nem quando o jogador acerta. Padrão: 0,6 de
amplitude para cada lado, **equidistante**.

**Três convenções da apuração**, e elas precisam ser públicas:

1. **Stop e alvo tocados no mesmo dia → AMBÍGUO, sai no fechamento.** O candle
   não diz o que veio primeiro, então usa o único preço que se conhece.
2. **Gap além do limite → preenche na abertura.** Stop não é promessa de preço.
3. **Entrada sempre na abertura.**

**Pontuação:**

| Desfecho | Pontos |
|---|---|
| `alvo`, `gap_favor` | +2 |
| `fechamento` positivo, `ambiguo` positivo | +1 |
| zero a zero | 0 |
| `fechamento` negativo, `ambiguo` negativo | −1 |
| `stop`, `gap_contra` | −2 |

**A unidade do placar é o DIA, não a operação.** Nota do dia = média dos pontos
dos papéis daquele dia, sempre entre −2 e +2, para quem entrou com 1 ou com 10.
Motivo: soma de pontos rankearia quem joga mais; média por operação trataria 10
apostas correlacionadas (cinco bancos) como 10 evidências independentes.
Diversificar reduz a variância do dia — o que é bom — mas não infla a amostra.

**Nota final = média das notas diárias × dias/(dias+20).** O encolhimento é a
mesma ideia do termômetro de palpites: três dias bons não passam na frente de um
ano de consistência.

**Lacre da aposta:** aposta de outra pessoa só aparece quando o prazo fecha, na
abertura do pregão (`banco17`). Durante o dia todos veem o campo montado e nada
pode mudar. Sem isso, quem entra por último copia quem entrou primeiro.

**Não há arbitragem em apostar nos dois lados do mesmo papel** — conferido:
+2 e −2, ou +1 e −1. Sempre zero.

---

## Os três vieses encontrados e corrigidos no jogo

Todos achados do mesmo jeito: olhando um número que não fechava.

**1. Imposto sobre volatilidade.** A convenção "empate conta stop" parecia
conservadora e era um imposto. Medido em 64 pregões:

| Papel | Dias de empate | Média por operação |
|---|---|---|
| MGLU3 | 25 de 64 | −0,564% |
| CVCB3 | 23 | −0,570% |
| VALE3 | 0 | −0,103% |
| LFTS11 | 0 | +0,026% (único positivo) |

O ranking de "melhor papel para operar" saía ordenado por volatilidade
invertida: a estratégia vencedora era escolher o papel que menos anda.
Corrigido no `banco14` — de 292 punições indevidas para 18 casos honestos, e a
média do `ambiguo` passou a **+1,096%**, o que mede o tamanho do imposto.

**2. Alvo em porcentagem fixa.** Corrigido com múltiplos da amplitude
(`faixa_papel`, `banco14`).

**3. Assimetria da pontuação.** Com stop a meia amplitude e alvo a três quartos,
o stop é atingido quase o dobro das vezes (500 contra 254). Pontos simétricos de
±2 com frequência de 2 para 1 dão expectativa negativa para **todos**. Daí o
padrão equidistante 0,6/0,6 no `banco15`. **O teste C do `banco15` ainda não foi
rodado** — é ele que confirma.

---

## O que foi medido, e prova que o motor está certo

**Neutralidade da apuração** (64 pregões, 19 papéis, 2.432 operações):

| Lado | Média por operação |
|---|---|
| comprado | −0,114% |
| vendido | +0,139% |
| **soma** | **+0,025% ≈ zero** |

A apuração não favorece direção nenhuma. A expectativa negativa do comprado é
mercado, não regra: **todos os 19 papéis fecharam o trimestre no negativo** —
MGLU3 −44,2%, CVCB3 −34,7%, RENT3 −20,6%, BOVA11 −7,3%, ITUB4 −4,6%.

**Volatilidade das classes** (mesmos 64 pregões, anualizada):

| Carteira | Vol | Leitura |
|---|---|---|
| Ações e Selic (40% LFTS11) | 8,55% | piso, como esperado |
| Hedge de índice | 9,48% | 36% menos que a comprada — o hedge funciona |
| Diversificada (12 papéis) | 14,12% | menos que a concentrada |
| Concentrada (4 papéis) | 14,81% | |
| Alavancada 1,5x | 23,15% | maior retorno, Sharpe pior, queda máxima maior |

**Determinismo:** "Minha carteira" e "[teste] Concentrada" têm os mesmos quatro
papéis e deram retorno e volatilidade idênticos (−1,44% e 14,81%) por caminhos
independentes.

---

## De onde vem a cotação

O robô tenta em cascata; cada fonte cobre o que a anterior não entregou. O log
diz quem entregou quanto — é assim que se percebe uma fonte degradando ao longo
das semanas em vez de descobrir no dia da queda.

**1. brapi.dev** — lotes de 20 papéis. **COTA ZERADA: 15.000 de 15.000,
renova 16/08/2026.** Última chamada que passou foi 21/07. Todos os fechamentos
verdes até hoje foram Yahoo puro.
Causa medida: o **duelo** chama a brapi do navegador de cada visitante, **um
papel por requisição**. Pico de ~9.000 requisições num domingo (19/07),
provavelmente laço de retentativa em dia sem pregão.
PETR4, MGLU3, VALE3 e ITUB4 respondem **sem token** — não confunda isso com "a
brapi voltou".

**2. bolsai** (`usebolsai.com`) — adaptador escrito no `robo.mjs` e **NÃO
VERIFICADO**. Três linhas marcadas para conferir na documentação: caminho do
endpoint, forma de enviar o token, nome do campo de variação. Sem
`BOLSAI_TOKEN`, é pulada em silêncio.

**3. Yahoo Finance** — `query1.finance.yahoo.com/v8/finance/chart/PETR4.SA`, um
papel por chamada, sem token. **Exige User-Agent de navegador.** Índice não leva
`.SA` e o `^` precisa ser escapado: `simboloYahoo()` faz isso.

**Fundamentus está morto** e não volta: recusa IP de datacenter, e falhou também
pelo navegador com os quatro intermediários de CORS. Já tentado com User-Agent,
Referer, Accept-Language e redirect follow. **Não tente de novo.**

**MetaTrader 5 não serve** para o robô: o acesso é por biblioteca Python que
conversa com o terminal aberto, precisa de Windows com o programa rodando. Não
há endpoint HTTP. Serve como fonte manual, nunca como cron.

**Intradiário é inviável por ora.** Pela brapi não há cota; pelo Yahoo, um papel
por chamada de IP de datacenter, dá 429. Quando a cota voltar, o desenho é
Actions busca e grava numa tabela, o site lê do Supabase — **nunca** o navegador
do visitante chamando a fonte.

**Índice de referência: `^BVSP` (Ibovespa), só ele.** BOVA11 e SMAL11 são papéis
que uma carteira pode ter, não régua — e sendo ETF, distribuem provento, o que
contaminaria a comparação. O Ibovespa é índice de retorno total por construção.

---

## A pergunta do provento, e o detector que já está de pé

A variação diária das fontes é bruta ou ajustada por provento? Se for bruta, a
carteira de dividendo afunda no dia "ex" sem ter perdido nada — e no modelo de
peso o dinheiro **não tem para onde ir**, porque o caixa é derivado (`100 −
líquida`), não uma conta que recebe depósito.

**O que se sabe:** no Brasil a série de preços é ajustada retroativamente pela
bolsa — o caso Petrobras 2022 é explícito (fechamento de quinta passou de R$
36,25 para R$ 29,58 no dia seguinte). Então **depende de qual fechamento
anterior a fonte usa na conta**, e isso muda de fonte para fonte. O Yahoo mantém
`Close` e `Adj Close` separados, o que sugere que o principal não é ajustado — e
é do principal que sai o `previousClose` que o robô usa.

**O detector que já está funcionando sem custo:** `^BVSP` e `BOVA11` são
gravados lado a lado todo dia. Em 29/07 a diferença foi 0,32 ponto (−2,06% contra
−2,38%), que é erro de rastreamento normal. No dia em que o BOVA11 ficar "ex", se
a fonte for bruta, **essa diferença salta pelo valor do provento**. Não precisa
de teste armado: é só olhar quando o par descolar.

**Cuidado ao montar teste manual:** o preço cai na **data ex**, que é o dia
seguinte à "data com" — não na data de pagamento. Provento pequeno (0,6%) se
perde no ruído diário de 2%; serve JCP acima de 2%, e serve muito melhor
distribuição gorda.

---

## Armadilhas já pagas — não repita

**No Supabase, função nova nasce ABERTA.** O privilégio vem de `PUBLIC`, não de
`anon` — revogar de `anon` não faz nada e o `has_function_privilege` continua
`true`. Em 29/07 as 36 funções estavam liberadas, incluindo as `robo_*`, que se
autopromovem a admin. Como a chave publishable está no `index.html` de um
repositório público, qualquer um podia fechar o dia. Corrigido com
`revoke ... from public` + `grant` para quem precisa. **Todo arquivo novo tem de
terminar com esse bloco.**

**`carteira.id` é `bigint`, `perfil.id` é `uuid`.** Errar isso quebra chave
estrangeira e assinatura de função. Já custou um `banco6` inteiro.

**RLS não restringe coluna, só linha.** Sem `trava_privilegio`, qualquer um se
marcaria `assinante = true` pelo console.

**`sou_admin()` precisa ser SECURITY DEFINER**, senão policy que a chame entra em
recursão infinita. Não revogue `sou_admin`, `eh_assinante`, `pode_mexer` nem
`apelido_livre` de `anon` — o ranking para de abrir para visitante deslogado.

**E-mail repetido não dá erro no Supabase**: devolve usuário falso com
`identities` vazio, contra enumeração. O `index.html` já trata.

**`round(x, 2)` não existe para `double precision`.** Erro `42883`. Sempre
`round((x)::numeric, 2)`.

**O SQL Editor do Supabase mostra só o resultado da ÚLTIMA consulta**, e se
houver texto selecionado executa **só a seleção**. Duas horas de 29/07 se foram
achando que um arquivo tinha rodado quando não tinha. Rode uma consulta por vez.

**O editor do GitHub não apaga com Ctrl+A confiável.** Para trocar arquivo:
Delete file, depois Create new file. E se o campo do nome já tiver um caminho
(`sql/`), ele fica — foi assim que nasceu uma pasta com nome de frase inteira.

**Arquivo que mora só em Downloads é arquivo perdido.** Foi assim com os
`banco*.sql`. Nome com sufixo (`robo__6_.mjs`) é sinal de cópia velha: confira
sempre pelo GitHub.

**Papel que morre é peso fantasma.** `AZUL4` virou `AZUL532`, depois `AZUL54`, e
hoje não existe. O `fechar_dia` trata papel sem cotação como **variação zero**
via `coalesce(o.valor, 0)`, silenciosamente e para sempre. A carteira
"[teste] Só vendida" está sendo apurada com dois terços dos papéis. Caçar zumbis:

```sql
select distinct pa.ativo from peso_atual pa
 where not exists (select 1 from oscilacao o where o.ativo = pa.ativo);
```

**O robô tolera 10% de falha** — uma perna faltando em 21 papéis passa sem
barrar nada.

---

## Como recuperar o SQL

Os `banco*.sql` antigos se perderam, mas o Postgres devolve o fonte:

```sql
select p.proname, pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;

select pg_get_viewdef('ranking'::regclass, true);

select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns where table_schema = 'public' order by 1, 2;

select conrelid::regclass, conname, pg_get_constraintdef(oid)
from pg_constraint where connamespace = 'public'::regnamespace order by 1;

select tablename, policyname, cmd, qual, with_check
from pg_policies where schemaname = 'public' order by 1;

select event_object_table, trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers order by 1;

select p.proname,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as logado,
       has_function_privilege('service_role', p.oid, 'execute')  as robo
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;
```

**Exportar em CSV e commitar em `sql/`.** O `funcoes.sql` no repositório é das
11h de 29/07 e já não tem nada do `banco10` em diante.

---

## As migrações de 29/07/2026

| Arquivo | O que fez |
|---|---|
| `banco8` | `hoje_br()`, `proximo_pregao()`; `declarar()` grava `valida_de` = próximo pregão |
| `banco9` | coluna `marco` em `peso_atual`; gatilho ignora declaração futura; `fechar_dia` adota a pendente **antes** de calcular |
| `banco10` | view `papeis_do_dia`; `gravar_oscilacao` arquiva pela data real; `fechar_dia` recusa dia já fechado; `robo_fechar_dia(d)` |
| `banco11` | classes, `valida_classe`, `trava_classe`, view `carteira_classe`, **default de `valida_de`** |
| `banco12` | `declarada_em`; tabela `referencia` (`^BVSP`); `indice_referencia`; `carteira_contra_referencia` |
| `banco13` | tabela `barra` (OHLC), `robo_gravar_barra`, `apurar_operacao` |
| `banco14` | empate → `ambiguo` no fechamento; view `faixa_papel` |
| `banco15` | `pontos()`, `limites_sugeridos()`, `apurar_aposta()` |
| `banco16` | tabela `aposta`, travas, `aposta_apurada`, `dt_dia`, `ranking_dt` |
| `banco17` | lacre da aposta abre na abertura, não no fechamento |

Dois bugs graves que o dia revelou e consertou:

**`gravar_oscilacao` arquivava por `CURRENT_DATE`.** Provado no próprio banco:
`data = 2026-07-29` com `data_cot = 2026-07-28`. No modo `recuperar`, que roda de
manhã para salvar o pregão de ontem, o dado de ontem era arquivado como de hoje —
o dia perdido continuava perdido e o robô tentaria de novo toda manhã, para
sempre.

**`fechar_dia` não era idempotente.** `retorno_dia` tem upsert e dava a impressão
de que era, mas a deriva de `peso_atual` era reaplicada a cada chamada. O
`recuperar` rodou duas vezes em 29/07 e deformou os pesos.

---

## O que funciona hoje

Cadastro (sem os campos de identidade) · apelido único · login · recuperação de
senha · publicar carteira **com classe obrigatória** · grade de posições com
resumo vivo de bruta/líquida/caixa · editar · histórico dia a dia · histórico de
declarações · **ranking filtrado por classe, com desempate por carteira mais
antiga** · lacre · duelo · comparador · indicação · seguir carteira · admin com
seções recolhíveis e ordenação por recente/nome/dono/acumulado · robô fechando o
dia sozinho pelo Yahoo · comparação contra Ibovespa na janela de cada carteira ·
apuração e pontuação de aposta de um pregão.

---

## O que falta

**Com prazo**

1. **Apagar o dado de laboratório** antes de qualquer usuário real.
2. **Rodar o teste C do `banco15`** — confirma se a pontuação equidistante é
   justa. Se pender para um lado, o placar nasce torto.
3. **Consumo da brapi antes de 16/08**, quando a cota renova: cache no Worker
   (feito), **20 papéis por chamada em vez de 1** (falta, é no front do duelo), e
   um **teto diário** no Worker — o pico de domingo mostrou que a causa pode ser
   desconhecida, e só teto protege contra isso.

**Tela (o maior pedaço)**

4. **Formulário de aposta:** papel, direção, limites sugeridos, até 10 por
   pregão, lista das pendentes com botão de desistir, e a tela do placar lendo
   `ranking_dt`.
5. **Dividir a navegação nas duas metades** — Investidores e Especuladores.
6. **Carteira sem posição em vigor mostra "0 ativos · só comprada"**, rótulo
   errado por acidente aritmético (`liquida >= bruta - 0.01` com tudo zero).
   Precisa dizer "estreia no próximo pregão".
7. Aviso na declaração de que ela vale a partir do próximo pregão.

**Banco**

8. `fechar_dia` **recusar** papel sem cotação em vez de assumir zero, e um jeito
   de aposentar papel que morreu.
9. Guardar **qual fonte** entregou cada cotação (coluna `fonte` em `oscilacao`).
   Se uma fonte ajustar provento e a outra não, dois papéis do mesmo dia saem em
   réguas diferentes e nada avisa.
10. `and not p.bloqueado` na view `ranking`.
11. Religar o `recuperar.yml` — o `banco10` consertou os dois bugs que o tornavam
    perigoso. Conferir também o cron: os runs saíram às 11h, e o memorial dizia
    8h, 9h e 10h BRT.
12. Criar `atualizar-universo.yml` (escrito, nunca criado). Depende da brapi.
13. **ETFs no universo**: BOVA11 e SMAL11 só entram em carteira se estiverem em
    `universo`, e o filtro corta tudo que não é `AAAA9`. Regex não serve —
    `AAAA11` pega ETF, FII, unit e BDR juntos.

**Produto**

14. **Domínio.** Worker do duelo atende por rota: dá para dividir
    (`/duelo*` no Worker, o resto no site novo) sem tocar no jogo. Conferir se a
    rota é curinga (`saldopositivo.com.br/*`), que engoliria tudo.
15. **URLs no Supabase**: já configuradas para o endereço do Pages; acrescentar
    `https://www.saldopositivo.com.br/**` quando o domínio entrar.
16. **`SEU-DOMINIO`** dentro de `avisar_seguidores()`.
17. **`avisar_seguidores` não aparece sendo chamada por nenhum gatilho.** Se
    nenhum a chamar, o sino nunca toca. Conferir na lista de gatilhos.
18. **Envio de e-mail**: falta conta na Resend e os secrets `RESEND_API_KEY` e
    `EMAIL_DE`. Sem eles a fila enche e não esvazia — nada quebra.
19. **Pagamento**: `/assinar` é só tela. O webhook precisa fazer
    `assinante = true` e gravar o lead com `origem = 'assinatura'`.
20. **Painel admin do `index.html`** já não tem os botões do Fundamentus, mas
    `fechar_dia` e `gravar_oscilacao` continuam com grant explícito para
    `authenticated` (a checagem interna de admin as protege).

---

## Ideias desenhadas, não construídas

**Ranking de pessoa.** Derivável do que existe, sem coletar nada novo. O furo a
evitar: publicar é grátis e ilimitado, então alguém cria vinte carteiras e é
reconhecido pela melhor — sorte, não habilidade. O conserto é contar **todas** as
carteiras da pessoa, com o mesmo encolhimento `n/(n+k)`. Ponto **não pode vir de
atividade**: se declarar der ponto, declara-se sem motivo.

**Termômetro de palpites.** Todo palpite tem prazo e é apurado; duas agulhas
(multidão e quem vem acertando, peso `[n/(n+20)] × máx(0, acerto−0,45)`);
consenso escondido até votar; alvo é mediana com faixa interquartil à mostra.

**Eixo de giro.** Frequência de re-declaração separa quem mexe todo dia de quem
mexe por trimestre, sem o site afirmar o que não consegue provar. "Day trader"
como classe de carteira **não é mensurável** neste motor: quem fecha o dia zerado
tem peso zero, e o motor mede fechamento a fechamento. Foi por isso que virou a
metade de especulação.

**Concentração como filtro, não classe.** Cruzar classe com faixa de
concentração daria baldes de uma carteira cada. Vira classe quando houver gente.

---

## Decisões em aberto

**O placar do jogo aparece junto do ranking de carteiras ou separado?** Minha
opinião: separado, e é o que o desenho atual faz.

**Quando pedir CPF e endereço.** Hoje o cadastro pede nome e telefone; a ficha
completa fica para `/assinar`. Kiwify e Asaas coletam no checkout e devolvem por
webhook. A tabela `lead` aceita os dois caminhos pelo campo `origem`.

**Sharpe encolhido.** A `metricas()` agora exige 20 pregões, anualiza por média
aritmética (a versão composta transformava +9% em 21 dias em +183% ao ano e o
Sharpe ia a 13,69) e encolhe por `n/(n+40)`. Isso **não é o Sharpe de livro** — é
Sharpe para ordenar. A alternativa é o valor cheio com a coluna escondida até 60
dias.

**Estado da brapi:** existe uma segunda conta. Eu não escrevi nada que gerencie
rodízio de contas e não vou; o robô lê o `BRAPI_TOKEN` que estiver nos secrets,
seja qual for. Um token foi exposto em conversa e **precisa ser substituído** no
painel da brapi.

---

## Parágrafo para colar no chat novo

> Estou construindo o Saldo Positivo, site com duas metades: **investidores**
> publicam carteiras de estudo de ações da B3 (desempenho público, papéis e pesos
> só para assinantes, ranking por classe) e **especuladores** apostam em papel e
> direção para o próximo pregão, com stop e alvo sugeridos pela volatilidade e
> placar por pontos. Banco no Supabase, site num HTML único já publicado no
> GitHub Pages, robô diário em GitHub Actions puxando cotação do Yahoo. O
> MEMORIAL.md anexado tem todas as decisões tomadas, as armadilhas já pagas, os
> números que provaram o motor e o que falta — **leia antes de responder**. Os
> `banco*.sql` de 1 a 7 se perderam; **não peça por eles**, o SQL está vivo no
> banco e o memorial traz as consultas que o devolvem. Atenção: o banco está com
> 64 pregões de dado retroativo de laboratório que precisam ser apagados antes de
> entrar gente. Nesta conversa quero trabalhar em [X].
