# LAB GRAFANA — Error Budget, impacto e comunicação

Atividade prática do este encontro, sobre o FIAP OTEL Bank com stack aberto
(Grafana · Prometheus · Loki · Tempo). Duração sugerida: **90 a 110 minutos**.

> "Degradação parcial não gera dilema quando é óbvia. O exercício só existe
> porque a decisão é de verdade."

**Cada aluno tem o próprio ambiente.** O que ele quebrar não afeta ninguém, e
ele pode repetir quantas vezes quiser. Não há coreografia central: quem dispara
o incidente é o próprio aluno.

Guia para o aluno (nginx local): `bash app/guia.sh` → porta 8031.

---

## Antes da aula — preparo do instrutor

```bash
cd ~/grafana && bash run-lab.sh --com-carga
```

Um comando: ele baixa o `bank-demo`, garante o MongoDB, constrói as imagens,
sobe a aplicação, o stack e o guia, e deixa a carga rodando. Na primeira vez o
build leva 10 a 20 minutos — vale fazer na véspera.

Depois confira nos painéis que há dado nos **últimos 5 minutos**: não basta a
série existir. Para derrubar ao fim da aula, `bash remove-lab.sh`.

**Numa EC2**, libere no Security Group `3000 3001 5000 8000 8001 8027 8031
8080 9090 9093`. A **8027** é a do RUM, e é a que costuma faltar — sem ela a
página do banco funciona normalmente e o RUM fica mudo, sem erro em lugar
nenhum além do console do navegador.

**Como o LAB GRAFANA muda a aplicação:** por um arquivo de variáveis
(`env/grafana.env`), não por override de compose. O `run-stack.sh` funde esse
arquivo com o `.env` que já existir no `bank-demo` e passa o resultado com
`--env-file`. Para reproduzir o `SyntaxError` do Encontro 1 ao vivo, basta
`ERROS_AMIGAVEIS=false` e recriar o `dashboard`.

**Por que a variante bridge e não host:** o collector do LAB GRAFANA entra na rede do
bank-demo e não publica 4317/4318 no host, então o `splunk-otel-collector` do
Encontro 1 pode continuar rodando. Não é preciso parar nada.

---

## O que muda em relação ao LAB 1

| | LAB 1 | LAB GRAFANA |
|---|---|---|
| Falha | serviço **morto** (`docker stop`) | **degradação parcial** de um deploy |
| Pergunta | o SLI capturou? | o orçamento justifica **seguir ou reverter**? |
| Saída | SLIs e SLOs definidos | **decisão registrada + comunicação** |
| Backend | Splunk O11y | Prometheus · Loki · Tempo · Grafana |

---

## Roteiro

### Fase 1 — A mesma instrumentação, outro backend (10 min)

A aplicação não muda uma linha; só o destino da telemetria. `docker ps` mostra
os mesmos containers com o mesmo uptime.

**Service Graph** (`Explore → Tempo → Service Graph`) é o análogo do Service Map.
O MongoDB aparece como nó `bank`, inferido — igual ao `mongodb:bank` tracejado
do Encontro 1, pela mesma razão.

### Fase 2 — Business Health (25 min)

Três atos, no dashboard **1 · Saúde do Negócio**:

1. **Jornada feliz.** `carga.sh --cenario auth --usuarios 10`; dobre os usuários
   e a linha "Clientes autenticados por minuto" dobra.
2. **Jornada infeliz, disparada pelo aluno.** Errar a senha 5× na tela de login.
   Recusas sobem; **a taxa de erro técnica fica em zero**.
3. **O mesmo número por outro caminho.** O painel via Loki conta as mesmas
   recusas a partir do log do morgan.

**AIOps (3 min):** `Drilldown → Logs → Patterns`. O Loki agrupa as linhas em
padrões sozinho. Precisa de volume — com poucas linhas ele acha zero.

**RUM (5 min):** a linha de painéis no fim do dashboard 1 mede no navegador.
Peça ao aluno que erre a senha na tela e observe: o evento aparece no RUM, o
trace do navegador costura com o backend no Tempo, e nenhum SLI de servidor
registrou falha. É a resposta ao "observabilidade baseada em cliente" da
ementa, e o complemento do probe sintético — o probe roda às 3h da manhã sem
ninguém; o RUM só existe quando há gente.

### Fase 3 — O incidente (45 min)

```bash
bash deploy.sh nova-versao     # v1.1.0 — saudável, nada muda
bash deploy.sh nova-versao     # v1.2.0 — a regressão
bash decisao.sh rollback "..." # registra com os números do momento
bash deploy.sh rollback
```

O instrutor pode piorar o quadro **depois** que o aluno decidiu:

```bash
bash deploy.sh piorar          # 2,5s de atraso + 25% de falha
```

### Fase 3b — Ruído de alerta (5 min)

Com o incidente em curso, compare três números no dashboard 2: **alertas
disparando** no Prometheus, **alertas ativos** no Alertmanager e
**silenciados**. Depois abra a tela do Alertmanager (porta 9093) e conte os
GRUPOS — é o que chegaria a uma pessoa.

A regra que faz isso é `group_by: [jornada_negocio]` mais um `inhibit_rules`
que suprime a queima lenta enquanto a rápida está ativa. Nenhum modelo,
nenhum aprendizado de máquina: um arquivo YAML.

### Fase 4 — Comunicação (25 min)

O `decisao.sh` gera `estado/comunicacao-*.md` já com os números. O aluno escreve
os três textos e o postmortem.

---
---

# GABARITO

Os números abaixo foram **medidos** no ambiente de referência.

## Fase 1 — o que precisa aparecer

O Service Graph do Grafana e o Service Map do Splunk mostram a mesma topologia,
mas por caminhos diferentes: lá o backend infere, aqui as métricas são
derivadas **no seu collector** — e você paga a cardinalidade.

**Ponto extra:** notar que o nó do MongoDB se chama `bank` (o nome do banco de
dados), não `mongodb`. A identidade de um serviço não instrumentado é sempre o
que o *chamador* conseguiu registrar.

## Fase 2 — o achado central

| Sinal | Valor medido | O que significa |
|---|---|---|
| `negocio:logins_sucesso:rate5m` | 0,104/s | clientes que entraram |
| `negocio:logins_recusados:rate5m` | 0,021/s | clientes que **não** entraram |
| `tecnico:auth_erros:rate5m` | **0,0** | o SLI clássico não vê nada |
| taxa de recusa | **16,7%** | um em cada seis |

**Por que zero:** o `customer-auth` responde **HTTP 400** para senha errada
(`userController.js`, `Invalid email or password`), e a instrumentação
automática não marca 4xx como erro de span. Do ponto de vista técnico nada
falhou; do ponto de vista do cliente, ele não entrou no banco.

**Vale ponto:** o aluno perceber que 400 também cobre "campo em branco", e que
por isso o log (que traz a mensagem) é mais preciso que a métrica.

**Ponto extra:** notar que o mesmo painel serve à segurança — 5 senhas erradas
de uma pessoa é normal; 500 por minuto é *credential stuffing*.

## Fase 3 — a degradação, número a número

| Versão | p90 de `POST /transfer` | % abaixo de 1,5s | erros |
|---|---|---|---|
| v1.0.0 / v1.1.0 | **90 ms** | ~99,7% | ~0 |
| v1.2.0 | **1886 ms** | cai para ~55% | ~0 |
| v1.2.0 + `piorar` | ~2900 ms | **0%** | 4,5% |

**O que o aluno tem de perceber, em ordem:**

1. **O deploy saudável não move nada.** Sem essa linha de base, qualquer
   variação parece incidente.
2. **A degradação aparece com ~60 s de atraso**, porque as janelas de taxa são
   de 5 min. É a distância entre *quebrou* e *soubemos*.
3. **O negócio cai sem erro nenhum.** Requisições mais lentas concluem menos no
   mesmo minuto: "Transferências por minuto" despenca com a taxa de erro em zero.
4. **A quebra por versão** é o que transforma "está lento" em "foi o deploy".

### O erro do serviço de domínio não chega ao cliente como erro

Com `piorar`, o `transactions` devolve 500. O `dashboard` faz `response.json()`
— que funciona, porque o corpo do erro é JSON — e devolve **HTTP 200** com
`{"response":{"message":"Internal error"}}`.

**Medido:** `transactions POST /transfer` com `STATUS_CODE_ERROR`, e o span do
`dashboard` em `UNSET`. Um SLI ancorado só na borda mostraria **100% de
disponibilidade** com 25% das transferências falhando.

É por isso que a regra deste lab conta o erro na **cadeia inteira**
(`service_name=~"dashboard|transactions"`), e não só no ponto de entrada. É o
terceiro rosto do mesmo tema do Encontro 1.

### Depois do rollback

Latência e erro voltam em 1–2 min. **O orçamento restante não volta.** Ele só
se recupera conforme os minutos ruins saem da janela de 6h — o que, numa aula,
o aluno **não** vai ver acontecer. Não ver é a lição.

## Fase 3b — ruído de alerta, número a número

Medido durante o incidente, com os dois alertas em `firing`:

| | |
|---|---|
| Alertas disparando no Prometheus | **2** |
| Alertas ativos no Alertmanager | **1** |
| Silenciados | **1** — a queima lenta, `inhibitedBy` a rápida |
| Grupos | **1** — `jornada_negocio="Transferencia entre contas"` |

**Dois alertas, uma notificação.** É o número que sustenta a conversa: não se
perdeu informação nenhuma — o alerta suprimido continua visível para quem
investiga — mas quem está de plantão é interrompido uma vez, não duas.

**O tempo importa para planejar a aula.** O alerta rápido chega em cerca de
2 minutos (`for: 2m`). O lento tem `for: 10m` por definição — é o que o torna
lento —, então a **supressão só é observável depois de uns 10 minutos de
incidente sustentado**. Medido aqui: o estado `suppressed` apareceu 7min42s
depois de o rápido já estar em `firing`. Numa passada rápida o instrutor
mostra o agrupamento e não chega na supressão.

**A pergunta de fechamento:** nada disso é modelo nem aprendizado de máquina —
é `group_by` e `inhibit_rules` num arquivo YAML. E um detector de anomalia
treinado na taxa de erro técnica não veria absolutamente nada na Fase 2, onde
o sinal fica em zero o tempo todo. AIOps herda o ponto cego do sinal que
recebe.

## O que vale ponto na decisão

Não existe resposta certa entre reverter e seguir. Avalia-se:

**Obrigatório:**
- a decisão **cita percentual de orçamento e burn rate** — número, não adjetivo;
- existe **checkpoint com prazo** ("se em 10 min não cair, revertemos");
- o texto do executivo não contém percentil, nome de serviço nem de ferramenta;
- o aluno percebeu que rollback estanca mas não repõe orçamento.

**Erro clássico a corrigir:** reverter "porque tem erro". Se toda degradação
vira rollback, o orçamento não serve para nada — e a organização volta a ter
medo de entregar, que é o problema que SLO existe para resolver.

**Ponto extra:** perceber que a jornada *Extrato* também degradou (mesma
`transactions`), com impacto muito menor — duas jornadas, um incidente,
decisões possivelmente diferentes, e uma pausa de deploy que é global.

## Política de error budget — respostas defensáveis

| Restante | Resposta esperada |
|---|---|
| 25–50% | revisão obrigatória de risco antes de cada deploy; nada de sexta-feira |
| < 25% | só correção e trabalho de confiabilidade; funcionalidade nova espera |
| 0% | congelamento de deploys até o orçamento se recompor |

A pergunta que separa quem entendeu: **quem pode suspender a congelação?**
Se a resposta for "qualquer gerente que precise entregar", a política é
decorativa.

## CFR

Com 3 deploys o número é ridículo — e isso é conteúdo. CFR é métrica de
**tendência**. O que ela aponta não é "fomos descuidados hoje", é "esta
cadência de entrega é sustentável?". A ação estrutural que ela sugere aqui é
*canary* para o `transactions`, e o painel de R$/min é o que justifica o
investimento.

## Fechamento — as três ideias que devem sobrar

1. **Falha de negócio não tem assinatura técnica única.** Na autenticação ela é
   HTTP 400; na transferência é HTTP 200. Em nenhuma das duas o serviço "deu erro".
2. **Orçamento consumido não volta com rollback.** É o que diferencia error
   budget de um alerta comum, e o que o torna instrumento de decisão.
3. **AIOps herda o ponto cego do sinal que recebe.** Um detector de anomalia
   treinado na taxa de erro técnica não veria nada na Fase 2 — o sinal fica em
   zero o tempo todo. Sem SLI de negócio, o algoritmo aprende ruído.

---

## Armadilhas conhecidas (para o instrutor)

| Sintoma | Causa | Correção |
|---|---|---|
| Painéis vazios | sem carga | `carga.sh` — as métricas nascem dos traces |
| `Patterns` mostra zero | pouco volume de log | subir usuários; com ~950 linhas apareceram 3 padrões |
| Contador em 0 logo após o deploy | primeira exposição da série | some sozinho no scrape seguinte |
| Nó virtual demora a aparecer | `store.ttl` de 30 s no `service_graph` | é esperado; vale como atraso de detecção |
| Porta 5000 ocupada | AirPlay, no macOS | o `run-stack.sh` remapeia sozinho para 5050 |
| RUM mudo, sem erro no collector | CORS sem `allowed_headers` | o preflight responde 204 (parece sucesso) sem `Access-Control-Allow-Origin`, e o navegador descarta o POST |
| Alerta de queima rápida nunca dispara | `burn_rate:30m` vazio | `sum()` devolve vetor sem labels; dividir por `jornada:slo_objetivo` não casa. A taxa de 30 min precisa sair numa regra própria, **com** o label |
| Alerta de ausência nunca dispara | `absent()` sobre série com `or vector(0)` | a série sempre existe; o teste certo é `== 0` |
