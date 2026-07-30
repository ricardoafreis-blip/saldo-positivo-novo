# Saldo Positivo — onde parou

Abra um chat novo, anexe este arquivo e cole o parágrafo do fim.
Última revisão: **30/07/2026, fim da tarde.**

---

## O que é

Site com **duas metades**, e a separação é deliberada:

| Metade | Quem | O que mede | Placar |
|---|---|---|---|
| **Investidores** | publica carteira de estudo da B3 | retorno de fechamento a fechamento, por classe | ranking de carteiras |
| **Especuladores** | palpita papel e lado para o próximo pregão | acerto de direção em um pregão | ranking de pontos |

Desempenho e risco são públicos; papéis e pesos são de quem assina. Publicar é
grátis.

**Não há ponte entre os dois placares, e é para continuar assim.** O valor do
site está em o número apurado ser confiável; misturar placar de jogo com placar
de carteira contamina os dois.

---

## Estado em 30/07/2026

**No ar:** `https://ricardoafreis-blip.github.io/saldo-positivo-novo/`
**Domínio:** `saldopositivo.com.br` ainda serve o **Duelo B3** (Cloudflare
Workers). DNS na Cloudflare. O site novo ainda não aponta para lá.
**Banco:** Supabase, plano grátis, ca-central-1. **Sem migrations, sem backups.**
**Repositório:** `ricardoafreis-blip/saldo-positivo-novo` (público).

### ⚠️ Pendências de estado, resolver antes de qualquer coisa

**`peso_atual` está vazio.** Nenhuma carteira tem posição em vigor, então não há
parcial, não há curva, e o fechamento não tem o que apurar. Foi consequência da
limpeza do laboratório: as declarações voltaram para "pendente".

Para o fechamento de hoje valer (⚠️ quebra a regra do próximo pregão — só vale
enquanto não houver mais ninguém no site):

```sql
update posicao set valida_de = hoje_br();
delete from peso_atual;
insert into peso_atual (carteira_id, ativo, peso, marco)
select p.carteira_id, p.ativo, sum(p.peso), p.valida_de
  from posicao p join carteira c on c.id = p.carteira_id
 where c.ativa group by p.carteira_id, p.ativo, p.valida_de;
select recalcular_exposicao_atual(carteira_id)
  from (select distinct carteira_id from peso_atual) x;
```

Ou não fazer nada e esperar o fechamento das 19h adotar as pendentes.

**Uma carteira sem classe** ("Minha carteira 2": 4 papéis, bruta 99). Precisa ser
enquadrada ou apagada antes de rodar o passo 4 do `banco21`, que torna a classe
obrigatória.

---

## A descoberta do dia: a brapi aceita 1 ticker por chamada

Medido em 30/07 pelo próprio robô, que desceu 20 → 9 → 4 → 2 → 1 até passar.
**No plano gratuito, `/api/quote/A,B,C` com mais de um ticker devolve 400** — sem
dizer o motivo.

Isso explica de uma vez três coisas que pareciam não ter relação:

- o **duelo** pedir um papel por requisição não era descuido: era a única forma
  que funcionava — e foi assim que 15.000 requisições sumiram numa semana;
- o robô "não receber nada da brapi" nunca foi cota nem token: o lote de 20 era
  recusado inteiro, sempre;
- o `AZUL4` (papel que deixou de existir) parecia envenenar o lote, mas era o
  tamanho do lote o tempo todo.

**Consequência de desenho:** a brapi perdeu a vantagem no fechamento diário (as
duas fontes custam 20 chamadas), mas é **insubstituível no intradiário**, porque
o Yahoo devolve 429 para IP de datacenter em volume. Então a cota inteira fica
reservada para o intradiário, e o fechamento usa o Yahoo, que não acaba.

---

## De onde vem a cotação

### Fechamento diário — `robo/robo.mjs`, 19h BRT

Cascata: **Yahoo → bolsai → brapi**. Cada fonte cobre o que a anterior não
entregou. O log diz quem entregou quanto (`de N papéis: yahoo X · brapi Y`) — é
assim que se percebe uma fonte degradando ao longo das semanas.

- **Yahoo**: `query1.finance.yahoo.com/v8/finance/chart/PETR4.SA`, um por chamada,
  sem token, ilimitado. **Exige User-Agent de navegador.** Índice não leva `.SA`
  e o `^` precisa ser escapado — `simboloYahoo()` faz isso.
- **bolsai**: adaptador escrito e **NÃO VERIFICADO**. Três linhas marcadas no
  arquivo para conferir na documentação. Sem `BOLSAI_TOKEN`, é pulada.
- **brapi**: só o que sobrou. Gasta cota.

### Intradiário — `robo/intradia.mjs`, de hora em hora

**Funcionando desde 30/07.** Cron `0 13-21 * * 1-5` (10h–18h BRT). Busca só pela
brapi, grava em `cotacao_viva`, o site lê da view `retorno_parcial`.

Custo: 20 requisições por rodada, ~3.800/mês contra 15.000. O `BRAPI_LOTE` (padrão
1) define o tamanho inicial do lote; se um dia o plano subir, põe 20 nos secrets.

**Duas decisões de desenho que não devem ser revertidas:**

1. **Quem busca é o Actions, não o navegador.** Cem visitantes custam zero. O
   caminho óbvio — cada visitante chamando a fonte — foi o que torrou a cota no
   duelo.
2. **O parcial é calculado no banco.** Se fosse no cliente, o site teria de
   entregar os pesos de cada carteira para qualquer visitante e o lacre acabaria.
   A view devolve só o número agregado.

### O que não serve

**Fundamentus:** morto, recusa IP de datacenter e falhou também pelo navegador.
Não tente de novo.
**MetaTrader 5 e RTD do Excel:** são pontes locais, presas a um computador com o
programa aberto. Não há endpoint para o Actions chamar. Serviria como script no
PC *enviando* para o Supabase — mas aí o site depende da sua máquina ligada.

### Índice de referência: `^BVSP`, só ele

BOVA11 e SMAL11 são papéis que uma carteira pode ter, não régua — e sendo ETF
distribuem provento, o que contaminaria a comparação. O Ibovespa é índice de
retorno total por construção.

---

## Decisões que não se discutem mais

**Oscilação, nunca preço** (no motor de carteira). Preço só existe no jogo de
especulação, em `barra`.

**Caixa = 100 − líquida.** Venda a descoberto entra dinheiro. Caixa positivo
rende CDI até 100%; negativo é margem e custa CDI.

**Peso anda sozinho:** `peso × (1+osc) / (1+retorno)` todo dia. Por isso
`peso_atual` não pode ser recalculado de `posicao` — perderia a deriva. Daí a
coluna `marco`.

**Declaração vale a partir do próximo pregão, sempre.** Era o furo mais grave do
projeto. Consertado em três lugares: `declarar()` (banco8), adoção no fechamento
(banco9) e **default da coluna `valida_de`** (banco11) — este último fechava a
estreia de carteira nova, que o front criava inserindo direto em `posicao`.

**Teto de 200%** na soma de compras e vendas. **Sem histórico retroativo.**

**O lacre é do banco, não da tela.** Vale igual para aposta (`aposta_le`).

**Atributo se deriva, nunca se declara** — com três exceções justificadas, todas
compromissos e todas **imutáveis**: a **classe**, o **rebalanceamento** e o
**lado da aposta**. Quem pudesse mudar depois escolheria a régua com o jogo já
jogado.

**Identidade autodeclarada saiu da tela** (29/07). As colunas ficam no banco.

**Quem aparece, e como** (banco18): apelido, um nome escolhido, ou anônimo.
Anônimo esconde na tela, não no banco — senão não haveria como bloquear abuso.

---

## As quatro classes

| Classe | O que o banco impõe |
|---|---|
| `all_in` | só compra · bruta de 100% a 200% — sem caixa, pode alavancar |
| `diversificada` | só compra · bruta abaixo de 100% · 5 a 15 papéis |
| `long_short` | ao menos uma compra e uma venda · bruta até 200% · é aqui que entra o hedge |
| `vendida` | só venda · bruta até 200% |

Sem sobreposição: o divisor entre `all_in` e `diversificada` é o caixa.

**Vão conhecido:** comprada com caixa e fora da faixa de 5 a 15 papéis não tem
classe. Se aparecer com frequência, baixar o mínimo da diversificada de 5 para 2.

---

## Rebalanceamento (banco19)

Escolhido na criação, **imutável**, cinco modos:

`nunca` · `semanal` · `mensal` · `anual` · `banda` (volta quando algum papel se
afastar mais que `banda_pct` pontos do declarado, padrão 5)

Não existe diário de propósito: custaria corretagem todo dia e ninguém faz.

A banda compara **tamanho** da posição, não sinal — vendida de −40 que virou −48
tem desvio de 8, igual a uma comprada de 25 que virou 33. Sem isso, dispararia na
hora errada em toda carteira com venda a descoberto.

**Rebalancear não é declarar de novo:** o `marco` não muda e `posicao` não é
tocada. Só o peso corrente volta para o declarado.

---

## O jogo de especulação

Escolhe **papel e direção** para o próximo pregão, até 10 por dia, sem obrigação
de jogar todo dia. Entrada na abertura. Stop e alvo o sistema propõe, em
**múltiplos da amplitude média do próprio papel** (padrão 0,6 para cada lado,
equidistante).

**Três convenções da apuração, e elas precisam ser públicas:**

1. Stop e alvo tocados no mesmo dia → **ambíguo, sai no fechamento**.
2. Gap além do limite → **preenche na abertura**. Stop não é promessa de preço.
3. Entrada sempre na abertura (o candle diário não tem o preço das 10h30).

**Pontuação:** alvo/gap_favor **+2** · fechamento a favor **+1** · zero **0** ·
fechamento contra **−1** · stop/gap_contra **−2** · ambíguo **±1**.

**A unidade do placar é o DIA**, não a operação: nota do dia = média dos pontos
daquele dia, sempre entre −2 e +2. Soma de pontos rankearia quem joga mais; média
por operação trataria 10 apostas correlacionadas como 10 evidências independentes.

**Nota final = média das notas diárias × dias/(dias+20).**

**Lacre:** aposta de outro só aparece quando o prazo fecha, na abertura do pregão
(banco17). Durante o dia todos veem o campo montado e nada pode mudar.

**Telas:** `#/apostar` e `#/placar`, ligadas na navegação.

### Os três vieses achados e corrigidos

**1. Imposto sobre volatilidade.** "Empate conta stop" parecia conservador e era
imposto: MGLU3 tinha 25 dias de empate em 64 e média −0,564%; LFTS11, zero
empates e +0,026%. O ranking de "melhor papel para operar" saía ordenado por
volatilidade invertida. Corrigido no banco14 — de 292 punições indevidas para 18
casos honestos.

**2. Alvo em porcentagem fixa.** Corrigido com múltiplos da amplitude
(`faixa_papel`).

**3. Assimetria da pontuação.** Stop mais perto que o alvo é atingido quase o
dobro das vezes (500 contra 254); com pontos simétricos, todo mundo perderia.
Daí o padrão equidistante. **O teste C do banco15 ainda não foi rodado.**

### Variante em aberto: papel contra papel

Mais simples que stop e alvo, e o banco já sabe fazer — compara a oscilação de
dois papéis na mesma data, sem preço. Ganha quem subiu mais, ou caiu menos.
Dispensa as três convenções. Vale considerar como formato principal do duelo,
com stop e alvo virando modo avançado.

---

## O que foi medido (64 pregões reais, abr–jul/2026)

**Neutralidade da apuração** — 2.432 operações:

| Lado | Média por operação |
|---|---|
| comprado | −0,114% |
| vendido | +0,139% |
| **soma** | **+0,025% ≈ zero** |

A expectativa negativa do comprado é mercado, não regra: **todos os 19 papéis
fecharam o trimestre no negativo** (MGLU3 −44,2%, BOVA11 −7,3%, ITUB4 −4,6%).

**Volatilidade das classes** (anualizada): Ações e Selic 8,55% · Hedge 9,48% ·
Diversificada 14,12% · Concentrada 14,81% · Alavancada 23,15%. O hedge com 36%
menos volatilidade que a comprada, sem ninguém programar isso.

**Dez papéis por dia não dão vantagem:** média por dia −0,031 / −0,120 / −0,072 /
−0,086 para 1, 3, 5 e 10 papéis (sem tendência), e desvio caindo de 1,690 para
0,771. Diversificar compra estabilidade, não nota.

**Determinismo:** duas carteiras com os mesmos papéis deram retorno e
volatilidade idênticos por caminhos independentes.

---

## A pergunta do provento, e o detector já de pé

Se a variação for bruta, a carteira de dividendo afunda no dia "ex" sem ter
perdido nada — e no modelo de peso o dinheiro **não tem para onde ir**, porque o
caixa é derivado.

No Brasil a série é ajustada retroativamente pela bolsa (caso Petrobras 2022: o
fechamento de quinta passou de R$ 36,25 para R$ 29,58 no dia seguinte). Então
**depende de qual fechamento anterior a fonte usa**, e isso muda de fonte para
fonte. O Yahoo mantém `Close` e `Adj Close` separados, o que sugere que o
principal não é ajustado — e é dele que sai o `previousClose`.

**O detector funciona sozinho:** `^BVSP` e `BOVA11` são gravados lado a lado todo
dia. Em 29/07 a diferença foi 0,32 ponto (erro de rastreamento normal). No dia em
que o BOVA11 ficar "ex", se a fonte for bruta, **a diferença salta pelo valor do
provento**. É só olhar quando o par descolar.

**Cuidado:** o preço cai na **data ex** (dia seguinte à "data com"), não na data
de pagamento. Provento de 0,6% se perde no ruído; serve JCP acima de 2%.

---

## O duelo — auditoria de 30/07

O `duelo-b3` é um HTML de 6.321 linhas com torneios, chaveamento, caldeirão,
badges, extrato e resgates. Antes de qualquer fusão, quatro coisas:

**1. `ADMIN_PASSWORD = "b3admin2024"` em texto puro no cliente**, numa página
pública. Quem abre o código-fonte vira admin — e admin aprova resgates e registra
pagamentos.

**2. `brapiToken` também no cliente**, e `proxyBaseUrl` nasce vazio: o duelo chama
a brapi **direto do navegador de cada visitante**, sem passar pelo proxy. Somado
ao limite de 1 ticker por chamada, é a explicação completa da cota queimada.

**3. Dinheiro real no desenho:** `houseRakePct: 0.25`, `registerPayment`,
`moneyLedger`, resgate com `prizeType: 'dinheiro'`. Taxa de 25% da casa sobre
disputa entre jogadores, com resgate em dinheiro, é outra categoria de produto no
Brasil (Lei 14.790/2023 e regime de licenciamento). **Precisa de opinião jurídica
antes de crescer, e principalmente antes de encostar no Saldo Positivo.**
**A pergunta que trava a fusão: o dinheiro fica ou sai?**

**4. Gerador de "retorno simulado"** para ativos sem cotação. Aceitável em jogo de
pontos fictícios; com dinheiro, não.

**Estado do proxy:** `duelo-b3-proxy` foi reescrito em 29/07 com cache de 60s,
origem obrigatória e chave de desligar. **`BRAPI_LIGADO` está em `false`** — o
duelo está sem cotação até virar para `true`.

---

## Armadilhas já pagas — não repita

**No Supabase, função nova nasce ABERTA.** O privilégio vem de `PUBLIC`, não de
`anon` — revogar de `anon` não faz nada. Em 29/07 as 36 funções estavam liberadas,
incluindo as `robo_*`, que se autopromovem a admin. **Todo arquivo novo termina
com `revoke ... from public` + `grant` para quem precisa.**

**`create or replace view` só aceita coluna acrescentada no FIM.** Mudar ordem,
nome ou tipo exige `drop view` antes (erro 42P16). Mesma família do `drop
function` quando a assinatura muda.

**`round(x, 2)` não existe para `double precision`** (erro 42883). Sempre
`round((x)::numeric, 2)`.

**O SQL Editor mostra só o resultado da ÚLTIMA consulta**, e se houver texto
selecionado executa **só a seleção**. Rode uma por vez.

**O editor do GitHub não apaga com Ctrl+A confiável.** Para trocar arquivo:
Delete file, depois Create new file. E o campo do nome guarda o caminho anterior.

**Arquivo que mora só em Downloads é arquivo perdido.** Nome com sufixo
(`robo__6_.mjs`) é sinal de cópia velha.

**Papel que morre é peso fantasma.** `AZUL4` virou AZUL532, depois AZUL54, e hoje
não existe. O `fechar_dia` trata papel sem cotação como **variação zero** via
`coalesce(o.valor, 0)`, silenciosamente e para sempre. Caçar zumbis:

```sql
select distinct pa.ativo from peso_atual pa
 where not exists (select 1 from oscilacao o where o.ativo = pa.ativo);
```

**Erro engolido é bug invisível.** O front criava a carteira e inseria as posições
sem checar o retorno — o porteiro da classe recusava e a pessoa via uma carteira
vazia com cara de sucesso. Sempre checar `error`.

**"Sem dado" não é "sem permissão".** A página da carteira decidia o lacre só pela
existência de linhas, e mostrava cadeado ao próprio dono. Três estados, não dois.

**`carteira.id` é `bigint`, `perfil.id` é `uuid`.** **RLS não restringe coluna, só
linha.** **`sou_admin()` precisa ser SECURITY DEFINER.** Não revogue `sou_admin`,
`eh_assinante`, `pode_mexer` nem `apelido_livre` de `anon` — o ranking para de
abrir para visitante deslogado.

---

## Como recuperar o SQL

Os `banco.sql` a `banco7.sql` se perderam. **Não peça por eles** — o Postgres
devolve o fonte:

```sql
select p.proname, pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;

select pg_get_viewdef('ranking'::regclass, true);

select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns where table_schema = 'public' order by 1, 2;

select tablename, policyname, cmd, qual, with_check
from pg_policies where schemaname = 'public' order by 1;

select p.proname,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as logado,
       has_function_privilege('service_role', p.oid, 'execute')  as robo
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;
```

Exportar em CSV e commitar em `sql/`. **O `funcoes.sql` do repositório é das 11h
de 29/07 e não tem nada do `banco10` em diante.**

---

## As migrações

| Arquivo | O que fez |
|---|---|
| `banco8` | `hoje_br()`, `proximo_pregao()`; `declarar()` grava próximo pregão |
| `banco9` | coluna `marco`; gatilho ignora declaração futura; adoção antes do cálculo |
| `banco10` | view `papeis_do_dia`; data real na `gravar_oscilacao`; recusa dia já fechado |
| `banco11` | classes, `valida_classe`, `trava_classe`, **default de `valida_de`** |
| `banco12` | `declarada_em`; `referencia` (`^BVSP`); `indice_referencia`; `carteira_contra_referencia` |
| `banco13` | tabela `barra` (OHLC), `apurar_operacao` |
| `banco14` | empate → `ambiguo`; view `faixa_papel` |
| `banco15` | `pontos()`, `limites_sugeridos()`, `apurar_aposta()` |
| `banco16` | tabela `aposta`, travas, `aposta_apurada`, `dt_dia`, `ranking_dt` |
| `banco17` | lacre da aposta abre na abertura |
| `banco18` | `exibir` e `nome_publico`; `autor` na view |
| `banco19` | rebalanceamento (5 modos) + `banda_pct` |
| `banco20` | `cotacao_viva`, `robo_gravar_viva`, `retorno_parcial`, `referencia_viva` |
| `banco21` | apagar de verdade **ou** encerrar; classe obrigatória (passo 4 comentado) |

---

## O que funciona hoje

Cadastro · apelido único · login · recuperação de senha · publicar carteira com
classe obrigatória e **tela de confirmação em duas etapas** · grade de posições ·
**declarado × hoje × deriva** na página da carteira · editar · histórico · ranking
**filtrado por classe** com desempate por carteira mais antiga · **parcial ao vivo
com legenda dizendo quando foi e quando será a próxima** · lacre · comparador ·
indicação · seguir · escolha de como aparecer · admin com seções recolhíveis ·
robô fechando o dia pelo Yahoo · **intradiário de hora em hora pela brapi** ·
comparação contra Ibovespa na janela de cada carteira · telas de palpite e placar.

---

## O que falta

**Com prazo**

1. Resolver o `peso_atual` vazio (topo deste arquivo).
2. Enquadrar ou apagar a carteira sem classe, e rodar o passo 4 do `banco21`.
3. Rodar o **teste C do banco15** — confirma se a pontuação é justa.
4. Reexportar o dump das funções e commitar em `sql/`.

**Tela**

5. Seletor de **rebalanceamento** no formulário, ao lado da classe, e etiqueta no
   ranking dizendo qual disciplina cada carteira segue.
6. Carteira **encerrada** precisa abrir por link com etiqueta "encerrada em X" e
   curva parada — hoje a `ranking` filtra por ativa e a página não abre.
7. Carteira sem posição mostrava "0 ativos · só comprada" no ranking — rótulo
   errado por acidente aritmético.
8. Dividir a navegação visualmente nas duas metades.

**Banco**

9. `fechar_dia` **recusar** papel sem cotação em vez de assumir zero, e um jeito
   de aposentar papel morto.
10. Coluna `fonte` em `oscilacao` — se uma fonte ajustar provento e a outra não,
    dois papéis do mesmo dia saem em réguas diferentes e nada avisa.
11. `and not p.bloqueado` na view `ranking`.
12. Religar o `recuperar.yml` (o banco10 consertou os dois bugs que o tornavam
    perigoso) e conferir o cron — os runs saíam às 11h, não às 8h/9h/10h.
13. `atualizar-universo.yml` nunca foi criado. E o `/quote/list` da brapi pode
    sofrer do mesmo limite de plano.
14. **ETFs no universo**: BOVA11 e SMAL11 só entram em carteira se estiverem em
    `universo`, e o filtro corta tudo que não é `AAAA9`. Regex não serve.

**Produto**

15. **Domínio.** O Worker do duelo atende por rota: dá para dividir sem tocar no
    jogo. Conferir se a rota é curinga (`saldopositivo.com.br/*`).
16. `SEU-DOMINIO` dentro de `avisar_seguidores()` — que, aliás, **não aparece
    sendo chamada por nenhum gatilho**. Se ninguém a chamar, o sino nunca toca.
17. E-mail: falta conta na Resend e os secrets `RESEND_API_KEY` e `EMAIL_DE`.
18. Pagamento: `/assinar` é só tela. O webhook precisa fazer `assinante = true`.
19. **Consumo do duelo**: cache no proxy (feito), mas o front continua chamando a
    brapi direto do navegador. E um teto diário no Worker, porque o pico de 9.000
    num domingo mostrou que a causa pode ser desconhecida.

---

## Ideias desenhadas, não construídas

**Ranking de pessoa.** Derivável do que existe. O furo: publicar é grátis, então
alguém publica vinte e é reconhecido pela melhor. A defesa é contar **todas** as
carteiras — e é por isso que apagar tem que ser limitado (banco21). Ponto não pode
vir de atividade: se declarar der ponto, declara-se sem motivo.

**Termômetro de palpites.** Prazo e apuração; duas agulhas (multidão e quem vem
acertando, peso `[n/(n+20)] × máx(0, acerto−0,45)`); consenso escondido até votar.

**Eixo de giro.** Frequência de re-declaração separa quem mexe todo dia de quem
mexe por trimestre. "Day trader" como classe de carteira **não é mensurável**
neste motor — foi por isso que virou a metade de especulação.

**Competição em chave** — inscrição, chaveamento 2 a 2 ou 3 a 3, eliminação por
rodada, veto de papéis, opção de não repetir papel já usado. O duelo já tem
chave, torneio e eliminação prontos; a fusão usa o motor de apuração daqui.
Cuidado medido: "quem oscilou menos perde" premia volatilidade por construção —
precisa da mesma normalização por amplitude.

---

## Decisões em aberto

**O dinheiro do duelo fica ou sai?** É o que trava a fusão das duas metades.

**Sharpe encolhido.** A `metricas()` exige 20 pregões, anualiza por média
aritmética (a versão composta transformava +9% em 21 dias em +183% ao ano e o
Sharpe ia a 13,69) e encolhe por `n/(n+40)`. **Não é o Sharpe de livro** — é
Sharpe para ordenar. Alternativa: valor cheio com a coluna escondida até 60 dias.

**Quando pedir CPF e endereço.** Hoje o cadastro pede nome e telefone; a ficha
completa fica para `/assinar`.

**brapi:** existe uma segunda conta. Não escrevi nada que gerencie rodízio e não
vou; o robô lê o `BRAPI_TOKEN` que estiver nos secrets. **Um token foi exposto em
conversa e precisa ser substituído.** E o token que está dentro do HTML do duelo
precisa sair de lá.

---

## Parágrafo para colar no chat novo

> Estou construindo o Saldo Positivo, site com duas metades: **investidores**
> publicam carteiras de estudo de ações da B3 (desempenho público, papéis e pesos
> só para assinantes, ranking por classe) e **especuladores** palpitam papel e
> direção para o próximo pregão, com stop e alvo sugeridos pela volatilidade e
> placar por pontos. Banco no Supabase, site num HTML único publicado no GitHub
> Pages, robô diário em GitHub Actions puxando do Yahoo às 19h, e intradiário de
> hora em hora pela brapi. O MEMORIAL.md anexado tem todas as decisões tomadas,
> as armadilhas já pagas, os números que provaram o motor e o que falta —
> **leia antes de responder**, e repare nas pendências de estado logo no começo.
> Os `banco*.sql` de 1 a 7 se perderam; **não peça por eles**, o SQL está vivo no
> banco e o memorial traz as consultas que o devolvem. Nesta conversa quero
> trabalhar em [X].
