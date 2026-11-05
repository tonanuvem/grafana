#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- publica versoes do servico `transactions`
# =============================================================================
#   ./deploy.sh                    mostra a versao no ar, a jornada e o CFR
#   ./deploy.sh nova-versao        avanca na sequencia guiada (v1.1 -> v1.4)
#   ./deploy.sh caos               ativa o Desafio Final as cegas (v2.0.0-caos)
#   ./deploy.sh diagnosticar A|B|C valida o diagnostico do Modo Caos
#   ./deploy.sh rollback           reverte para a ultima versao estavel (v1.4.0)
#   ./deploy.sh --reset            volta a v1.0.0 e limpa o historico
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HIST="$ESTADO/deploys.csv"
ARQ_CAOS="$ESTADO/caos.env"

# ---- a sequencia de construcao do entendimento ------------------------------
#   versao | atraso_ms | falha_% | descricao
#
#   Passo 1 (v1.1.0): Controle (0ms, 0% erro) -- prova que nem todo deploy
#                     quebra producao; cria a linha vertical roxa sem mover curvas.
#   Passo 2 (v1.2.0): Degradacao silenciosa (+1100ms, 0% erro) -- Service Graph
#                     continua VERDE e erro tecnico em 0%, mas p90 sobe, SLI de
#                     latencia cai e o volume de negocio (transferencias/min) cai.
#   Passo 3 (v1.3.0): Incidente severo (+1100ms, 15% HTTP 500) -- Service Graph
#                     fica VERMELHO, Burn Rate dispara derretendo o Error Budget,
#                     traces com erro surgem no Tempo e logs ERROR no Loki.
#   Passo 4 (v1.4.0): Hotfix / Fix-Forward (0ms, 0% erro) -- limpa a lentidao e
#                     os erros 500; mostra que corrigir estanca a queima, mas o
#                     Error Budget consumido NAO volta para 100%.
#   Passo 5 (caos):   v2.0.0-caos -- sorteia as cegas 1 de 3 perfis (A, B ou C)
#                     para o aluno investigar nos dashboards e responder com
#                     `./deploy.sh diagnosticar A|B|C`.
#   Passo 6 (rollback): reverte a v2.0.0-caos de volta para a v1.4.0 estavel e
#                       atualiza a metrica DORA Change Failure Rate (CFR).
VERSOES=(
  "v1.0.0|0|0|linha de base"
  "v1.1.0|0|0|deploy saudavel -- o controle: nenhuma metrica reage"
  "v1.2.0|1100|0|lentidao silenciosa: +1,1s por requisicao, responde 200, mapa VERDE"
  "v1.3.0|1100|15|o incidente escala: +1,1s e 15% devolvem 500, mapa VERMELHO"
  "v1.4.0|0|0|hotfix (fix-forward): remove a lentidao e o erro"
)

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

# ---- aplica uma versao ao container -----------------------------------------
aplicar() {
    local versao="$1" atraso="$2" falha="$3"
    local jitter=0
    [ "$atraso" != "0" ] && jitter=300

    definir_env APP_VERSION          "${versao#v}"
    definir_env ATRASO_ARTIFICIAL_MS "$atraso"
    definir_env ATRASO_JITTER_MS     "$jitter"
    definir_env FALHA_ARTIFICIAL_PCT "$falha"

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

orientar_versao() {
    local v="$1"
    case "$v" in
      v1.1.0)
        cat <<'EOF'
  ETAPA 1 DE 4 -- O DEPLOY DE CONTROLE (GRUPO DE CONTROLE)
  --------------------------------------------------------
  O que observar no Grafana (aguarde ~60s):
    1. Abra: Dashboards > 2 · Error Budget (e 3 · Deploys e CFR)
    2. Localize a linha vertical tracejada ROXA (anotacao do deploy v1.1.0).
    3. Pergunta: alguma curva de latencia, erro ou Burn Rate se moveu?

  Licao: nem todo deploy causa incidente. Sem conhecer o comportamento
         de um deploy saudavel, qualquer oscilacao vira culpa no deploy.

  Proximo passo (quando conferir no painel):
    ./deploy.sh nova-versao
EOF
        ;;
      v1.2.0)
        cat <<'EOF'
  ETAPA 2 DE 4 -- O ASSASSINO SILENCIOSO (MAPA VERDE, NEGOCIO CAINDO)
  -------------------------------------------------------------------
  O que observar no Grafana (aguarde ~60s):
    1. Drilldown > Traces > Service Graph:
       - Qual e' a cor do no' `transactions`? (Continua 100% VERDE!)
       - A taxa de erro HTTP 500 e o Burn Rate continuam em ZERO.
    2. Dashboards > 2 · Error Budget:
       - Olhe "p90 por VERSAO": a serie v1.2.0 saltou para > 1,5s!
       - Olhe "SLI de latencia (% abaixo de 1,5s)": despencou!
    3. Dashboards > 1 · Saude do Negocio:
       - Olhe "Transferencias concluidas por minuto": o volume caiu so'
         porque ficou lento, sem nenhum erro 500!

  Proximo passo (apos investigar a lentidao nos paineis):
    ./deploy.sh nova-versao
EOF
        ;;
      v1.3.0)
        cat <<'EOF'
  ETAPA 3 DE 4 -- O INCENDIO NO CORE (OS 3 PILARES EM ACAO)
  ---------------------------------------------------------
  O incidente escalou! Percorra os 3 pilares no Grafana (aguarde ~60s):
    1. METRICAS (Dashboards > 2 · Error Budget):
       - Veja o "Burn rate (5 min)" explodir (> 7,2x) e o "Orcamento restante"
         derreter rapidamente.
    2. TRACES (Drilldown > Traces > Service Graph):
       - O no' `transactions` ficou VERMELHO!
       - No Explore > Tempo, filtre por `status = error` e veja o span
         POST /transfer falhando com HTTP 500 na `service.version = 1.3.0`.
    3. LOGS (No rodape' do Dashboard "2 · Error Budget" ou Explore > Loki):
       - Veja as linhas de ERROR confessando a falha na v1.3.0!

  Proximo passo (aplicar o Hotfix / Fix-Forward para corrigir o bug):
    ./deploy.sh nova-versao
EOF
        ;;
      v1.4.0)
        cat <<'EOF'
  ETAPA 4 DE 4 -- O HOTFIX / FIX-FORWARD (ESTANCANDO O SANGRAMENTO)
  -----------------------------------------------------------------
  A correcao (v1.4.0) entrou no ar! Confira nos paineis (aguarde ~60s):
    1. Dashboards > 2 · Error Budget:
       - Os erros por minuto caem a zero e o "p90 por VERSAO" da v1.4.0
         volta para ~250ms.
       - ATENCAO AO GAUGE "Orcamento restante": ele parou de cair, mas
         NAO voltou para 100%! Corrigir (ou reverter) estanca o sangramento,
         mas nao repoe o orcamento gasto -- so' o tempo repoe.

  PRONTO PARA O DESAFIO FINAL?
    Dispare uma versao misteriosa e tente descobrir o que ela tem olhando
    apenas para os dashboards:
      ./deploy.sh caos
EOF
        ;;
    esac
}

mostrar_status() {
    local v; v=$(versao_atual)
    titulo "DEPLOYS -- servico transactions"
    echo
    echo "  Trilha: v1.0.0 -> v1.1.0 -> v1.2.0 -> v1.3.0 -> v1.4.0 -> [caos] -> [rollback]"
    echo "  Versao no ar agora:  $v"
    if [ -f "$HIST" ] && [ "$(wc -l < "$HIST")" -gt 1 ]; then
        echo
        echo "  Historico:"
        tail -n +2 "$HIST" | awk -F, '{printf "    %s  %-12s %-9s %s\n", $1, $2, $3, $4}'
        local d r
        d=$(grep -c ',deploy,' "$HIST"); r=$(grep -c ',rollback,' "$HIST")
        echo
        if [ "$d" -gt 0 ]; then
            echo "  Deploys: $d · revertidos: $r · CFR: $(( r * 100 / d ))%"
            [ "$d" -lt 5 ] && echo "  (com $d deploys o CFR ainda e' amostra pequena -- acompanhe no dashboard 3 · Deploys e CFR)"
        fi
    else
        echo "  Nenhum deploy registrado. Comece com: ./deploy.sh nova-versao"
    fi
    echo
}

# ------------------------------------------------------------------- acoes
ACAO="${1:-status}"

case "$ACAO" in
  status|"") mostrar_status; exit 0 ;;

  --reset)
      exige_stack
      rm -f "$HIST" "$ENV_ESTADO" "$ARQ_CAOS"
      aplicar "v1.0.0" "0" "0"
      publicar_metricas
      ok "voltou para v1.0.0 e limpou o historico"
      exit 0 ;;

  nova-versao|hotfix)
      exige_stack
      ATUAL=$(versao_atual)
      if [ "$ATUAL" = "v2.0.0-caos" ]; then
          aviso "voce esta no Modo Caos (v2.0.0-caos)."
          echo "       Diagnostique com: ./deploy.sh diagnosticar A|B|C"
          echo "       Ou reverta para a v1.4.0 estavel com: ./deploy.sh rollback"
          exit 0
      fi
      # Se o aluno ja passou pela v1.3.0 e fez rollback antes da hora, avanca
      # para a proxima versao inedita (ex.: v1.4.0 hotfix) em vez de repetir.
      IDX=$(indice_de "$ATUAL")
      if [ -f "$HIST" ] && grep -q ',v1.3.0,deploy,' "$HIST" && [ "$IDX" -lt 3 ]; then
          PROX=4
      else
          PROX=$((IDX+1))
      fi
      if [ "$PROX" -ge "${#VERSOES[@]}" ]; then
          aviso "voce ja concluiu as 4 versoes guiadas (esta na v1.4.0)."
          echo "       Agora encare o Desafio Final rodando:"
          echo "         ./deploy.sh caos"
          exit 0
      fi
      NOVA=$(campo "$PROX" 1); ATRASO=$(campo "$PROX" 2); FALHA=$(campo "$PROX" 3)
      titulo "PUBLICANDO $NOVA"
      echo
      aplicar "$NOVA" "$ATRASO" "$FALHA"
      registrar "$NOVA" "deploy" "em-observacao"
      ok "$NOVA no ar (anterior: $ATUAL)"
      echo
      orientar_versao "$NOVA"
      echo
      exit 0 ;;

  caos)
      exige_stack
      ATUAL=$(versao_atual)
      # Sorteia 1 entre 3 perfis de anomalia sem revelar no terminal:
      #   0 -> [A] Comportamento tipo v1.2.0 (Lentidao Silenciosa: 1500ms, 0% erro)
      #   1 -> [B] Comportamento tipo v1.3.0 (Colapso: 2000ms + 25% erro 500)
      #   2 -> [C] Comportamento Inedito Fast-Fail (Rapido: 0ms, mas 20% erro 500)
      SORTEIO=$(( RANDOM % 3 ))
      case "$SORTEIO" in
        0)
          CAOS_OPCAO="A"
          CAOS_ATRASO="1500"
          CAOS_FALHA="0"
          CAOS_RESUMO="Opcao [A] -- Degradacao Silenciosa tipo v1.2.0 (atraso=1500ms, falha=0%)"
          ;;
        1)
          CAOS_OPCAO="B"
          CAOS_ATRASO="2000"
          CAOS_FALHA="25"
          CAOS_RESUMO="Opcao [B] -- Colapso Total tipo v1.3.0 (atraso=2000ms, falha=25% HTTP 500)"
          ;;
        2)
          CAOS_OPCAO="C"
          CAOS_ATRASO="0"
          CAOS_FALHA="20"
          CAOS_RESUMO="Opcao [C] -- Fast-Fail Inedito (atraso=0ms, falha=20% HTTP 500 sem lentidao)"
          ;;
      esac

      cat > "$ARQ_CAOS" <<EOF
CAOS_OPCAO="$CAOS_OPCAO"
CAOS_ATRASO="$CAOS_ATRASO"
CAOS_FALHA="$CAOS_FALHA"
CAOS_RESUMO="$CAOS_RESUMO"
CAOS_ANTERIOR="$ATUAL"
EOF

      titulo "DESAFIO FINAL: MODO CAOS (v2.0.0-caos NO AR)"
      echo
      aplicar "v2.0.0-caos" "$CAOS_ATRASO" "$CAOS_FALHA"
      registrar "v2.0.0-caos" "deploy" "desafio-caos"
      ok "v2.0.0-caos publicada (nenhum parametro foi revelado no terminal!)"
      echo
      cat <<'EOF'
  SUA MISSAO:
  Aguarde ~60s, inspecione os dashboards no Grafana e descubra qual
  destes 3 comportamentos a v2.0.0-caos introduziu em producao:

    [A] Comportamento tipo v1.2.0 (Degradacao Silenciosa / So' Lentidao)
        - Service Graph continua VERDE, 0 erros/min e Burn Rate em 0
        - Latencia p90 da v2.0.0-caos sobe (> 1,5s) e SLI de Latencia cai

    [B] Comportamento tipo v1.3.0 (Colapso: Lentidao + Erro HTTP 500)
        - Service Graph fica VERMELHO, Burn Rate explode e logs mostram ERROR
        - Latencia p90 da v2.0.0-caos TAMBEM sobe (> 2,0s)

    [C] Comportamento Inedito: "Fast-Fail" (Erro HTTP 500 SEM Lentidao!)
        - Service Graph fica VERMELHO, Burn Rate explode e logs mostram ERROR
        - MAS a Latencia p90 da v2.0.0-caos continua baixa (~250ms) e o
          SLI de Latencia fica perto de 100%!

  Quando fechar o diagnostico pelos graficos, confira sua resposta com:
    ./deploy.sh diagnosticar A    (ou B, ou C)
EOF
      echo
      exit 0 ;;

  diagnosticar|revelar)
      if [ ! -f "$ARQ_CAOS" ]; then
          aviso "o Modo Caos ainda nao foi ativado."
          echo "       Rode primeiro: ./deploy.sh caos"
          exit 0
      fi
      # shellcheck disable=SC1090
      source "$ARQ_CAOS"
      PALPITE=$(echo "${2:-}" | tr '[:lower:]' '[:upper:]')

      if [ "$ACAO" = "revelar" ] && [ -z "$PALPITE" ]; then
          PALPITE="$CAOS_OPCAO"
      fi

      if [ -z "$PALPITE" ] || [[ ! "$PALPITE" =~ ^[ABC]$ ]]; then
          aviso "informe a opcao que voce diagnosticou nos dashboards: A, B ou C."
          echo "       Exemplo: ./deploy.sh diagnosticar A"
          exit 1
      fi

      echo
      if [ "$PALPITE" = "$CAOS_OPCAO" ]; then
          titulo "DIAGNOSTICO CORRETO! [$CAOS_OPCAO]"
          echo
          ok "$CAOS_RESUMO"
          echo
          case "$CAOS_OPCAO" in
            A)
              echo "  Por que os paineis provaram a Opcao [A]:"
              echo "    - No Service Graph e em 'Erro por versao', a v2.0.0-caos teve 0 erros 500."
              echo "    - Mas em 'p90 por VERSAO' a latencia subiu para ~2s e o SLI de latencia caiu!"
              ;;
            B)
              echo "  Por que os paineis provaram a Opcao [B]:"
              echo "    - Os DOIS sinais degradaram juntos na v2.0.0-caos:"
              echo "      Burn Rate explodiu com 25% de HTTP 500 E o p90 passou de 2,5s!"
              ;;
            C)
              echo "  Por que os paineis provaram a Opcao [C]:"
              echo "    - Pegadinha classica: o servico falhou rapido (Fast-Fail com 20% de HTTP 500)!"
              echo "    - O Burn Rate explodiu e o Service Graph ficou vermelho, mas o p90 da"
              echo "      v2.0.0-caos continuou baixinho (~250ms) porque abortar nao gasta tempo."
              ;;
          esac
          echo
          echo "  PASSO FINAL DA MISSAO:"
          echo "    Agora estanque o incidente revertendo a v2.0.0-caos para a ultima"
          echo "    versao estavel (v1.4.0) e veja o efeito no dashboard '3 · Deploys e CFR':"
          echo "      ./deploy.sh rollback"
          echo
      else
          titulo "DIAGNOSTICO INCORRETO (voce chutou [$PALPITE])"
          echo
          aviso "Os paineis do Grafana mostram outro padrao para a v2.0.0-caos!"
          echo
          echo "  Dica de investigacao (olhe no dashboard '2 · Error Budget'):"
          echo "    1. Olhe o painel 'Transferencias por minuto x erros' e o 'Burn rate (5 min)':"
          echo "       - Ha erros HTTP 500 subindo agora? (Se NAO ha erros, so' pode ser [A])."
          echo "    2. Se HA erros HTTP 500 subindo, olhe o grafico 'p90 por VERSAO' da v2.0.0-caos:"
          echo "       - O p90 da v2.0.0-caos esta ALTO (> 2s) -> Opcao [B]"
          echo "       - O p90 da v2.0.0-caos esta BAIXO (~250ms) -> Opcao [C]"
          echo
          echo "  Olhe novamente os graficos e tente de novo:"
          echo "    ./deploy.sh diagnosticar A   (ou B, ou C)"
          echo
      fi
      exit 0 ;;

  rollback)
      exige_stack
      ATUAL=$(versao_atual)
      if [ "$ATUAL" = "v2.0.0-caos" ]; then
          ANT="v1.4.0"
          ATRASO="0"
          FALHA="0"
          rm -f "$ARQ_CAOS"
      else
          IDX=$(indice_de "$ATUAL")
          if [ "$IDX" -le 0 ]; then
              aviso "ja esta na versao de base (v1.0.0), nada a reverter."
              exit 0
          fi
          ANT=$(campo $((IDX-1)) 1); ATRASO=$(campo $((IDX-1)) 2); FALHA=$(campo $((IDX-1)) 3)
      fi
      titulo "ROLLBACK EXECUTADO: $ATUAL -> $ANT"
      echo
      aplicar "$ANT" "$ATRASO" "$FALHA"
      registrar "$ANT" "rollback" "revertido-de-$ATUAL"
      ok "$ANT de volta no ar (incidente estancado!)"
      echo
      cat <<EOF
  Confira o fechamento nos dashboards (aguarde ~60s):
    1. Dashboards > 3 · Deploys e CFR:
       - Veja o contador "Revertidos" subir e o seu Change Failure Rate (CFR)
         refletir a falha do deploy revertido ($ATUAL).
       - Veja em "Volume por versao" o trafego da $ATUAL cair e a $ANT reassumir.
    2. Dashboards > 2 · Error Budget:
       - O Burn Rate volta a cair e a queima do orcamento estanca.
       - O "Orcamento restante" permanece onde parou: rollback estanca o
         incidente, mas so' o tempo repoe o orcamento consumido.
EOF
      echo
      exit 0 ;;

  piorar)
      exige_stack
      ATUAL=$(versao_atual)
      titulo "ESCALADA DE INCIDENTE ($ATUAL)"
      echo
      aplicar "$ATUAL" "$PIOR_ATRASO" "$PIOR_FALHA"
      ok "degradacao intensificada em producao na $ATUAL"
      echo
      echo "  Observe no dashboard '2 · Error Budget' a aceleracao do Burn Rate"
      echo "  e o custo por minuto nao transacionado."
      echo
      exit 0 ;;

  *) erro "acao desconhecida: $ACAO"
     echo "       use: status | nova-versao | caos | diagnosticar <A|B|C> | rollback | --reset"; exit 1 ;;
esac
