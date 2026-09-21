# LAB 2 — Observabilidade Baseada em Impacto e Governança

Stack aberto (Grafana · Prometheus · Loki · Tempo · OpenTelemetry Collector)
sobre o **FIAP OTEL Bank**, para o Encontro 2: correlação entre alerta técnico
e impacto de negócio, Error Budget como instrumento de decisão, e comunicação
de impacto para diferentes audiências.

É o repositório irmão de [`tonanuvem/splunk`](https://github.com/tonanuvem/splunk)
(Encontro 1). A aplicação continua em
[`tonanuvem/bank-demo`](https://github.com/tonanuvem/bank-demo) — **nada aqui
altera o código dela**: tudo é variável de ambiente e configuração de collector.

---

## Começando

```bash
# 1. a aplicação, na variante BRIDGE (o LAB 2 não usa network_mode: host)
cd ~/bank-demo-docker
docker compose -f docker-compose-network-docker-internal.yml up -d

# 2. o stack de observabilidade
cd ~/grafana
bash run-stack.sh

# 3. carga (sem tráfego os painéis ficam vazios)
bash carga.sh --cenario transaction --usuarios 10
```

| | |
|---|---|
| Grafana | http://localhost:3001 |
| Prometheus | http://localhost:9090 |
| Service Map | Explore → Tempo → **Service Graph** |
| Logs | Drilldown → **Logs** |
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
run-stack.sh                sobe, valida e conecta a aplicação
carga.sh                    gerador de carga (locust)
deploy.sh                   publica versões / rollback / piorar
decisao.sh                  registra a decisão com os números do momento
slo.sh                      alvo do SLO e valor por transferência
lib.sh                      funções comuns aos scripts
app/                        o guia do aluno (nginx) -- bash app/guia.sh
docs/                       roteiro e gabarito
stack/
  docker-compose.yml        versões pinadas de propósito
  otelcol/config.yaml       spanmetrics, service_graph, normalização, peer.service
  prometheus/rules/         SLIs, error budget, burn rate  (alvos.yml é gerado)
  loki/ tempo/ grafana/     configs e provisionamento
lab2/
  lab2.env                  o que o LAB 2 muda no bank-demo -- só variáveis
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

**Nenhum override de compose.** O compose do `bank-demo` declara as variáveis
com `${VAR:-default}`, então o LAB 2 é um arquivo `.env` — inclusive o deploy,
que reescreve quatro linhas em vez de gerar YAML. O `run-stack.sh` **funde**
`lab2/lab2.env` com o `.env` que já existir no `bank-demo`, porque
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
