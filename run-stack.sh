#!/usr/bin/env bash
# =============================================================================
# LAB 2 -- sobe o stack de observabilidade e liga o bank-demo nele
# =============================================================================
#   bash run-stack.sh             sobe tudo e valida
#   bash run-stack.sh --parar     derruba o stack (preserva dados)
#   bash run-stack.sh --status    mostra o estado atual
#   bash run-stack.sh --sem-app   so' o stack, sem religar o bank-demo
#
# O collector daqui NAO disputa porta com o splunk-otel-collector: ele nao
# publica 4317/4318 no host. Os dois convivem na mesma maquina.
# =============================================================================

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$AQUI/stack"
PROJETO="fiapbank-lab2"

BASE_APP="${BASE_APP:-$HOME/bank-demo-docker}"
COMPOSE_APP="docker-compose-network-docker-internal.yml"
OVERRIDE="$AQUI/lab2/docker-compose-lab2.yml"

ACAO="subir"
RELIGAR_APP=true

for ARG in "$@"; do
    case "$ARG" in
        --parar)   ACAO="parar" ;;
        --status)  ACAO="status" ;;
        --sem-app) RELIGAR_APP=false ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERRO] opcao desconhecida: $ARG"; exit 1 ;;
    esac
done

titulo() { echo; echo "=================================================="; echo " $1"; echo "=================================================="; }
ok()     { echo "  [OK] $1"; }
aviso()  { echo "  [!]  $1"; }
erro()   { echo "  [ERRO] $1"; }


# ------------------------------------------------------------------ parar
if [ "$ACAO" = "parar" ]; then
    titulo "PARANDO O STACK DO LAB 2"
    docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" down 2>/dev/null
    ok "stack parado (volumes preservados)"
    echo
    echo "  Para apagar tambem os dados:"
    echo "    docker compose -p $PROJETO -f $STACK/docker-compose.yml down -v"
    exit 0
fi


# ----------------------------------------------------------------- checagens
titulo "LAB 2 -- OBSERVABILIDADE COM GRAFANA"

echo
echo "1. PRE-REQUISITOS"
echo "--------------------------------------------------"

command -v docker >/dev/null 2>&1 || { erro "Docker nao encontrado."; exit 1; }
docker info >/dev/null 2>&1      || { erro "Docker instalado, mas o daemon nao responde."; exit 1; }
ok "docker"

# A aplicacao precisa estar rodando NA VARIANTE BRIDGE: e' ela que cria a
# rede em que o collector vai entrar. Em network_mode: host nao ha rede.
REDE=$(docker network ls --format '{{.Name}}' | grep -E '(fiapbank|martianbank)-otel-hg_bankapp-network' | head -1)

if [ -z "$REDE" ]; then
    erro "A rede do bank-demo (variante bridge) nao existe."
    echo "       O LAB 2 usa a variante BRIDGE, nao a host."
    echo
    echo "       Suba a aplicacao antes:"
    echo "         cd $BASE_APP"
    echo "         docker compose -f $COMPOSE_APP up -d"
    exit 1
fi
ok "rede do bank-demo: $REDE"

# Portas que o stack publica. A 4317/4318 NAO estao aqui de proposito.
for P in 9090 3100 3200 3001 8007; do
    DONO=$(docker ps --format '{{.Names}} {{.Ports}}' | grep ":$P->" | awk '{print $1}' | head -1)
    if [ -n "$DONO" ] && [[ "$DONO" != lab2-* ]]; then
        erro "porta $P ocupada por '$DONO'."
        echo "       Libere antes de subir: docker stop $DONO"
        exit 1
    fi
done
ok "portas livres (9090, 3100, 3200, 3001, 8007)"

if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet splunk-otel-collector 2>/dev/null; then
        ok "splunk-otel-collector segue ativo -- e nao ha conflito: o collector"
        echo "       do LAB 2 nao publica 4317/4318 no host."
    fi
fi

printf 'REDE_BANK=%s\n' "$REDE" > "$STACK/.env"


# ------------------------------------------------------------------ subir
echo
echo "2. SUBINDO O STACK"
echo "--------------------------------------------------"

docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" up -d --remove-orphans >/dev/null 2>&1

# Um container que falha ao publicar porta fica CRIADO sem rede, e um `up`
# seguinte apenas o inicia, quebrado e em silencio. Por isso conferimos.
for C in lab2-otelcol lab2-prometheus lab2-loki lab2-tempo lab2-grafana; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
        aviso "$C nao subiu -- recriando"
        docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" up -d --force-recreate "${C#lab2-}" >/dev/null 2>&1
    fi
done

esperar() {
    local nome="$1" url="$2" i=0
    until curl -sf "$url" >/dev/null 2>&1 || [ $i -ge 45 ]; do i=$((i+1)); sleep 2; done
    if [ $i -ge 45 ]; then erro "$nome nao respondeu"; return 1; fi
    ok "$nome"
}

esperar "prometheus" "http://localhost:9090/-/ready"
esperar "loki"       "http://localhost:3100/ready"
esperar "tempo"      "http://localhost:3200/status"
esperar "grafana"    "http://localhost:3001/api/health"
docker ps --format '{{.Names}}' | grep -qx lab2-otelcol && ok "otelcol"


# ------------------------------------------- religar a aplicacao no collector
if [ "$RELIGAR_APP" = "true" ]; then
    echo
    echo "3. APONTANDO O BANK-DEMO PARA ESTE COLLECTOR"
    echo "--------------------------------------------------"

    if [ ! -f "$BASE_APP/$COMPOSE_APP" ]; then
        erro "$BASE_APP/$COMPOSE_APP nao encontrado."
        echo "       Ajuste com: BASE_APP=/caminho bash run-stack.sh"
        exit 1
    fi

    # A porta 5000 do dashboard e' disputada em algumas maquinas (no macOS o
    # AirPlay Receiver fica com ela). Em vez de falhar com "address already
    # in use" no meio da aula, remapeamos e avisamos.
    EXTRA=""
    if ss -lnt 2>/dev/null | grep -q ":5000 " || lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1; then
        if ! docker ps --format '{{.Names}} {{.Ports}}' | grep -q ":5000->"; then
            aviso "porta 5000 ocupada por outro processo -- usando 5050"
            cat > "$AQUI/lab2/.porta-dashboard.yml" <<YML
# Gerado pelo run-stack.sh. Nao versionar.
services:
  dashboard:
    ports: !override ["${PORTA_DASHBOARD:-5050}:5000"]
YML
            EXTRA="-f $AQUI/lab2/.porta-dashboard.yml"
        fi
    fi

    SAIDA=$( (cd "$BASE_APP" && docker compose -f "$COMPOSE_APP" -f "$OVERRIDE" $EXTRA up -d) 2>&1 )
    if [ $? -eq 0 ]; then
        ok "servicos recriados apontando para otelcol:4317"
        [ -n "$EXTRA" ] && echo "       dashboard em http://localhost:${PORTA_DASHBOARD:-5050}"
    else
        erro "falha ao recriar os servicos"
        echo "$SAIDA" | tail -3 | sed 's/^/       /'
        exit 1
    fi
fi


# ------------------------------------------------------------------ validar
echo
echo "4. A TELEMETRIA ESTA CHEGANDO?"
echo "--------------------------------------------------"

SERIES=$(curl -s 'http://localhost:9090/api/v1/query?query=count(traces_span_metrics_calls_total)' 2>/dev/null \
         | grep -oE '"value":\[[0-9.]+,"[0-9]+"' | grep -oE '"[0-9]+"$' | tr -d '"')

if [ -z "$SERIES" ] || [ "$SERIES" = "0" ]; then
    aviso "nenhuma metrica derivada ainda."
    echo
    echo "       Isso e' ESPERADO sem transito: as metricas nascem dos traces."
    echo "       Gere carga e os paineis se preenchem em ~30s:"
    echo
    echo "         bash $AQUI/carga.sh --cenario transaction --usuarios 10"
else
    ok "$SERIES series derivadas dos traces"
fi


# ------------------------------------------------------------------ acesso
IP=$(curl -s --max-time 3 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
H="${IP:-localhost}"

titulo "ACESSO"
echo
echo "  Grafana       http://$H:3001"
echo "  Prometheus    http://$H:9090"
echo
echo "  Service Map   Explore > Tempo > Service Graph"
echo "  Logs          Drilldown > Logs"
echo
[ -n "$IP" ] && echo "  (libere 3001 e 9090 no Security Group)" && echo
