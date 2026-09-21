# LAB GRAFANA — Observabilidade Baseada em Impacto e Governança

Stack aberto (Grafana · Prometheus · Loki · Tempo · OpenTelemetry Collector)
sobre o **FIAP OTEL Bank**, para o este encontro: correlação entre alerta técnico
e impacto de negócio, Error Budget como instrumento de decisão, e comunicação
de impacto para diferentes audiências.

É o repositório irmão de [`tonanuvem/splunk`](https://github.com/tonanuvem/splunk)
(Encontro 1). A aplicação continua em
[`tonanuvem/bank-demo`](https://github.com/tonanuvem/bank-demo) — **nada aqui
altera o código dela**: tudo é variável de ambiente e configuração de collector.

---

## Começando

```bash
git clone https://github.com/tonanuvem/grafana.git ~/grafana
cd ~/grafana && bash run-lab.sh
```

Um comando. Ele baixa o `bank-demo`, garante o MongoDB, constrói as imagens,
sobe a aplicação, o stack e o guia — nessa ordem, que é obrigatória: a
aplicação cria a rede em que o collector entra, e o MongoDB precisa existir
antes dela.

```bash
bash carga.sh --fundo --cenario transaction --usuarios 10 --duracao 120m
```

Sem carga os painéis ficam vazios: as métricas deste lab nascem dos traces.

| | |
|---|---|
| Banco | http://localhost:3000 |
| Guia do aluno | http://localhost:8031 |
| Grafana | http://localhost:3001 |
| Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |
| Service Map | Explore → Tempo → **Service Graph** |
| Logs | Drilldown → **Logs** |

Para derrubar: `bash remove-lab.sh` (preserva dados e imagens; `--dados` e
`--imagens` removem, com confirmação).

**Numa EC2**, libere no Security Group: `3000 3001 5000 8000 8001 8027 8031
8080 9090 9093`. A **8027** é a do RUM — sem ela a página funciona e o RUM
fica mudo, sem erro em lugar nenhum.

Outras opções: `--sem-build` pula a construção das imagens, `--com-carga` já
deixa a carga rodando, `--sem-guia` não sobe a página do aluno.

---|---|
| Grafana | http://localhost:3001 |
| Prometheus | http://localhost:9090 |
| Service Map | Explore → Tempo → **Service Graph** |
| Logs | Drilldown → **Logs** |
| Alertas | http://localhost:9093 (Alertmanager) |
| Guia do aluno | http://localhost:8031 (`bash app/guia.sh`) |

---

## Convive com o collector da Splunk

O `splunk-otel-collector` do Encontro 1 pode continuar rodando no systemd.
O collector deste lab **não publica 4317/4318 no host**: ele entra na mesma
rede Docker do bank-demo e as aplicações falam com ele por `otelcol:4317`.

A única porta de host que ele usa é a **8007** (`fluent_forward`), porque quem
abre essa conexão é o daemon do Docker, que roda no host. A 8006 fica com a
Splunk.

```
bank-demo ──OTLP (rede interna)──> otelcol (container)  ──> Prometheus / Loki / Tempo
          ──OTLP (127.0.0.1:4317)─> splunk-otel-collector ──> Splunk O11y
```

---

## Estrutura

```
run-lab.sh                  porta de entrada: sobe tudo, na ordem certa
remove-lab.sh               tira tudo do ar
run-stack.sh                só o stack (o run-lab.sh chama este)
carga.sh                    gerador de carga (locust)
deploy.sh                   publica versões / rollback / piorar
decisao.sh                  registra a decisão com os números do momento
slo.sh                      alvo do SLO e valor por transferência
lib.sh                      funções comuns aos scripts
app/                        o guia do aluno (nginx) -- bash app/guia.sh
docs/                       roteiro e gabarito
stack/
  docker-compose.yml        versões pinadas de propósito
  alertmanager/             agrupamento e supressão — o exercício de ruído
  otelcol/config.yaml       spanmetrics, service_graph, normalização, peer.service
  prometheus/rules/         SLIs, error budget, burn rate  (alvos.yml é gerado)
  loki/ tempo/ grafana/     configs e provisionamento
env/
  grafana.env               o que o LAB GRAFANA muda no bank-demo -- só variáveis
```

---

## Decisões que valem conhecer

Tudo abaixo foi **medido neste ambiente**, não presumido.

**Duas convenções semânticas convivem.** Os serviços Python emitem
`http.status_code`; os Node emitem `http.response.status_code`. Um processor
`transform` normaliza os dois — sem ele, toda query precisaria de um `or`.

**`peer.service` é obrigatório para ver serviço morto.** Sem ele, com o
`accounts` derrubado o Service Map não mostra *nada*: não há span de servidor
para parear. Com ele, aparece como nó virtual com `failed="true"`.

**Spans de middleware não viram métrica.** A instrumentação do Express cria um
span por middleware; um `filter` os mantém no Tempo e os tira da métrica
(de 26 para 9 séries). 

**O Loki precisa de `otlp_config`.** No padrão ele promove 34 atributos a
label de stream, inclusive `trace_id` — um stream por trace. Com a
configuração daqui ficam 3 labels; o resto vira metadata estruturada.

**`le` é normalizado pelo Prometheus.** O collector expõe `le="1500"` e o
Prometheus grava `le="1500.0"`. Uma regra com `le="1500"` não casa com nada e
deixa o painel de latência vazio, sem erro nenhum.

**RUM sem tocar na aplicação.** O `bank-demo` já injetava o agente da Splunk no
`index.html` em tempo de execução; o mesmo script ganhou um ramo para o
**Grafana Faro**, ligado por `FARO_COLLECTOR_URL`. Quem posta no coletor é o
navegador do aluno, então esse endereço precisa ser alcançável de fora — o
`run-stack.sh` troca `localhost` pelo IP público quando detecta um.

O receiver `faro` é a única porta do collector publicada para fora, e a única
que precisa de CORS. E precisa de `allowed_headers` além de `allowed_origins`:
sem ele o preflight responde 204, que parece sucesso, mas sem
`Access-Control-Allow-Origin` — o navegador descarta o POST em silêncio.

**Alertas não entregam em lugar nenhum, de propósito.** Os receptores do
Alertmanager não têm destino: o exercício é de `group_by` e `inhibit_rules`,
e o que se compara é quantos alertas disparam contra quantos chegariam a uma
pessoa.

**Nenhum override de compose.** O compose do `bank-demo` declara as variáveis
com `${VAR:-default}`, então o LAB GRAFANA é um arquivo `.env` — inclusive o deploy,
que reescreve quatro linhas em vez de gerar YAML. O `run-stack.sh` **funde**
`env/grafana.env` com o `.env` que já existir no `bank-demo`, porque
`--env-file` substitui o `.env` padrão em vez de somar, e na EC2 do Encontro 1
há um com realm e token do Splunk.

A única exceção é o log driver do Node: `logging.options` muda de *chave*
conforme o driver, e interpolação não torna chave condicional — com
`json-file`, `fluentd-address` é opção inválida. Esse continua sendo o
`docker-compose-logs-fluentd.yml` que o `bank-demo` já tinha, agora com a
porta parametrizada.

**A degradação é por variável de ambiente, não por limite de CPU.** Medido: o
teto de CPU degrada de forma imprevisível — sob concorrência o gargalo se
desloca para o BFF e para o MongoDB, e o mesmo limite produz resultados
diferentes conforme a carga de cada aluno. Num laboratório a degradação precisa
ser igual para todo mundo, então ela vive em `ATRASO_ARTIFICIAL_MS` /
`FALHA_ARTIFICIAL_PCT` no `transactions`.

**O erro do serviço de domínio não chega à borda como erro.** Com o
`transactions` devolvendo 500, o `dashboard` responde **200** ao cliente. Por
isso o SLI conta erro na cadeia inteira, e não só no ponto de entrada.

**Versões pinadas.** `pip install splunk-opentelemetry` sem versão é o maior
risco do laboratório: é a versão da distro que decide a convenção semântica.
Se ela mudar num rebuild, as queries retornam vazio sem ninguém ter tocado em
nada.
