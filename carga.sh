#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- gerador de carga (locust)
# =============================================================================
#   ./carga.sh                                todos os cenarios, 5 usuarios, 60s cada
#   ./carga.sh --cenario transaction          so' a jornada de transferencia
#   ./carga.sh --cenario extrato              so' a consulta de extrato
#   ./carga.sh --cenario auth --usuarios 20   mais carga na autenticacao
#   ./carga.sh --cenario auth --falhas        toda tentativa erra a senha
#   ./carga.sh --cenario transaction --falhas transferencias acima do saldo
#   ./carga.sh --cenario loan --falhas        credito negado
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

# Uma lista so': a estimativa de duracao conta daqui, e o laco percorre daqui.
# Duplicar a lista seria garantir que um dia elas divergissem.
CENARIOS="auth account transaction extrato loan atm"

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
        -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) erro "opcao desconhecida: $1"; exit 1 ;;
    esac
done

case "$FALHAS" in
    ''|*[!0-9]*) erro "--falhas espera um numero de 0 a 100 (recebido: '$FALHAS')"; exit 1 ;;
esac
[ "$FALHAS" -gt 100 ] && { erro "--falhas nao pode passar de 100"; exit 1; }

# --falhas age em todo cenario que tenha uma recusa de NEGOCIO, e cada uma e'
# de natureza diferente -- e' esse contraste que o dashboard 1 mostra:
#   auth        -> senha errada .................. HTTP 400, metrica E log
#   transaction -> acima do saldo ................ HTTP 200, so' log
#   loan        -> valor menor que 1, recusado ... HTTP 200, so' log
#   account     -> conta do tipo ja' existe ...... HTTP 200, so' log
#   atm         -> caixa inexistente ............. HTTP 404, metrica E log
#
# `extrato` fica de fora porque nao tem "nao" de negocio: consultar extrato ou
# funciona ou e' erro tecnico. O SLI dele e' latencia, nao recusa.
if [ "$FALHAS" -gt 0 ] && [ "$CENARIO" = "extrato" ]; then
    aviso "--falhas nao age em 'extrato': o SLI dessa jornada e' latencia."
fi

# `--build` SEMPRE, e nao so' quando o container esta fora do ar.
#
# Os cenarios vivem DENTRO da imagem (`COPY . /service/`), e a imagem do locust
# nao e' publicada: ela nasce local. Sem o --build, um `git pull` que traz
# cenario novo nao chega a lugar nenhum -- o container antigo continua de pe'
# rodando o codigo antigo, e o resultado e' o pior tipo de erro: numeros
# plausiveis e silenciosamente errados. Foi assim que `--falhas` devolveu
# "0 falhas" com 100% pedido, porque a imagem ainda lia a variavel com o nome
# anterior.
#
# Com cache o build leva segundos; so' refaz a camada quando um .py mudou.
echo "Preparando o container do locust (profile 'load')..."
(cd "$BASE_APP" && docker compose -f "$COMPOSE_APP" --profile load up -d --build locust) \
    >/tmp/lab-locust.log 2>&1 \
    || { erro "falha ao preparar o locust -- veja /tmp/lab-locust.log"; exit 1; }
sleep 3
CT=$(docker ps --format '{{.Names}}' | grep -E 'otel-hg-locust' | head -1)
[ -z "$CT" ] && { erro "o container do locust nao subiu -- veja /tmp/lab-locust.log"; exit 1; }

# Na variante bridge os destinos sao os NOMES dos servicos, resolvidos pelo
# DNS interno do Docker -- nao localhost.
ENVS=(
  -e VITE_ACCOUNTS_URL=http://dashboard:5000/account
  -e VITE_USERS_URL=http://customer-auth:8000/api/users
  -e VITE_ATM_URL=http://atm-locator:8001/api/atm
  -e VITE_TRANSFER_URL=http://dashboard:5000/transaction
  -e VITE_LOAN_URL=http://dashboard:5000/loan
  -e FALHA_PCT="$FALHAS"
)

converter() { case "$1" in *h) echo $(( ${1%h} * 3600 ));; *m) echo $(( ${1%m} * 60 ));; *s) echo "${1%s}";; *) echo "$1";; esac; }

# Estimativa em minutos e segundos. Sao ~3s de partida do locust por cenario,
# mais ~6s de preparacao do container -- MEDIDOS: um cenario de 10s leva 19s no
# total, um de 20s leva 27s.
estimativa() {
    local n=1
    [ "$CENARIO" = "todos" ] && n=$(echo $CENARIOS | wc -w)
    local seg=$(( n * ($(converter "$TEMPO") + 3) + 6 ))
    if [ -n "$DURACAO" ]; then
        echo "~$(( $(converter "$DURACAO") / 60 ))min (repete ate completar)"
    elif [ "$seg" -lt 60 ]; then
        echo "~${seg}s"
    else
        echo "~$(( seg / 60 ))min$(( seg % 60 ))s"
    fi
}

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

laco() {
    local fim=""
    [ -n "$DURACAO" ] && fim=$(( $(date +%s) + $(converter "$DURACAO") ))
    while true; do
        if [ "$CENARIO" = "todos" ]; then
            for c in $CENARIOS; do
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
    ok "carga rodando em segundo plano (pid $(cat "$PIDF")) · $(estimativa)"
    echo "     acompanhar:  tail -f $LOG"
    echo "     encerrar:    ./carga.sh --parar"
    exit 0
fi

TITULO_FALHAS=""
[ "$FALHAS" -gt 0 ] && TITULO_FALHAS=" · ${FALHAS}% com falha"
titulo "CARGA -- cenario: $CENARIO · $USUARIOS usuarios${TITULO_FALHAS}"
if [ "$CENARIO" = "todos" ]; then
    echo "  $(echo $CENARIOS | wc -w | tr -d ' ') cenarios de $TEMPO cada · duracao total $(estimativa)"
else
    echo "  $TEMPO de carga · duracao total $(estimativa)"
fi
echo
laco
echo
ok "carga concluida"
