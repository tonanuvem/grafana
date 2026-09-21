# Funcoes comuns aos scripts do LAB GRAFANA. Sempre com `source`.
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$AQUI/stack"
PROJETO="fiapbank-obs"
BASE_APP="${BASE_APP:-$HOME/bank-demo-docker}"
COMPOSE_APP="docker-compose-network-docker-internal.yml"
PROM="${PROM:-http://localhost:9090}"
PUSH="${PUSH:-http://localhost:9091}"

ok()    { echo "  [OK] $1"; }
aviso() { echo "  [!]  $1"; }
erro()  { echo "  [ERRO] $1"; }
titulo(){ echo; echo "=================================================="; echo " $1"; echo "=================================================="; }

ENV_LAB="$AQUI/env/grafana.env"
ENV_EFETIVO="$AQUI/env/.env-efetivo"

# Tudo o que o lab PRODUZ (historico de deploys, decisoes, rascunhos de
# comunicacao, log da carga) fica aqui, separado do que ele CONFIGURA.
# Criado na hora: diretorio vazio nao sobrevive a um git clone.
ESTADO="$AQUI/estado"
mkdir -p "$ESTADO"

# Tudo o que muda ao RODAR o lab -- a versao publicada, a regressao simulada,
# a porta que sobrou livre nesta maquina, o IP que o navegador alcanca -- mora
# aqui, e nao no arquivo versionado. Senao rodar a aula deixa o repositorio
# sujo, e o `git pull` seguinte traz conflito num arquivo de configuracao.
ENV_ESTADO="$ESTADO/ambiente.env"
if [ ! -f "$ENV_ESTADO" ]; then
    cat > "$ENV_ESTADO" <<'PADRAO'
# ARQUIVO GERADO -- estado desta execucao. Nao versionar.
# Use ./deploy.sh e ./run-stack.sh; editar isto a mao nao recria container.
APP_VERSION=1.0.0
ATRASO_ARTIFICIAL_MS=0
ATRASO_JITTER_MS=0
FALHA_ARTIFICIAL_PCT=0
PADRAO
fi

# Funde o .env que ja existir no bank-demo com o do LAB GRAFANA (o nosso por cima).
#
# Por que fundir e nao so' apontar: `--env-file` SUBSTITUI o .env padrao, nao
# soma. Na EC2 do Encontro 1 existe um .env com realm e token do Splunk --
# apontar direto para o nosso descartaria aqueles valores em silencio.
gerar_env() {
    {
        echo "# ARQUIVO GERADO por run-stack.sh -- nao edite, nao versione."
        echo "# Fonte: $BASE_APP/.env (se existir) + env/grafana.env por cima."
        [ -f "$BASE_APP/.env" ] && grep -vE '^\s*(#|$)' "$BASE_APP/.env"
        grep -vE '^\s*(#|$)' "$ENV_LAB"
        # por ultimo: o estado desta execucao vence a configuracao
        grep -vE '^\s*(#|$)' "$ENV_ESTADO"
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

# Reescreve uma variavel e regenera o efetivo. O terceiro argumento escolhe o
# arquivo: "deploy" para o estado, qualquer outra coisa para a configuracao.
definir_env() {
    local chave="$1" valor="$2" onde="${3:-estado}"

    # O padrao e' o ESTADO: quase tudo o que os scripts mudam e' consequencia
    # de rodar o lab NESTA maquina -- a versao publicada, a regressao, a porta
    # que sobrou livre, o IP que o navegador alcanca. Nada disso pertence a um
    # arquivo versionado: senao dar aula deixa o repositorio sujo e o `git
    # pull` seguinte vira conflito.
    #
    # Passe "config" como terceiro argumento para gravar no env/grafana.env.
    local arquivo="$ENV_ESTADO"
    [ "$onde" = "config" ] && arquivo="$AQUI/env/grafana.env"

    if grep -qE "^${chave}=" "$arquivo"; then
        python3 - "$arquivo" "$chave" "$valor" <<'PYEOF'
import sys, re
arq, chave, valor = sys.argv[1], sys.argv[2], sys.argv[3]
linhas = open(arq, encoding="utf-8").read().splitlines(keepends=True)
saida = [re.sub(rf"^{re.escape(chave)}=.*$", f"{chave}={valor}", l.rstrip("\n")) + "\n"
         if l.startswith(chave + "=") else l for l in linhas]
open(arq, "w", encoding="utf-8").writelines(saida)
PYEOF
    else
        printf '%s=%s\n' "$chave" "$valor" >> "$arquivo"
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

# A porta 5000 e' disputada em algumas maquinas (no macOS, pelo AirPlay
# Receiver). Precisa ser decidida ANTES de a aplicacao subir -- descobrir
# depois nao adianta: o `up` ja' falhou com "address already in use".
# Idempotente: quem chamar primeiro decide, os outros so' confirmam.
ajustar_porta_dashboard() {
    local livre=true
    if ss -lnt 2>/dev/null | grep -q ":5000 " || lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1; then
        docker ps --format '{{.Names}} {{.Ports}}' | grep -q ":5000->" || livre=false
    fi
    if [ "$livre" = "false" ]; then
        if ! grep -qE '^PORTA_DASHBOARD=' "$ENV_ESTADO" 2>/dev/null; then
            aviso "porta 5000 ocupada por outro processo -- usando ${PORTA_DASHBOARD:-5050}"
        fi
        definir_env PORTA_DASHBOARD "${PORTA_DASHBOARD:-5050}"
    fi
}

exige_stack() {
    curl -sf "$PROM/-/ready" >/dev/null 2>&1 || {
        erro "o stack do LAB GRAFANA nao esta no ar."
        echo "       Suba antes:  bash $AQUI/run-stack.sh"
        exit 1
    }
}
