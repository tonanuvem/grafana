#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- registra a decisao do incidente, com os numeros do momento
# =============================================================================
#   ./decisao.sh                         mostra o quadro atual e o historico
#   ./decisao.sh rollback "justificativa"
#   ./decisao.sh seguir   "justificativa"
#
# O script captura sozinho os numeros do painel NO INSTANTE da decisao --
# orcamento restante, burn rate, latencia, volume e custo acumulado. Depois
# nao da' para reconstruir: as janelas deslizam e o momento passa.
#
# Decisao sem numero nao e' decisao, e' opiniao. Por isso a justificativa e'
# obrigatoria e o registro guarda o contexto junto.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HIST="$ESTADO/decisoes.csv"

num() {  # valor formatado, ou "-" quando nao ha dado
    local v; v=$(promq "$1")
    [ -z "$v" ] || [ "$v" = "NaN" ] && { echo "-"; return; }
    python3 -c "print(round(float('$v'), ${2:-2}))"
}

pct() {
    local v; v=$(promq "$1")
    [ -z "$v" ] || [ "$v" = "NaN" ] && { echo "-"; return; }
    python3 -c "print(round(float('$v')*100, 1))"
}

quadro() {
    ORC=$(pct 'jornada:error_budget_restante:ratio')
    BURN=$(num 'jornada:burn_rate:5m' 1)
    LAT=$(pct 'jornada:sli_latencia:ratio5m')
    VOL=$(num 'negocio:transferencias_por_min' 1)
    VERSAO=$(promq 'topk(1, traces_span_metrics_calls_total{service_name="transactions"}) ' >/dev/null 2>&1; \
             curl -sG "$PROM/api/v1/query" --data-urlencode 'query=topk(1, sum by (service_version) (rate(traces_span_metrics_calls_total{service_name="transactions"}[5m])))' \
             | python3 -c "
import sys,json
r=json.load(sys.stdin)['data']['result']
print(r[0]['metric'].get('service_version','?') if r else '?')")

    # Custo: o que deixou de ser transacionado em relacao ao volume normal.
    TKT=$(num 'negocio:valor_por_transferencia_brl' 0)
    echo
    echo "  QUADRO NO MOMENTO DA DECISAO"
    echo "  ------------------------------------------------"
    printf "   versao no ar             %s\n" "${VERSAO:-?}"
    printf "   orcamento restante       %s%%\n" "$ORC"
    printf "   burn rate (5 min)        %sx\n" "$BURN"
    printf "   %% abaixo de 1,5s         %s%%\n" "$LAT"
    printf "   transferencias/min       %s\n" "$VOL"
    printf "   valor por transferencia  R$ %s\n" "$TKT"
    echo
}

if [ $# -eq 0 ]; then
    exige_stack
    titulo "DECISAO -- Transferencia entre contas"
    quadro
    if [ -f "$HIST" ] && [ "$(wc -l < "$HIST")" -gt 1 ]; then
        echo "  DECISOES JA REGISTRADAS"
        echo "  ------------------------------------------------"
        tail -n +2 "$HIST" | awk -F'|' '{printf "   %s  %-9s orc %5s%%  burn %5sx\n     \"%s\"\n", $1, $2, $3, $4, $7}'
        echo
    fi
    echo "  Para registrar:"
    echo "    ./decisao.sh rollback \"orcamento em 32%, burn 7x, nao da' para esperar\""
    echo "    ./decisao.sh seguir   \"burn 2x e caindo, checkpoint em 10 min\""
    echo
    exit 0
fi

ACAO="$1"
JUST="${2:-}"

case "$ACAO" in
    rollback|seguir) : ;;
    *) erro "decisao invalida: $ACAO  (use: rollback | seguir)"; exit 1 ;;
esac

if [ ${#JUST} -lt 15 ]; then
    erro "a justificativa e' obrigatoria e precisa citar numeros."
    echo "       Ex.: ./decisao.sh $ACAO \"orcamento em 32%, burn 7x, esgota em 40 min\""
    exit 1
fi

exige_stack
quadro

[ -f "$HIST" ] || echo "timestamp|decisao|orcamento_pct|burn_rate|latencia_pct|transf_por_min|justificativa" > "$HIST"
echo "$(date +%Y-%m-%dT%H:%M:%S)|$ACAO|$ORC|$BURN|$LAT|$VOL|$JUST" >> "$HIST"

ok "decisao registrada: $ACAO"

# ---------------------------------------------------------------------------
# O rascunho das tres comunicacoes, ja com os numeros reais. O aluno escreve o
# texto; os numeros vem do painel -- que e' exatamente o argumento do Bloco 3.
# ---------------------------------------------------------------------------
RASCUNHO="$ESTADO/comunicacao-$(date +%H%M%S).md"
cat > "$RASCUNHO" <<TXT
# Comunicacao do incidente -- $(date +%d/%m\ %H:%M)

Decisao tomada: **$ACAO** -- $JUST

## Para o time tecnico (agora, no canal do time)
> Transferencia: burn rate ${BURN}x. Latencia: ${LAT}% das transferencias
> abaixo de 1,5s. Volume: ${VOL}/min. Orcamento restante: ${ORC}%.
> Decisao: $ACAO. Checkpoint em ___ min.
>
> (complete: qual versao, desde que horario, e o que voce viu no trace)

## Para a gestao (status a cada 30 min)
> (o que o CLIENTE esta vivendo, em uma frase, sem jargao)
> (desde quando, e o que ja foi feito)
> Impacto estimado: ___ transferencias nao concluidas.
> Orcamento de confiabilidade do mes: ${ORC}% restante.

## Para o executivo (uma frase)
> (sem nome de servico, sem percentil, sem nome de ferramenta.
>  Teste: se provocar uma pergunta de esclarecimento, falhou.)

## Postmortem -- o que muda estruturalmente
> (nao vale "ter mais cuidado". O que na ARQUITETURA ou no PROCESSO
>  impediria a repeticao? O CFR aponta a resposta.)
TXT

echo
echo "  Rascunho com os numeros ja preenchidos:"
echo "    $RASCUNHO"
echo
