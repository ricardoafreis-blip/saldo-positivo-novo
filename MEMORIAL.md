# Saldo Positivo — memorial do projeto

Atualizado em 04/08/2026, fim do dia.
Anexe este arquivo no primeiro turno de qualquer conversa nova.

---

## O que é

Site onde qualquer pessoa publica uma carteira de ações hipotética. O
sistema apura sozinho o fechamento de cada pregão e **ninguém muda o
passado depois** — nem quem publicou. Não há dinheiro real, não é
recomendação, e a rentabilidade começa no dia da publicação: sem
histórico retroativo.

Além das carteiras há uma metade de jogo — Tiro curto, Placar, Duelo —
e uma tela de Screening quantitativo.

**Onde mora o quê**
- Repositório **público**: `ricardoafreis-blip/saldo-positivo-novo`
- Banco: Supabase, projeto `ixoucxcbategvjfdgmti`, plano gratuito
- Site no ar: GitHub Pages
- Domínio `saldopositivo.com.br`: Cloudflare, apontando hoje para o
  Worker `duelo-b3` (o jogo antigo). **Ainda não integrado.**

---

## A mudança grande: a cotação vem do MT5

**O que estava errado.** O robô calculava a oscilação a partir do
`meta.previousClose` do Yahoo, e esse campo vem `undefined` naquele
endpoint. **Todas as oscilações gravadas até 02/08 estavam erradas** —
não só de papéis ilíquidos, de todos. AUAU3 marcou 7,055% num pregão que
foi de 2,95%. O Yahoo também se mostrou instável: a mesma URL devolveu 10
candles às 20h30 e 9 às 20h41. E mesmo com os candles certos, o
fechamento dele divergia da B3.

**Como ficou.** Yahoo, brapi e bolsai foram removidos. Um EA no
MetaTrader manda o candle inteiro; o banco deriva a oscilação comparando
um pregão com o anterior.

```
MT5 (EA) → mt5_gravar → tabela barra → oscilacao (derivada no banco)
                                              ↓
                          robo.mjs → fechar_dia → retorno_dia → site
        └→ mt5_viva → cotacao_viva (preço ao vivo, a cada 60s)
```

---

## Rotina de todo dia

1. **MT5 aberto** com o EA `SaldoPositivo_MT5` anexado a um gráfico. Ele
   pergunta ao site quais papéis interessam (`papeis_do_dia`: carteiras +
   tiros + referências + universo), adiciona ao Observador, manda os
   candles e cota ao vivo durante o pregão. Quando o pregão encerra, ele
   manda os candles definitivos sozinho — **uma vez por dia**.
2. **Actions → Fechar o dia** roda sozinho em sete horários (18h20,
   21h30, 8h30, 8h45, 9h, 9h15, 9h30) e também pelo botão. O robô recusa
   apurar duas vezes o mesmo pregão, então tentar de novo é barato.
3. **Backup** roda às 3h: estrutura para `sql/` no repositório, dados
   como artefato privado do Actions (o repositório é público).

---

## Armadilhas já pagas — não repetir

**`auth.uid()` não funciona com a chave de serviço.** A permissão das
funções `mt5_gravar`, `mt5_viva` e `fechar_dia` é por
`current_setting('request.jwt.claim.role') = 'service_role'`. Custou três
tentativas.

**`TimeCurrent()` no MT5 é o relógio do SERVIDOR e para quando o mercado
fecha.** No domingo marcava sexta 19h21 e o EA concluiu que o pregão
estava aberto. Tudo usa `TimeLocal()`.

**`WebRequest` do MT5 é síncrono** e trava o terminal inteiro. Regra:
uma requisição por tique. A primeira versão mandava 34 seguidas e
congelava o MT5 por 30 segundos.

**Filtro de símbolo por nome não separa ação de futuro.** WINQ26 e BOVA11
têm o mesmo padrão. Varrer os 77 mil símbolos da corretora encontrou
2.220 "ações", quase tudo lixo. Por isso o EA pega a lista do site.

**O MT5 só entrega histórico de símbolo cujo gráfico já foi carregado.**
Hoje só ~40 papéis têm 34+ pregões na tabela `barra`; os outros vão
enchendo a cada carga funda. Para acelerar: abrir os gráficos diários.

**`create table as select` no Supabase nasce SEM RLS** e exposto pela
API. Um backup temporário de `peso_atual` ficou legível por qualquer um
até ser apagado.

**Um script de edição que aborta no meio não grava nada.** Aconteceu duas
vezes e mudanças ficaram horas fora do arquivo sem ninguém notar.

---

## Decisões de produto que já foram tomadas

**Classe imutável.** Escolhida no nascimento da carteira. Trocar depois
de ver o resultado seria escolher a régua com o jogo jogado. Rebalancea-
mento pode mudar, e a troca vira nota no extrato.

**Cada classe tem seu próprio pódio.** O ranking vem em quatro colunas,
uma por classe. Comparar uma 60/40 com uma alavancada mede o risco que
cada uma tomou, não a escolha de quem montou.

**Sem histórico retroativo.** É o que separa o site de print de lucro no
Telegram. A coluna de dias fica sempre visível, porque quem apaga e
recomeça volta a zero à vista de todos.

**Encerrar conta arquiva, não apaga.** Vai para `conta_arquivada`, sai do
site, e os dados ficam para consulta e reativação. ⚠️ Guardar registro é
legítimo; usar aqueles contatos para alcançar quem pediu para sair não é.

**Assinatura desligada.** O site está todo aberto. Cobrar antes de haver
carteira com track record é vender o que ainda não existe. A estrutura
(`assinatura`, `dar_assinatura`, `painel_assinatura`) está pronta e o
`sincronizar_assinantes()` roda dentro do `fechar_dia`.

---

## Pendências, em ordem de urgência

**1. O lacre ainda está de pé no banco.** As telas pararam de vender
assinatura, mas a RLS continua exigindo `assinante` para ver papéis e
pesos. Para abrir de verdade, precisa ver as políticas:
`select tablename, policyname, qual from pg_policies where tablename in ('peso_atual','posicao','nota');`

**2. Confirmação de e-mail.** O SMTP padrão do Supabase manda **2
e-mails por hora no projeto inteiro**. Se divulgar, a terceira pessoa não
entra. Ou desligar "Confirm email" em Authentication → Providers, ou
ligar SMTP próprio (Resend tem 3.000/mês grátis e já há
`RESEND_API_KEY` nos secrets).

**3. A chave secreta do Supabase e a senha do banco apareceram no
histórico de conversa** e não foram trocadas.

**4. Cálculos que assumem carteira comprada erram na vendida.** Caixa
(`100 − líquida` passa de 200 — já tratado na tela, não no banco),
drawdown (perder quando o mercado sobe é a carteira funcionando) e o
gatilho de encerramento por perda total (vendida pode passar de −100%).

**5. Integrar o domínio.** Site novo na raiz, duelo em `/duelob3`.
**Antes disso:** a senha de admin do duelo está em texto puro no código
do cliente.

**6. Repositório público.** O `index.html` e os comentários do código
estão visíveis, e o backup de dados precisou virar artefato privado por
causa disso.

**7. O Duelo não grava nada.** Já pareia por classe e usa o parcial
certo, mas não acumula ponto nem tem histórico.

---

## Vocabulário do banco (não bate com a tela)

| No banco | Na tela |
|---|---|
| `diversificada` | Comprada |
| `all_in` | aposentada, carteiras encerradas |
| `sessenta_quarenta` | 60/40 |
| tabela `aposta` | Tiro curto |
| rota `#/apostar` | `#/tiro-curto` (a antiga ainda responde) |

---

## Regras do Screening (as oito fases)

| Ordem das médias | Preço | Estado |
|---|---|---|
| 17 > 34 > 72 | acima da 17 | fortíssima alta |
| 17 > 34 > 72 | abaixo da 17 | realizando na alta |
| 17 < 34, ambas > 72 | acima da 72 | possível saída da alta |
| 17 < 34, ambas > 72 | abaixo da 72 | saindo da alta · indefinido |
| 17 > 34, ambas < 72 | abaixo da 72 | possível saída da baixa |
| 17 > 34, ambas < 72 | acima da 72 | saindo da baixa · indefinido |
| 17 < 34 < 72 | acima da 17 | realizando na baixa |
| 17 < 34 < 72 | abaixo da 17 | fortíssima baixa |

Quando as médias estão desalinhadas (17>72>34 ou 34>72>17): se o **preço
passou das três**, é *virando para alta* ou *virando para baixa* — quem
manda é o preço, as médias chegam depois. Se está no meio delas, *sem
tendência*.

Nunca dizer "comprado" ou "vendido": são sinais de operação, e o site é
assinado por analista credenciado. A tela descreve onde o preço está.

---

## Arquivos e onde ficam

| Arquivo | Onde |
|---|---|
| `index.html` | raiz do repositório |
| `robo.mjs` | `robo/` — 165 linhas, sem fonte externa |
| `SaldoPositivo_MT5.mq5` | `MQL5/Experts` no MT5 |
| `fechar-dia.yml`, `backup.yml` | `.github/workflows/` |

Workflows ativos: *Fechar o dia*, *Backup*, *Testar Yahoo* (inofensivo,
só imprime). Desativados: *Cotação ao vivo*, *Carregar histórico*,
*Recuperar dia perdido*.

**SQL rodado nesta semana** (guardado nas conversas, e a estrutura vai
para `sql/estrutura.sql` a cada backup): `mt5_gravar`, `mt5_viva`,
`quant_medias`, `fechar_dia`, `fora_da_banda`, `refazer_pesos`,
`encerrar_minha_conta`, `sincronizar_assinantes`, `dar_assinatura`,
`tirar_assinatura`, tabelas `barra`, `fechamento`, `parametro`,
`assinatura`, `conta_arquivada`, `rebalanceamento`.

---

## Duas taxas que precisam andar juntas

`parametro.cdi_ano` no banco (hoje 15%) e `CDI_ANO` no topo do
`index.html`. Se uma mudar e a outra não, o Sharpe e o gráfico passam a
discordar da apuração.

---

## Como trabalhar comigo neste projeto

- Ricardo é CNPI e prefere implementação direta a discussão abstrata.
- Todo bloco de código precisa de etiqueta: *rode isto no SQL Editor*,
  *trecho do arquivo, só para ver*, *já apliquei no arquivo*. Sem isso,
  exemplo vira comando colado no lugar errado — aconteceu três vezes.
- Chaves e senhas: ele preenche, eu não escrevo em arquivo nenhum.
- Quando ele desconfia de um número, geralmente há um erro real. O maior
  bug da semana saiu de um "essa carteira nunca daria 4% com essas
  oscilações".
