#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- sobe TUDO, na ordem certa
# =============================================================================
#   bash run-lab.sh                 baixa, constroi, sobe aplicacao + stack + guia
#   bash run-lab.sh --build         forca construir localmente
#   bash run-lab.sh --pull          so' baixa; falha se nao conseguir
#   bash run-lab.sh --sem-build     nao mexe nas imagens (ja existem)
#   bash run-lab.sh --com-carga     ja deixa a carga rodando ao final
#   bash run-lab.sh --sem-guia      nao sobe a pagina do aluno
#
# Existe porque a ordem importa e errar a ordem da erro: a aplicacao precisa
# subir ANTES do stack (e' ela que cria a rede em que o collector entra), e o
# MongoDB precisa existir antes da aplicacao.
#
# NAO mexe no splunk-otel-collector. Os dois convivem: o collector deste lab
# nao publica 4317/4318 no host.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_APP="${REPO_APP:-https://github.com/tonanuvem/bank-demo.git}"
# dashboard, accounts, transactions, loan, customer-auth, atm-locator, ui
TOTAL_IMAGENS=7
MODO_IMAGENS=auto      # auto = tenta baixar, constroi se falhar
SUBIR_GUIA=true
COM_CARGA=false

TEST_EMAIL="teste@teste.com"
TEST_PASSWORD="Teste@123"

for ARG in "$@"; do
    case "$ARG" in
        --sem-build) MODO_IMAGENS=nenhum ;;
        --build)     MODO_IMAGENS=build ;;
        --pull)      MODO_IMAGENS=pull ;;
        --sem-guia)  SUBIR_GUIA=false ;;
        --com-carga) COM_CARGA=true ;;
        -h|--help)   sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) erro "opcao desconhecida: $ARG"; exit 1 ;;
    esac
done

titulo "LAB GRAFANA -- SUBINDO O AMBIENTE COMPLETO"

# ---------------------------------------------------------------- 1. docker
echo
echo "1. PRE-REQUISITOS"
echo "--------------------------------------------------"
command -v docker >/dev/null 2>&1 || { erro "Docker nao encontrado."; exit 1; }
docker info >/dev/null 2>&1      || { erro "Docker instalado, mas o daemon nao responde."; exit 1; }
command -v git    >/dev/null 2>&1 || { erro "git nao encontrado."; exit 1; }
ok "docker e git"

LIVRE=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')
if [ -n "$LIVRE" ] && [ "$LIVRE" -lt 8 ]; then
    aviso "so' ${LIVRE}GB livres em $HOME -- as imagens ocupam cerca de 6GB"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet splunk-otel-collector 2>/dev/null; then
    ok "splunk-otel-collector ativo -- sera' preservado (nao ha conflito de porta)"
fi

# ------------------------------------------------------------- 2. mongodb
echo
echo "2. MONGODB"
echo "--------------------------------------------------"
# A variante bridge aponta para host.docker.internal:27017, entao o Mongo e'
# um container separado, com volume proprio -- o mesmo do encontro anterior.
if docker ps --format '{{.Names}}' | grep -qx fiap-mongodb; then
    ok "fiap-mongodb no ar"
elif docker ps -a --format '{{.Names}}' | grep -qx fiap-mongodb; then
    docker start fiap-mongodb >/dev/null && ok "fiap-mongodb reiniciado"
else
    echo "   criando (o volume fiap-mongodb-data e' preservado entre execucoes)"
    docker run -d --name fiap-mongodb --restart unless-stopped \
        -p 27017:27017 -v fiap-mongodb-data:/data/db mongo:7 >/dev/null \
        && ok "fiap-mongodb criado" || { erro "nao subiu"; exit 1; }
fi

# --------------------------------------------------------- 3. repo da app
echo
echo "3. APLICACAO (bank-demo)"
echo "--------------------------------------------------"
if [ -d "$BASE_APP/.git" ]; then
    if git -C "$BASE_APP" pull --ff-only origin main >/dev/null 2>&1; then
        ok "atualizado: $BASE_APP"
    else
        aviso "nao consegui atualizar $BASE_APP (mudancas locais?) -- seguindo com o que existe"
        echo "       Se o lab se comportar diferente do esperado, e' o primeiro lugar a olhar."
    fi
else
    echo "   clonando $REPO_APP"
    git clone -q "$REPO_APP" "$BASE_APP" && ok "clonado em $BASE_APP" \
        || { erro "falha ao clonar"; exit 1; }
fi

# -------------------------------------------------------------- 4. build
if [ "$MODO_IMAGENS" = "auto" ] || [ "$MODO_IMAGENS" = "pull" ]; then
    echo
    echo "4. BAIXANDO AS IMAGENS"
    echo "--------------------------------------------------"
    echo "   Publicadas em tonanuvem/fiap-bank-*. Baixar leva ~3 min contra"
    echo "   10-20 do build -- e nao depende do PyPI nem do npm estarem de pe'."
    if (cd "$BASE_APP" && docker compose -f "$COMPOSE_APP" pull --quiet) >/tmp/lab-pull.log 2>&1; then
        ok "imagens baixadas"
        MODO_IMAGENS=nenhum
    elif [ "$MODO_IMAGENS" = "pull" ]; then
        erro "nao consegui baixar as imagens:"
        tail -6 /tmp/lab-pull.log | sed 's/^/       /'
        exit 1
    else
        aviso "nao consegui baixar -- vou construir localmente"
        echo "       Motivo provavel: limite de pulls do Docker Hub, tag ausente"
        echo "       ou arquitetura diferente. Detalhes em /tmp/lab-pull.log"
        MODO_IMAGENS=build
    fi
fi

if [ "$MODO_IMAGENS" = "build" ]; then
    echo
    echo "4b. CONSTRUINDO AS IMAGENS"
    echo "--------------------------------------------------"
    echo "   Sao $TOTAL_IMAGENS imagens com versoes fixas. Na primeira vez leva 10-20 min;"
    echo "   depois o cache resolve em segundos."
    echo

    # O build corre em segundo plano e o progresso sai daqui. Sem isto a tela
    # fica parada por 20 minutos e parece travada -- em sala, alguem sempre
    # interrompe achando que morreu.
    #
    # --progress plain porque o formato padrao redesenha a tela com codigos de
    # terminal e nao da' para ler linha a linha.
    ( cd "$BASE_APP" && docker compose -f "$COMPOSE_APP" build --progress plain ) \
        >/tmp/lab-build.log 2>&1 &
    BUILD_PID=$!

    INICIO=$(date +%s)
    CHEIO="################################"
    VAZIO="                                "

    while kill -0 "$BUILD_PID" 2>/dev/null; do
        # Uma imagem pronta produz "naming to docker.io/library/<imagem>".
        # `grep -c` JA imprime 0 quando nao acha, e ainda sai com codigo 1 --
        # um "|| echo 0" aqui produz "0\n0" e quebra a aritmetica logo abaixo.
        PRONTAS=$(grep -c "naming to " /tmp/lab-build.log 2>/dev/null); PRONTAS=${PRONTAS:-0}

        # A ultima etapa vista: "#42 [transactions 5/8]". O buildkit constroi
        # em paralelo, entao e' a ULTIMA e nao "a atual" -- e' honesto assim.
        ETAPA=$(grep -oE '^#[0-9]+ \[[a-z][a-z0-9-]* [0-9]+/[0-9]+\]' /tmp/lab-build.log 2>/dev/null \
                | tail -1 | sed -E 's/^#[0-9]+ \[([a-z0-9-]+) ([0-9]+)\/([0-9]+)\]/\1 \2\/\3/')

        PASSO_PCT=0
        if [ -n "$ETAPA" ]; then
            N=$(echo "$ETAPA" | awk '{print $2}' | cut -d/ -f1)
            D=$(echo "$ETAPA" | awk '{print $2}' | cut -d/ -f2)
            [ -n "$D" ] && [ "$D" -gt 0 ] 2>/dev/null && PASSO_PCT=$(( N * 100 / D ))
        fi

        PCT=$(( (PRONTAS * 100 + PASSO_PCT) / TOTAL_IMAGENS ))
        [ "$PCT" -gt 99 ] && PCT=99
        DECOR=$(( $(date +%s) - INICIO ))

        if [ -t 1 ]; then
            NB=$(( PCT * 32 / 100 ))
            printf '\r   [%s%s] %3d%%  %d/%d imagens  %-26s %dm%02ds ' \
                   "${CHEIO:0:$NB}" "${VAZIO:0:$(( 32 - NB ))}" "$PCT" \
                   "$PRONTAS" "$TOTAL_IMAGENS" "${ETAPA:-preparando}" \
                   $(( DECOR / 60 )) $(( DECOR % 60 ))
            sleep 2
        else
            # Fora de um terminal o \r viraria lixo no arquivo de log.
            echo "   ${PCT}% - ${PRONTAS}/${TOTAL_IMAGENS} imagens - ${ETAPA:-preparando} - $(( DECOR / 60 ))min"
            sleep 30
        fi
    done

    wait "$BUILD_PID"; RC=$?
    [ -t 1 ] && printf '\r%-90s\r' " "

    if [ "$RC" -eq 0 ]; then
        DECOR=$(( $(date +%s) - INICIO ))
        ok "$TOTAL_IMAGENS imagens construidas em $(( DECOR / 60 ))m$(( DECOR % 60 ))s"
    else
        erro "o build falhou. Ultimas linhas:"
        tail -12 /tmp/lab-build.log | sed 's/^/       /'
        echo "       Log completo em /tmp/lab-build.log"
        exit 1
    fi
fi

# ------------------------------------------------------- 5. subir a app
echo
echo "5. SUBINDO A APLICACAO"
echo "--------------------------------------------------"
# Sobe JA' com o env do lab -- inclusive a porta do dashboard, decidida acima.
# Descobrir o conflito de porta depois nao adianta: o `up` ja' falhou.
#
# As aplicacoes vao apontar para otelcol:4317, que ainda nao existe. E' inofensivo:
# o exportador OTel tenta, falha e repete ate o collector subir no passo 6.
ajustar_porta_dashboard
FS=(); while IFS= read -r linha; do FS+=("$linha"); done < <(compose_app)
if (cd "$BASE_APP" && docker compose "${FS[@]}" up -d) >/tmp/lab-up.log 2>&1; then
    ok "aplicacao no ar"
else
    erro "falha ao subir a aplicacao:"
    tail -8 /tmp/lab-up.log | sed 's/^/       /'
    exit 1
fi

# ------------------------------------------------------------ 6. o stack
echo
echo "6. STACK DE OBSERVABILIDADE"
echo "--------------------------------------------------"
bash "$AQUI/run-stack.sh" || { erro "o run-stack.sh falhou"; exit 1; }

# -------------------------------------------------------------- 7. guia
if [ "$SUBIR_GUIA" = "true" ]; then
    echo
    echo "7. GUIA DO ALUNO"
    echo "--------------------------------------------------"
    bash "$AQUI/app/guia.sh" >/dev/null 2>&1 && ok "guia no ar" || aviso "o guia nao subiu (siga sem ele)"
fi

# ------------------------------------------------------------- 8. carga
if [ "$COM_CARGA" = "true" ]; then
    echo
    echo "8. CARGA"
    echo "--------------------------------------------------"
    bash "$AQUI/carga.sh" --fundo --cenario transaction --usuarios 10 --duracao 120m
fi


# ------------------------------------------------------- usuario de teste
# As credenciais sao ANUNCIADAS no fim do script, entao elas precisam existir
# de verdade -- exibir um login que nao funciona e' pior que nao exibir nada.
# Criamos aqui (idempotente: se ja' existir, o customer-auth devolve 400 e
# seguimos) e CONFERIMOS com um login antes de imprimir.
criar_usuario_teste() {
    local i=0
    until curl -s -o /dev/null --max-time 3 "http://localhost:8000/api/users/auth" \
              -X POST -H 'Content-Type: application/json' -d '{}' 2>/dev/null || [ $i -ge 20 ]; do
        i=$((i+1)); sleep 2
    done

    curl -s -o /dev/null --max-time 10 -X POST "http://localhost:8000/api/users" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"Aluno Teste\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>/dev/null

    # A confirmacao e' um login de verdade, nao o codigo do cadastro: se o
    # usuario ja' existia, o cadastro devolve 400 e nao diz nada sobre a senha.
    local codigo
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "http://localhost:8000/api/users/auth" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>/dev/null)
    [ "$codigo" = "200" ]
}

echo
echo "9. USUARIO DE TESTE"
echo "--------------------------------------------------"
if criar_usuario_teste; then
    ok "$TEST_EMAIL pronto (login conferido)"
    LOGIN_OK=true
else
    aviso "nao consegui deixar o login de teste funcionando"
    echo "       O banco sobe do mesmo jeito -- crie uma conta pela tela"
    echo "       'Abra sua conta'. Para investigar:"
    echo "         docker logs fiapbank-otel-hg-customer-auth-1 --tail 20"
    LOGIN_OK=false
fi

# ------------------------------------------------------------- resumo
IP=$(curl -s --max-time 4 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
H="${IP:-localhost}"
PORTA_DASH=$(grep -E '^PORTA_DASHBOARD=' "$ENV_EFETIVO" 2>/dev/null | tail -1 | cut -d= -f2)

#titulo "PRONTO"
echo
echo "=================================================="
echo " BANK INICIADO (MICROSERVICES)"
echo "=================================================="
echo
echo "  Banco          http://$H:3000"
echo
if [ "${LOGIN_OK:-false}" = "true" ]; then
    echo "LOGIN DE TESTE:"
    echo
    echo "Email: $TEST_EMAIL"
    echo "Senha: $TEST_PASSWORD"
else
    echo "LOGIN DE TESTE: indisponivel -- use 'Abra sua conta' na tela"
fi
echo
# echo "  Guia do aluno  http://$H:8031"
echo
echo "=================================================="
echo " GRAFANA INICIADO (OBSERVABILIDADE)"
echo "=================================================="
echo
echo "  Grafana        http://$H:3001"
echo "  Prometheus     http://$H:9090"
echo "  Alertmanager   http://$H:9093"
echo
[ -n "$PORTA_DASH" ] && [ "$PORTA_DASH" != "5000" ] && echo "  Dashboard/BFF  http://$H:$PORTA_DASH  (5000 estava ocupada)"
echo
if [ "$COM_CARGA" != "true" ]; then
    echo "  Sem carga os paineis ficam vazios. Comece por:"
    echo "    bash carga.sh --fundo --cenario transaction --usuarios 10 --duracao 120m"
    echo
fi
#[ -n "$IP" ] && echo "  Libere no Security Group: 3000, 3001, 5000, 8000, 8001, 8027, 8031, 8080, 9090, 9093" && \
#                echo "  A 8027 e' a do RUM -- sem ela a pagina funciona e o RUM fica mudo, sem erro." && echo
# echo "  Para derrubar tudo:  bash remove-lab.sh"
echo
