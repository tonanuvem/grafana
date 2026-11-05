#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- publica versoes do servico `transactions`
# =============================================================================
#   ./deploy.sh                    mostra a versao no ar, a jornada e o CFR
#   ./deploy.sh nova-versao        avanca na sequencia guiada (v1.1 -> v1.4)
#   ./deploy.sh rollback           reverte para a ultima versao estavel (v1.4.0)
#   ./deploy.sh --reset            volta a v1.0.0 e limpa o historico
#
#   Fora do roteiro (opcional, nao citado no fluxo guiado):
#     ./deploy.sh caos               versao as cegas para diagnostico
#     ./deploy.sh diagnosticar A|B|C confere o diagnostico do Modo Caos
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
#   Passo 2 (v1.2.0): Degradacao silenciosa (+1400ms, 0% erro) -- Service Graph
#                     continua VERDE e erro tecnico em 0%, mas p90 sobe, SLI de
#                     latencia cai e o volume de negocio (transferencias/min) cai.
#   Passo 3 (v1.3.0): Incidente severo (+1400ms, 15% HTTP 500) -- Service Graph
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
  "v1.2.0|1400|0|lentidao silenciosa: +1,4s por requisicao, responde 200, mapa VERDE"
  "v1.3.0|1400|15|o incidente escala: +1,4s e 15% devolvem 500, mapa VERMELHO"
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
    # O hotfix tambem e' um deploy, entao conta no denominador.
    deploys=$(grep -cE ',(deploy|hotfix),' "$HIST" 2>/dev/null); deploys=${deploys:-0}
    rollbacks=$(grep -c ',rollback,' "$HIST" 2>/dev/null); rollbacks=${rollbacks:-0}
    local hotfixes falhas
    hotfixes=$(grep -c ',hotfix,' "$HIST" 2>/dev/null); hotfixes=${hotfixes:-0}
    # Falha, no DORA, e' a mudanca que exigiu remediacao: reverter ou corrigir.
    falhas=$((rollbacks + hotfixes))

    corpo=$(printf '%s\n' \
        "# TYPE lab_deploys_total gauge" \
        "lab_deploys_total $deploys" \
        "# TYPE lab_rollbacks_total gauge" \
        "lab_rollbacks_total $rollbacks" \
        "# TYPE lab_falhas_total gauge" \
        "lab_falhas_total $falhas" \
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
  Etapa 1 de 4 — um deploy que não muda nada
  ------------------------------------------
  A v1.1.0 subiu sem alterar latência nem taxa de erro.

  Aguarde 60s e abra o dashboard "2 · Error Budget":
    1. a linha roxa tracejada marca o momento do deploy;
    2. nenhuma curva se move depois dela.

  Guarde esta imagem: é a aparência de um deploy saudável. Sem essa
  referência, qualquer oscilação parece culpa do deploy.

  Próximo:  ./deploy.sh nova-versao
EOF
        ;;
      v1.2.0)
        cat <<'EOF'
  Etapa 2 de 4 — ficou lento, e nada acusou
  -----------------------------------------
  A v1.2.0 somou 1,4s por requisição. Nenhuma requisição falha.

  Aguarde 60s e confira, nesta ordem:
    1. Explore → Tempo → aba "Service Graph": o nó transactions está verde?
    2. Dashboard 2, "Tempo de resposta por versão": a v1.2.0 passou de 1,5s?
    3. Dashboard 1, "Transferências concluídas por minuto": o volume caiu?

  Mapa verde e negócio em queda ao mesmo tempo: é isso que um
  monitoramento baseado só em erro deixa passar.

  Próximo:  ./deploy.sh nova-versao
EOF
        ;;
      v1.3.0)
        cat <<'EOF'
  Etapa 3 de 4 — agora também falha
  ---------------------------------
  A v1.3.0 manteve a lentidão e passou a devolver erro 500 em 15%
  das requisições.

  Aguarde 60s e percorra os três sinais:
    1. Métrica — Dashboard 2: o orçamento restante começa a derreter.
    2. Traço — Explore → Tempo → aba "Service Graph": o nó transactions
       ficou vermelho. Na aba "Search", filtre status = error e abra um
       span da versão 1.3.0.
    3. Log — Dashboard 2, "Erros do serviço transactions": as linhas aparecem.

  Compare com a etapa anterior: lá o painel de log estava vazio.

  Próximo:  ./deploy.sh nova-versao
EOF
        ;;
      v1.4.0)
        cat <<'EOF'
  Etapa 4 de 4 — a correção
  -------------------------
  A v1.4.0 removeu a lentidão e o erro.

  Aguarde 60s e confira no dashboard "2 · Error Budget":
    1. os erros por minuto voltam a zero;
    2. o tempo de resposta da v1.4.0 volta para cerca de 90ms;
    3. o orçamento restante parou de cair — e não voltou a 100%.

  O terceiro item é o que importa: corrigir estanca o consumo, mas o
  orçamento gasto só se recompõe com o tempo.

  Trilha concluída.
EOF
        ;;
    esac
}

mostrar_status() {
    local v; v=$(versao_atual)
    titulo "DEPLOYS -- servico transactions"
    echo
    echo "  Trilha: v1.0.0 -> v1.1.0 -> v1.2.0 -> v1.3.0 -> v1.4.0"
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
          ok "trilha concluída: as 4 versões guiadas já passaram pela produção."
          echo "       Para reconstruir o incidente do zero: ./deploy.sh --reset"
          exit 0
      fi
      NOVA=$(campo "$PROX" 1); ATRASO=$(campo "$PROX" 2); FALHA=$(campo "$PROX" 3)
      titulo "PUBLICANDO $NOVA"
      echo
      aplicar "$NOVA" "$ATRASO" "$FALHA"
      # O CFR do DORA conta como falha a mudanca que exigiu remediacao --
      # rollback OU fix-forward. A v1.4.0 e' o hotfix: registrar como
      # "deploy" deixava o CFR em zero numa trilha que teve um incidente.
      if [ "$NOVA" = "v1.4.0" ]; then
          registrar "$NOVA" "hotfix" "corrigiu-$ATUAL"
      else
          registrar "$NOVA" "deploy" "em-observacao"
      fi
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
              echo "    - Mas em 'Tempo de resposta por versao' a latencia subiu para ~2s e o SLI de latencia caiu!"
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
          echo "    1. Olhe 'Transferencias por minuto (negocio) x erros (tecnico)':"
          echo "       - Ha erros HTTP 500 subindo agora? (Se NAO ha erros, so' pode ser [A])."
          echo "    2. Se HA erros HTTP 500 subindo, olhe o grafico 'Tempo de resposta por versao' da v2.0.0-caos:"
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
     echo "       use: status | nova-versao | rollback | --reset"; exit 1 ;;
esac
