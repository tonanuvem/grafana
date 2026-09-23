#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- tira tudo do ar
# =============================================================================
#   bash remove-lab.sh              para tudo (preserva dados e imagens)
#   bash remove-lab.sh --dados      remove tambem os volumes  (APAGA os dados)
#   bash remove-lab.sh --imagens    remove tambem as imagens  (o proximo start rebuilda)
#   bash remove-lab.sh --tudo       as duas coisas
#
# NAO mexe no splunk-otel-collector nem no que e' do encontro do Splunk: este
# script so' desfaz o que o run-lab.sh fez.
#
# O padrao e' conservador de proposito. --dados apaga contas e transacoes, e
# --imagens custa 10-20 min de rebuild na proxima vez -- os dois pedem
# confirmacao.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMOVER_DADOS=false
REMOVER_IMAGENS=false

for ARG in "$@"; do
    case "$ARG" in
        --dados)   REMOVER_DADOS=true ;;
        --imagens) REMOVER_IMAGENS=true ;;
        --tudo)    REMOVER_DADOS=true; REMOVER_IMAGENS=true ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) erro "opcao desconhecida: $ARG"; exit 1 ;;
    esac
done

titulo "LAB GRAFANA -- REMOVENDO"

if [ "$REMOVER_DADOS" = "true" ] || [ "$REMOVER_IMAGENS" = "true" ]; then
    echo
    [ "$REMOVER_DADOS"   = "true" ] && echo "  + APAGA os dados: contas, transacoes, metricas, logs e traces"
    [ "$REMOVER_IMAGENS" = "true" ] && echo "  + remove as imagens (proximo start: 10-20 min de rebuild)"
    echo
    printf "  Confirma? [s/N] "
    read -r RESP
    case "$RESP" in
        s|S|sim|SIM) : ;;
        *) echo "  cancelado."; exit 0 ;;
    esac
fi

# ---------------------------------------------------------------- 1. carga
echo
echo "1. CARGA"
echo "--------------------------------------------------"
bash "$AQUI/carga.sh" --parar 2>/dev/null | sed 's/^/  /' || true

# ----------------------------------------------------------------- 2. guia
echo
echo "2. GUIA DO ALUNO"
echo "--------------------------------------------------"
if docker ps -a --format '{{.Names}}' | grep -qx fiap-lab-guia; then
    docker rm -f fiap-lab-guia >/dev/null 2>&1 && ok "guia removido"
else
    echo "  [INFO] nao estava no ar"
fi

# ---------------------------------------------------------------- 3. stack
echo
echo "3. STACK DE OBSERVABILIDADE"
echo "--------------------------------------------------"
if [ "$REMOVER_DADOS" = "true" ]; then
    docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" --profile containers down -v >/dev/null 2>&1 \
        && ok "stack removido, volumes apagados"
else
    docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" --profile containers down >/dev/null 2>&1 \
        && ok "stack parado, volumes preservados"
fi

# ----------------------------------------------------------- 4. aplicacao
echo
echo "4. APLICACAO (bank-demo)"
echo "--------------------------------------------------"
if [ -f "$BASE_APP/$COMPOSE_APP" ]; then
    FS=(); while IFS= read -r linha; do FS+=("$linha"); done < <(compose_app)
    (cd "$BASE_APP" && docker compose "${FS[@]}" --profile load down --remove-orphans) >/dev/null 2>&1 \
        && ok "aplicacao parada"
else
    aviso "$BASE_APP/$COMPOSE_APP nao encontrado -- removendo por nome"
    docker ps -a --format '{{.Names}}' | grep -E '^fiapbank-otel-hg-' \
        | xargs -r docker rm -f >/dev/null 2>&1 && ok "containers removidos"
fi

# ------------------------------------------------------------- 5. mongodb
echo
echo "5. MONGODB"
echo "--------------------------------------------------"
if [ "$REMOVER_DADOS" = "true" ]; then
    docker rm -f fiap-mongodb >/dev/null 2>&1
    docker volume rm fiap-mongodb-data >/dev/null 2>&1
    ok "fiap-mongodb e seus dados removidos"
else
    # Preservado de proposito: e' compartilhado com o encontro do Splunk, e
    # derrubar aqui quebraria o outro laboratorio sem aviso.
    echo "  [INFO] fiap-mongodb preservado (compartilhado com o outro lab)"
    echo "         Use --dados para remove-lo junto com as contas e transacoes."
fi

# ------------------------------------------------------------- 6. imagens
if [ "$REMOVER_IMAGENS" = "true" ]; then
    echo
    echo "6. IMAGENS"
    echo "--------------------------------------------------"
    QTD=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -cE '^fiap-bank|^fiap-lab-guia' || true)
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^fiap-bank|^fiap-lab-guia' \
        | xargs -r docker rmi >/dev/null 2>&1
    ok "${QTD:-0} imagem(ns) da aplicacao removida(s)"
    echo "  [INFO] as imagens do stack (grafana, loki, tempo...) foram mantidas:"
    echo "         sao publicas e baixar de novo custa mais que guardar."
fi

# -------------------------------------------------------------- 7. estado
echo
echo "7. ESTADO DA EXECUCAO"
echo "--------------------------------------------------"
rm -f "$ENV_EFETIVO" "$ENV_ESTADO"
ok "estado/ambiente.env e env/.env-efetivo removidos"
echo "  [INFO] o historico de deploys, as decisoes e os rascunhos de"
echo "         comunicacao ficaram em estado/ -- sao a entrega do aluno."

# ---------------------------------------------------------------- resumo
echo
echo "=================================================="
SOBRA=$(docker ps --format '{{.Names}}' | grep -cE '^obs-|^fiapbank-otel-hg-|^fiap-lab-guia' || true)
if [ "${SOBRA:-0}" -eq 0 ]; then
    echo " TUDO FORA DO AR"
else
    echo " AINDA NO AR: ${SOBRA} container(s)"
    docker ps --format '{{.Names}}' | grep -E '^obs-|^fiapbank-otel-hg-|^fiap-lab-guia' | sed 's/^/   /'
fi
echo "=================================================="
echo
echo "  Para subir de novo:  bash run-lab.sh --sem-build"
echo
