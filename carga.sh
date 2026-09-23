#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- gerador de carga (locust)
# =============================================================================
#   ./carga.sh                                todos os cenarios, 5 usuarios, 60s cada
#   ./carga.sh --cenario transaction          so' a jornada de transferencia
#   ./carga.sh --cenario extrato              so' a consulta de extrato
#   ./carga.sh --cenario auth --usuarios 20   mais carga na autenticacao
#   ./carga.sh --cenario auth --falhas        toda tentativa erra a senha antes
#   ./carga.sh --cenario auth --falhas 35     ou o percentual que quiser
#   ./carga.sh --duracao 20m                  repete ate completar 20 min
#   ./carga.sh --parar                        encerra a carga em segundo plano
#   ./carga.sh --fundo --duracao 60m          roda em segundo plano
#
# SEM CARGA OS PAINEIS FICAM VAZIOS. As metricas do lab nascem dos traces:
# sem requisicao nao ha trace, sem trace nao ha metrica. E a deteccao de
# padroes de log do Loki so' funciona com volume (com ~50 linhas ela acha
# zero padroes; com ~950 achou tres).
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USUARIOS=5
TEMPO="60s"
CENARIO="todos"
FALHAS=0
DURACAO=""
FUNDO=false
LOG="$ESTADO/.carga.log"
PIDF="$ESTADO/.carga.pid"

# Sob `set -u`, uma opcao sem valor abortava com "$2: unbound variable" -- erro
# cru do bash, que nem diz qual opcao faltou. E `--falhas --usuarios 10` engolia
# "--usuarios" como se fosse o percentual, para so' depois reclamar do "10".
exige_valor() {
    case "${2-}" in
        ""|--*) erro "a opcao $1 espera um valor."; exit 1 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --usuarios) exige_valor "$1" "${2-}"; USUARIOS="$2"; shift 2 ;;
        --tempo)    exige_valor "$1" "${2-}"; TEMPO="$2";    shift 2 ;;
        --cenario)  exige_valor "$1" "${2-}"; CENARIO="$2";  shift 2 ;;
        --duracao)  exige_valor "$1" "${2-}"; DURACAO="$2";  shift 2 ;;
        # O valor e' OPCIONAL: `--falhas` sozinho e' a forma que as pessoas
        # tentam primeiro, e faze-la falhar nao ensina nada. Sem valor vai a
        # 100 -- quem digita so' `--falhas` quer ver o sinal aparecer, nao
        # calibrar percentual.
        --falhas)
            case "${2-}" in
                ""|--*) FALHAS=100;    shift   ;;
                *)      FALHAS="$2";   shift 2 ;;
            esac ;;
        --fundo)    FUNDO=true;    shift ;;
        --parar)
            if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
                kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; ok "carga encerrada"
            else
                aviso "nao ha carga em segundo plano"
            fi
            exit 0 ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) erro "opcao desconhecida: $1"; exit 1 ;;
    esac
done

case "$FALHAS" in
    ''|*[!0-9]*) erro "--falhas espera um numero de 0 a 100 (recebido: '$FALHAS')"; exit 1 ;;
esac
[ "$FALHAS" -gt 100 ] && { erro "--falhas nao pode passar de 100"; exit 1; }

# --falhas so' tem efeito no cenario de autenticacao: e' o unico que tem uma
# senha para errar. Avisar e' melhor do que aceitar em silencio -- caso
# contrario o aluno roda `--cenario atm --falhas 30`, nao ve recusa nenhuma e
# conclui que o lab esta quebrado.
if [ "$FALHAS" -gt 0 ] && [ "$CENARIO" != "auth" ] && [ "$CENARIO" != "todos" ]; then
    aviso "--falhas so' age no cenario 'auth'; em '$CENARIO' sera' ignorado."
fi

CT=$(docker ps --format '{{.Names}}' | grep -E 'otel-hg-locust' | head -1)
if [ -z "$CT" ]; then
    echo "Subindo o container do locust (profile 'load')..."
    (cd "$BASE_APP" && docker compose -f "$COMPOSE_APP" --profile load up -d locust) >/dev/null 2>&1
    sleep 4
    CT=$(docker ps --format '{{.Names}}' | grep -E 'otel-hg-locust' | head -1)
    [ -z "$CT" ] && { erro "o container do locust nao subiu."; exit 1; }
fi

# Na variante bridge os destinos sao os NOMES dos servicos, resolvidos pelo
# DNS interno do Docker -- nao localhost.
ENVS=(
  -e VITE_ACCOUNTS_URL=http://dashboard:5000/account
  -e VITE_USERS_URL=http://customer-auth:8000/api/users
  -e VITE_ATM_URL=http://atm-locator:8001/api/atm
  -e VITE_TRANSFER_URL=http://dashboard:5000/transaction
  -e VITE_LOAN_URL=http://dashboard:5000/loan
  -e FALHA_LOGIN_PCT="$FALHAS"
)

arquivo_do_cenario() {
    case "$1" in
        auth)        echo "auth_locust.py" ;;
        account)     echo "account_locust.py" ;;
        transaction) echo "transaction_locust.py" ;;
        loan)        echo "loan_locust.py" ;;
        extrato)     echo "extrato_locust.py" ;;
        atm)         echo "atm_locust.py" ;;
        *) echo "" ;;
    esac
}

rodar_um() {
    local arq="$1"
    docker exec "${ENVS[@]}" "$CT" \
        locust -f "/service/$arq" --headless -u "$USUARIOS" -r 1 \
               --run-time "$TEMPO" --only-summary 2>&1 \
    | grep -E "^[[:space:]]*Aggregated" | head -1 \
    | awk '{printf "   %s req · %s falhas · %s req/s · med %sms\n", $2, $3, $10, $8}'
}

converter() { case "$1" in *h) echo $(( ${1%h} * 3600 ));; *m) echo $(( ${1%m} * 60 ));; *s) echo "${1%s}";; *) echo "$1";; esac; }

laco() {
    local fim=""
    [ -n "$DURACAO" ] && fim=$(( $(date +%s) + $(converter "$DURACAO") ))
    while true; do
        if [ "$CENARIO" = "todos" ]; then
            for c in auth account transaction extrato loan atm; do
                echo "  [$c]"; rodar_um "$(arquivo_do_cenario "$c")"
                [ -n "$fim" ] && [ "$(date +%s)" -ge "$fim" ] && return 0
            done
        else
            local arq; arq=$(arquivo_do_cenario "$CENARIO")
            [ -z "$arq" ] && { erro "cenario invalido: $CENARIO"; exit 1; }
            echo "  [$CENARIO]"; rodar_um "$arq"
        fi
        [ -z "$fim" ] && return 0
        [ "$(date +%s)" -ge "$fim" ] && return 0
    done
}

if [ "$FUNDO" = "true" ]; then
    : > "$LOG"
    laco >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
    ok "carga rodando em segundo plano (pid $(cat "$PIDF"))"
    echo "     acompanhar:  tail -f $LOG"
    echo "     encerrar:    ./carga.sh --parar"
    exit 0
fi

TITULO_FALHAS=""
[ "$FALHAS" -gt 0 ] && TITULO_FALHAS=" · ${FALHAS}% de logins recusados"
titulo "CARGA -- cenario: $CENARIO · $USUARIOS usuarios${TITULO_FALHAS}"
laco
echo
ok "carga concluida"
