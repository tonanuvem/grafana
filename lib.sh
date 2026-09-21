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

ENV_LAB2="$AQUI/lab2/lab2.env"
ENV_EFETIVO="$AQUI/lab2/.env-efetivo"

# Funde o .env que ja existir no bank-demo com o do LAB 2 (o nosso por cima).
#
# Por que fundir e nao so' apontar: `--env-file` SUBSTITUI o .env padrao, nao
# soma. Na EC2 do Encontro 1 existe um .env com realm e token do Splunk --
# apontar direto para o nosso descartaria aqueles valores em silencio.
gerar_env() {
    {
        echo "# ARQUIVO GERADO por run-stack.sh -- nao edite, nao versione."
        echo "# Fonte: $BASE_APP/.env (se existir) + lab2/lab2.env por cima."
        [ -f "$BASE_APP/.env" ] && grep -vE '^\s*(#|$)' "$BASE_APP/.env"
        grep -vE '^\s*(#|$)' "$ENV_LAB2"
    } > "$ENV_EFETIVO"
}

# O comando do compose da aplicacao. Um unico override, e so' por causa do log
# driver: `logging.options` muda de CHAVE conforme o driver, e interpolacao nao
# torna chave condicional -- com json-file, `fluentd-address` e' opcao invalida.
compose_app() {
    [ -f "$ENV_EFETIVO" ] || gerar_env
    printf '%s\n' --env-file "$ENV_EFETIVO" \
        -f "$BASE_APP/$COMPOSE_APP" \
        -f "$BASE_APP/docker-compose-logs-fluentd.yml"
}

# Reescreve uma variavel no lab2.env e regenera o efetivo.
definir_env() {
    local chave="$1" valor="$2"
    if grep -qE "^${chave}=" "$ENV_LAB2"; then
        python3 - "$ENV_LAB2" "$chave" "$valor" <<'PYEOF'
import sys, re
arq, chave, valor = sys.argv[1], sys.argv[2], sys.argv[3]
linhas = open(arq, encoding="utf-8").read().splitlines(keepends=True)
saida = [re.sub(rf"^{re.escape(chave)}=.*$", f"{chave}={valor}", l.rstrip("\n")) + "\n"
         if l.startswith(chave + "=") else l for l in linhas]
open(arq, "w", encoding="utf-8").writelines(saida)
PYEOF
    else
        printf '%s=%s\n' "$chave" "$valor" >> "$ENV_LAB2"
    fi
    gerar_env
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
