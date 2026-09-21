# Funcoes comuns aos scripts do LAB 2. Sempre com `source`.
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$AQUI/stack"
PROJETO="fiapbank-lab2"
BASE_APP="${BASE_APP:-$HOME/bank-demo-docker}"
COMPOSE_APP="docker-compose-network-docker-internal.yml"
PROM="${PROM:-http://localhost:9090}"
PUSH="${PUSH:-http://localhost:9091}"

ok()    { echo "  [OK] $1"; }
aviso() { echo "  [!]  $1"; }
erro()  { echo "  [ERRO] $1"; }
titulo(){ echo; echo "=================================================="; echo " $1"; echo "=================================================="; }

# A cadeia de -f do compose da aplicacao, na ordem certa. Os arquivos que
# comecam com ponto sao gerados pelos scripts e nao vao para o git.
compose_app() {
    local args=(-f "$BASE_APP/$COMPOSE_APP" -f "$AQUI/lab2/docker-compose-lab2.yml")
    [ -f "$AQUI/lab2/.porta-dashboard.yml" ] && args+=(-f "$AQUI/lab2/.porta-dashboard.yml")
    [ -f "$AQUI/lab2/.versao-atual.yml" ]    && args+=(-f "$AQUI/lab2/.versao-atual.yml")
    printf '%s\n' "${args[@]}"
}

# Consulta instantanea no Prometheus. Devolve o valor ou vazio.
promq() {
    curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)['data']['result']
    print(r[0]['value'][1] if r else '')
except Exception:
    print('')
"
}

exige_stack() {
    curl -sf "$PROM/-/ready" >/dev/null 2>&1 || {
        erro "o stack do LAB 2 nao esta no ar."
        echo "       Suba antes:  bash $AQUI/run-stack.sh"
        exit 1
    }
}
