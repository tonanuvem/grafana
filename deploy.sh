#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- publica versoes do servico `transactions`
# =============================================================================
#   ./deploy.sh                 mostra a versao no ar e o historico
#   ./deploy.sh nova-versao     publica a proxima versao da sequencia
#   ./deploy.sh rollback        volta a anterior e marca aquele deploy como falho
#   ./deploy.sh --reset         volta a v1.0.0 e limpa o historico
#
# Voce NAO sabe, de antemao, se a versao que vai subir e' boa. E' assim de
# proposito: e' o que torna a decisao do exercicio uma decisao de verdade.
#
# Um deploy revertido conta como FALHA -- e' a definicao do DORA para
# Change Failure Rate: falhou o que exigiu rollback ou hotfix.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HIST="$ESTADO/deploys.csv"

# ---- a sequencia. Duas saudaveis e uma degradada, nesta ordem. -------------
#   versao   | cpus  | descricao (nao aparece para o aluno antes da hora)
VERSOES=(
  "v1.0.0|0|0|linha de base"
  "v1.1.0|0|0|deploy saudavel -- mostra que deploy normal nao move nada"
  "v1.2.0|1400|0|regressao de performance: +1,4s (com jitter) por transferencia"
  "v1.3.0|0|0|hotfix"
)

# O segundo estagio do incidente, que o instrutor dispara com ./deploy.sh piorar.
# Nao faz parte da sequencia: e' a mesma versao ficando pior.
PIOR_ATRASO=2500
PIOR_FALHA=25

versao_atual() {
    [ -f "$HIST" ] || { echo "v1.0.0"; return; }
    tail -1 "$HIST" 2>/dev/null | cut -d, -f2 | grep -E '^v[0-9]' || echo "v1.0.0"
}

indice_de() {
    local v="$1" i=0
    for linha in "${VERSOES[@]}"; do
        [ "${linha%%|*}" = "$v" ] && { echo "$i"; return; }
        i=$((i+1))
    done
    echo 0
}

campo() { echo "${VERSOES[$1]}" | cut -d'|' -f"$2"; }

# ---- aplica uma versao ao container -------------------------------------------
# Sem gerar YAML: o compose do bank-demo declara estas variaveis com
# ${VAR:-default}, entao publicar uma versao e' reescrever quatro linhas do
# env/grafana.env e recriar UM container.
aplicar() {
    local versao="$1" atraso="$2" falha="$3"
    local jitter=0
    [ "$atraso" != "0" ] && jitter=400

    definir_env APP_VERSION          "${versao#v}"
    definir_env ATRASO_ARTIFICIAL_MS "$atraso"
    definir_env ATRASO_JITTER_MS     "$jitter"
    definir_env FALHA_ARTIFICIAL_PCT "$falha"

    # while/read em vez de mapfile: o bash 3.2 (padrao do macOS) nao tem mapfile.
    local FS=(); local linha
    while IFS= read -r linha; do FS+=("$linha"); done < <(compose_app)
    (cd "$BASE_APP" && docker compose "${FS[@]}" up -d transactions) >/dev/null 2>&1
}

registrar() {
    local versao="$1" acao="$2" resultado="$3"
    [ -f "$HIST" ] || echo "timestamp,versao,acao,resultado" > "$HIST"
    echo "$(date +%Y-%m-%dT%H:%M:%S),$versao,$acao,$resultado" >> "$HIST"
    publicar_metricas
}

publicar_metricas() {
    local deploys rollbacks codigo corpo
    # ATENCAO: nada de "grep -c ... || echo 0". O grep -c JA imprime 0 quando
    # nao acha e ainda sai com codigo 1, entao o "|| echo 0" acrescenta um
    # segundo zero; o valor vira duas linhas e o corpo enviado ao pushgateway
    # fica invalido. O sintoma e' silencioso: o push e' recusado e o painel
    # de CFR simplesmente nao atualiza.
    deploys=$(grep -c ',deploy,'   "$HIST" 2>/dev/null); deploys=${deploys:-0}
    rollbacks=$(grep -c ',rollback,' "$HIST" 2>/dev/null); rollbacks=${rollbacks:-0}

    corpo=$(printf '%s\n' \
        "# TYPE lab_deploys_total gauge" \
        "lab_deploys_total $deploys" \
        "# TYPE lab_rollbacks_total gauge" \
        "lab_rollbacks_total $rollbacks" \
        "# TYPE lab_deploy_timestamp_seconds gauge" \
        "lab_deploy_timestamp_seconds $(date +%s)")

    codigo=$(printf '%s\n' "$corpo" | curl -s -o /dev/null -w '%{http_code}' \
             --data-binary @- "$PUSH/metrics/job/deploys/servico/transactions")

    case "$codigo" in
        200|202) : ;;
        *) aviso "pushgateway respondeu $codigo -- o painel de CFR nao vai atualizar" ;;
    esac
}

mostrar_status() {
    local v; v=$(versao_atual)
    titulo "DEPLOYS -- servico transactions"
    echo
    echo "  Versao no ar:  $v"
    if [ -f "$HIST" ] && [ "$(wc -l < "$HIST")" -gt 1 ]; then
        echo
        echo "  Historico:"
        tail -n +2 "$HIST" | awk -F, '{printf "    %s  %-8s %-9s %s\n", $1, $2, $3, $4}'
        local d r
        d=$(grep -c ',deploy,' "$HIST"); r=$(grep -c ',rollback,' "$HIST")
        echo
        if [ "$d" -gt 0 ]; then
            echo "  Deploys: $d · revertidos: $r · CFR: $(( r * 100 / d ))%"
            [ "$d" -lt 5 ] && echo "  (com $d deploys o CFR ainda nao significa nada -- e' metrica de tendencia)"
        fi
    else
        echo "  Nenhum deploy registrado."
    fi
    echo
}

# ------------------------------------------------------------------- acoes
ACAO="${1:-status}"

case "$ACAO" in
  status|"") mostrar_status; exit 0 ;;

  --reset)
      exige_stack
      rm -f "$HIST" "$ENV_ESTADO"
      aplicar "v1.0.0" "0" "0"
      publicar_metricas
      ok "voltou para v1.0.0 e limpou o historico"
      exit 0 ;;

  nova-versao)
      exige_stack
      ATUAL=$(versao_atual); IDX=$(indice_de "$ATUAL"); PROX=$((IDX+1))
      if [ "$PROX" -ge "${#VERSOES[@]}" ]; then
          aviso "nao ha mais versoes na sequencia."
          echo "       Recomece com: ./deploy.sh --reset"
          exit 0
      fi
      NOVA=$(campo "$PROX" 1); ATRASO=$(campo "$PROX" 2); FALHA=$(campo "$PROX" 3)
      titulo "PUBLICANDO $NOVA"
      echo
      aplicar "$NOVA" "$ATRASO" "$FALHA"
      registrar "$NOVA" "deploy" "em-observacao"
      ok "$NOVA no ar (anterior: $ATUAL)"
      echo
      echo "  O que fazer agora:"
      echo "    1. NAO olhe o codigo. Olhe o painel."
      echo "    2. Grafana > LAB GRAFANA > Error Budget"
      echo "    3. Se algo piorar, decida:  ./decisao.sh"
      echo
      echo "  Leva ~60s ate o sinal aparecer: as janelas de rate sao de 5 min."
      echo
      exit 0 ;;

  rollback)
      exige_stack
      ATUAL=$(versao_atual); IDX=$(indice_de "$ATUAL")
      if [ "$IDX" -le 0 ]; then
          aviso "ja esta na versao de base (v1.0.0), nada a reverter."
          exit 0
      fi
      ANT=$(campo $((IDX-1)) 1); ATRASO=$(campo $((IDX-1)) 2); FALHA=$(campo $((IDX-1)) 3)
      titulo "ROLLBACK: $ATUAL -> $ANT"
      echo
      aplicar "$ANT" "$ATRASO" "$FALHA"
      registrar "$ANT" "rollback" "revertido-de-$ATUAL"
      ok "$ANT no ar"
      echo
      echo "  Confira no painel, nesta ordem:"
      echo "    - latencia e erro voltam em 1-2 min"
      echo "    - o ORCAMENTO RESTANTE nao volta: fica onde parou."
      echo "      Rollback estanca, nao repoe. So' o tempo repoe."
      echo
      exit 0 ;;

  piorar)
      exige_stack
      ATUAL=$(versao_atual)
      titulo "A DEGRADACAO PIOROU ($ATUAL)"
      echo
      aplicar "$ATUAL" "$PIOR_ATRASO" "$PIOR_FALHA"
      ok "atraso ${PIOR_ATRASO}ms e ${PIOR_FALHA}% de falha"
      echo
      echo "  Uso: o instrutor dispara isto DEPOIS que o grupo ja decidiu."
      echo "  E' o custo de ter decidido com a informacao de 2 minutos atras."
      echo
      exit 0 ;;

  *) erro "acao desconhecida: $ACAO"
     echo "       use: status | nova-versao | rollback | piorar | --reset"; exit 1 ;;
esac
