#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- o alvo do SLO e o valor de negocio, por script
# =============================================================================
#   ./slo.sh                 mostra os valores em vigor e o orcamento
#   ./slo.sh alvo 99.5       muda o alvo do SLO da transferencia
#   ./slo.sh ticket 125      muda o R$ por transferencia nao concluida
#   ./slo.sh --reset         volta ao padrao (99% e R$ 125)
#
# Voce nunca edita arquivo de configuracao: o script valida, reescreve
# alvos.yml e recarrega o Prometheus. Se errar o valor, ele recusa.
#
# Para EXPLORAR o efeito de um alvo diferente sem se comprometer, use a
# variavel "Alvo do SLO" no proprio dashboard do Grafana -- ela recalcula na
# hora. Este script e' o passo seguinte: comprometer-se, porque e' ele que
# muda o ALERTA.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALVOS="$STACK/prometheus/rules/alvos.yml"
JANELA_H=6

escrever() {
    local objetivo="$1" ticket="$2"
    cat > "$ALVOS" <<YML
# =============================================================================
# ARQUIVO GERADO -- nao edite a mao.
#   ./slo.sh alvo 99.5      muda o alvo do SLO
#   ./slo.sh ticket 125     muda o R\$ por transferencia
#   ./slo.sh --reset        volta ao padrao
# =============================================================================
groups:
  - name: alvos
    rules:
      # Janela do lab: ${JANELA_H}h (em producao seriam 30 dias).
      - record: jornada:slo_objetivo
        expr: vector($objetivo)
        labels: { jornada: transferencia }

      # Quanto vale, para o negocio, uma transferencia que nao aconteceu.
      - record: negocio:valor_por_transferencia_brl
        expr: vector($ticket)
YML
}

ler() {
    grep -A1 "record: $1" "$ALVOS" | grep -oE 'vector\([0-9.]+\)' | grep -oE '[0-9.]+' | head -1
}

recarregar() {
    local codigo
    codigo=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROM/-/reload")
    if [ "$codigo" != "200" ]; then
        erro "o Prometheus recusou a recarga (HTTP $codigo)."
        echo "       Veja o motivo:  docker logs obs-prometheus --tail 20"
        return 1
    fi
    sleep 2
    return 0
}

orcamento_minutos() {
    python3 -c "
obj = float('$1')
print(round((1 - obj) * $JANELA_H * 60, 1))"
}

mostrar() {
    exige_stack
    local obj tkt restante
    obj=$(ler jornada:slo_objetivo)
    tkt=$(ler negocio:valor_por_transferencia_brl)
    restante=$(promq 'jornada:error_budget_restante:ratio')

    titulo "SLO EM VIGOR -- Transferencia entre contas"
    echo
    printf "  Alvo                  %s%%\n" "$(python3 -c "print(round(float('$obj')*100,3))")"
    printf "  Janela                %sh\n" "$JANELA_H"
    printf "  Orcamento de erro     %s minutos\n" "$(orcamento_minutos "$obj")"
    printf "  Valor por transacao   R$ %s\n" "$tkt"
    echo
    if [ -n "$restante" ] && [ "$restante" != "NaN" ]; then
        printf "  Orcamento restante    %s%%\n" "$(python3 -c "print(round(float('$restante')*100,1))")"
    else
        printf "  Orcamento restante    (sem dado -- ha transito na jornada?)\n"
    fi
    echo
}

ACAO="${1:-mostrar}"

case "$ACAO" in
  mostrar|"") mostrar; exit 0 ;;

  --reset)
      exige_stack; escrever "0.99" "125" && recarregar && ok "alvo 99% e R\$ 125 restaurados"; exit 0 ;;

  alvo)
      exige_stack
      NOVO="${2:-}"
      case "$NOVO" in
        ''|*[!0-9.]*) erro "informe o alvo em porcentagem. Ex.: ./slo.sh alvo 99.5"; exit 1 ;;
      esac
      VALIDO=$(python3 -c "
v=float('$NOVO')
print('sim' if 50 <= v < 100 else 'nao')")
      [ "$VALIDO" != "sim" ] && { erro "alvo fora da faixa: use algo entre 50 e 99.999"; exit 1; }

      OBJ=$(python3 -c "print(float('$NOVO')/100)")
      TKT=$(ler negocio:valor_por_transferencia_brl)
      escrever "$OBJ" "${TKT:-125}" && recarregar || exit 1
      ok "alvo agora e' $NOVO% (orcamento: $(orcamento_minutos "$OBJ") min em ${JANELA_H}h)"
      echo
      echo "  Confira o efeito:  Grafana > LAB GRAFANA > Error Budget"
      echo "  O alerta tambem mudou -- e' ele que decide se alguem e' acordado."
      exit 0 ;;

  ticket)
      exige_stack
      NOVO="${2:-}"
      case "$NOVO" in
        ''|*[!0-9.]*) erro "informe o valor em reais. Ex.: ./slo.sh ticket 125"; exit 1 ;;
      esac
      OBJ=$(ler jornada:slo_objetivo)
      escrever "${OBJ:-0.99}" "$NOVO" && recarregar || exit 1
      ok "cada transferencia nao concluida passa a valer R\$ $NOVO"
      echo
      echo "  De onde vem esse numero? E' a pergunta do exercicio -- e nenhuma"
      echo "  ferramenta responde por voce."
      exit 0 ;;

  *) erro "acao desconhecida: $ACAO"
     echo "       use: (vazio) | alvo <n> | ticket <n> | --reset"; exit 1 ;;
esac
