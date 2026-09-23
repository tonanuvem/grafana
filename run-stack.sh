#!/usr/bin/env bash
# =============================================================================
# LAB GRAFANA -- sobe o stack de observabilidade e liga o bank-demo nele
# =============================================================================
#   bash run-stack.sh             sobe tudo e valida
#   bash run-stack.sh --parar     derruba o stack (preserva dados)
#   bash run-stack.sh --status    mostra o estado atual
#   bash run-stack.sh --sem-app   so' o stack, sem religar o bank-demo
#
# O collector daqui NAO disputa porta com o splunk-otel-collector: ele nao
# publica 4317/4318 no host. Os dois convivem na mesma maquina.
# =============================================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACAO="subir"
RELIGAR_APP=true

for ARG in "$@"; do
    case "$ARG" in
        --parar)   ACAO="parar" ;;
        --status)  ACAO="status" ;;
        --sem-app) RELIGAR_APP=false ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERRO] opcao desconhecida: $ARG"; exit 1 ;;
    esac
done



# ------------------------------------------------------------------ parar
if [ "$ACAO" = "parar" ]; then
    titulo "PARANDO O STACK DO LAB GRAFANA"
    # --profile containers: sem ele o `down` ignora o cAdvisor, que e'
    # profile-gated, e o container fica de pe' depois do "stack parado".
    docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" \
        --profile containers down 2>/dev/null
    ok "stack parado (volumes preservados)"
    echo
    echo "  Para apagar tambem os dados:"
    echo "    docker compose -p $PROJETO -f $STACK/docker-compose.yml --profile containers down -v"
    exit 0
fi


# ----------------------------------------------------------------- checagens
titulo "LAB GRAFANA -- OBSERVABILIDADE COM GRAFANA"

echo
echo "1. PRE-REQUISITOS"
echo "--------------------------------------------------"

command -v docker >/dev/null 2>&1 || { erro "Docker nao encontrado."; exit 1; }
docker info >/dev/null 2>&1      || { erro "Docker instalado, mas o daemon nao responde."; exit 1; }
ok "docker"

# A aplicacao precisa estar rodando NA VARIANTE BRIDGE: e' ela que cria a
# rede em que o collector vai entrar. Em network_mode: host nao ha rede.
REDE=$(docker network ls --format '{{.Name}}' | grep -E '(fiapbank|martianbank)-otel-hg_bankapp-network' | head -1)

if [ -z "$REDE" ]; then
    erro "A rede do bank-demo (variante bridge) nao existe."
    echo "       O LAB GRAFANA usa a variante BRIDGE, nao a host."
    echo
    echo "       Suba a aplicacao antes:"
    echo "         cd $BASE_APP"
    echo "         docker compose -f $COMPOSE_APP up -d"
    exit 1
fi
ok "rede do bank-demo: $REDE"

# Portas que o stack publica. A 4317/4318 NAO estao aqui de proposito.
for P in 9090 3100 3200 3001 8007; do
    DONO=$(docker ps --format '{{.Names}} {{.Ports}}' | grep ":$P->" | awk '{print $1}' | head -1)
    if [ -n "$DONO" ] && [[ "$DONO" != obs-* ]]; then
        erro "porta $P ocupada por '$DONO'."
        echo "       Libere antes de subir: docker stop $DONO"
        exit 1
    fi
done
ok "portas livres (9090, 3100, 3200, 3001, 8007)"

if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet splunk-otel-collector 2>/dev/null; then
        ok "splunk-otel-collector segue ativo -- e nao ha conflito: o collector"
        echo "       do LAB GRAFANA nao publica 4317/4318 no host."
    fi
fi

# O socket do Docker, para o cAdvisor nomear os containers.
#
# Sem ele o cAdvisor nao registra o "docker container factory" e cai para
# cgroup cru: as metricas continuam saindo, mas SEM os labels `name` e `image`
# -- e o dashboard de containers, que filtra por `image!=""`, fica inteiro
# vazio. MEDIDO: o log do cAdvisor diz "Registration of the docker container
# factory failed" e nada mais reclama.
#
# O caminho nao e' o mesmo em todo lugar: em Linux e' /var/run/docker.sock, mas
# o Docker Desktop usa ~/.docker/run/docker.sock.
SOCK=""
for C in /var/run/docker.sock "$HOME/.docker/run/docker.sock"; do
    [ -S "$C" ] && { SOCK="$C"; break; }
done
# O cAdvisor precisa TAMBEM do socket do containerd: desde a v0.47 ele usa o
# cliente do containerd para registrar o docker factory, e so' o socket do
# Docker nao basta. MEDIDO: com apenas o do Docker, o log passa a dizer
# "cannot unix dial containerd api service" e os labels continuam faltando.
CSOCK=""
for C in /run/containerd/containerd.sock /var/run/containerd/containerd.sock; do
    [ -S "$C" ] && { CSOCK="$C"; break; }
done

PERFIS=()
if [ -n "$SOCK" ] && [ -n "$CSOCK" ]; then
    ok "sockets do Docker e do containerd encontrados"
    PERFIS=(--profile containers)
else
    # No Docker Desktop (macOS/Windows) o containerd fica DENTRO da VM e nao ha
    # como monta-lo. O resto do stack funciona normalmente; so' o dashboard de
    # containers e' afetado. Dizer isso e' melhor do que o aluno abrir a tela
    # vazia e achar que o lab quebrou.
    aviso "sem socket do containerd -- 'Containers - Docker' ficara sem dados."
    echo "       Esperado no Docker Desktop (macOS/Windows); em Linux nao acontece."
fi
[ -z "$SOCK" ]  && SOCK=/var/run/docker.sock
[ -z "$CSOCK" ] && CSOCK=/run/containerd/containerd.sock

# Hash do conteudo de cada diretorio de config.
#
# Os arquivos de configuracao entram por bind mount, e `docker compose up -d`
# NAO recria um container por causa deles: ele compara a ESPECIFICACAO do
# servico, nao o conteudo dos arquivos montados. MEDIDO -- ao acrescentar um
# job ao prometheus.yml e rodar `up -d`, o compose responde "Container Running"
# e o job nao existe.
#
# O sintoma era mudo e caro: a pasta System Health aparecia (o Grafana FOI
# recriado, porque ganhou um mount novo) mas os tres dashboards ficavam
# vazios, porque o Prometheus seguia com a config antiga e sem os jobs.
#
# Passando o hash como variavel de ambiente, a especificacao do servico muda
# quando o arquivo muda, e o proprio compose recria so' o que precisa.
hash_de() {
    find "$1" -type f 2>/dev/null | LC_ALL=C sort | xargs cat 2>/dev/null \
        | cksum | awk '{print $1}'
}

{ printf 'REDE_BANK=%s\n' "$REDE"
  for D in otelcol prometheus loki tempo alertmanager blackbox; do
      printf 'CONF_%s=%s\n' "$(echo "$D" | tr 'a-z' 'A-Z')" "$(hash_de "$STACK/$D")"
  done
  printf 'CONF_GRAFANA=%s\n' "$(hash_de "$STACK/grafana/provisioning")"
  printf 'DOCKER_SOCK=%s\n' "$SOCK"
  printf 'CONTAINERD_SOCK=%s\n' "$CSOCK"; } > "$STACK/.env"


# ------------------------------------------------------------------ subir
echo
echo "2. SUBINDO O STACK"
echo "--------------------------------------------------"

# ${PERFIS[@]+...}: no bash 3.2 do macOS, expandir um array VAZIO sob `set -u`
# aborta com "unbound variable". Esta forma expande para nada quando vazio.
docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" \
    ${PERFIS[@]+"${PERFIS[@]}"} up -d --remove-orphans >/dev/null 2>&1

# Um container que falha ao publicar porta fica CRIADO sem rede -- e um `up`
# seguinte apenas o INICIA, quebrado e em silencio: ele aparece "Up" no
# docker ps, mas sem porta e sem DNS. Ja aconteceu duas vezes aqui, entao
# nao basta conferir se esta rodando: conferimos se tem porta publicada.
#
# obs-otelcol e' a excecao legitima -- ele so' publica a 8007 do fluent_forward.
declare_porta() { case "$1" in
    obs-prometheus) echo 9090 ;; obs-loki) echo 3100 ;; obs-tempo) echo 3200 ;;
    obs-grafana) echo 3000 ;; obs-alertmanager) echo 9093 ;;
    obs-pushgateway) echo 9091 ;; obs-otelcol) echo 8006 ;; esac; }

for C in obs-otelcol obs-prometheus obs-loki obs-tempo obs-grafana obs-alertmanager obs-pushgateway; do
    P=$(declare_porta "$C")
    if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
        aviso "$C nao subiu -- recriando"
        docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" up -d --force-recreate "${C#obs-}" >/dev/null 2>&1
    elif ! docker port "$C" 2>/dev/null | grep -q "^${P}/"; then
        aviso "$C esta no ar sem publicar a porta $P -- recriando"
        docker compose -p "$PROJETO" -f "$STACK/docker-compose.yml" up -d --force-recreate "${C#obs-}" >/dev/null 2>&1
    fi
done

esperar() {
    local nome="$1" url="$2" i=0
    until curl -sf "$url" >/dev/null 2>&1 || [ $i -ge 45 ]; do i=$((i+1)); sleep 2; done
    if [ $i -ge 45 ]; then erro "$nome nao respondeu"; return 1; fi
    ok "$nome"
}

esperar "prometheus" "http://localhost:9090/-/ready"
esperar "loki"       "http://localhost:3100/ready"
esperar "tempo"      "http://localhost:3200/status"
esperar "grafana"    "http://localhost:3001/api/health"
docker ps --format '{{.Names}}' | grep -qx obs-otelcol && ok "otelcol"


# ------------------------------------------- religar a aplicacao no collector
if [ "$RELIGAR_APP" = "true" ]; then
    echo
    echo "3. APONTANDO O BANK-DEMO PARA ESTE COLLECTOR"
    echo "--------------------------------------------------"

    if [ ! -f "$BASE_APP/$COMPOSE_APP" ]; then
        erro "$BASE_APP/$COMPOSE_APP nao encontrado."
        echo "       Ajuste com: BASE_APP=/caminho bash run-stack.sh"
        exit 1
    fi

    ajustar_porta_dashboard

    gerar_env
    FS=(); while IFS= read -r linha; do FS+=("$linha"); done < <(compose_app)

    SAIDA=$( (cd "$BASE_APP" && docker compose "${FS[@]}" up -d) 2>&1 )
    if [ $? -eq 0 ]; then
        ok "servicos recriados apontando para otelcol:4317"
        PORTA_DASH=$(grep -E '^PORTA_DASHBOARD=' "$ENV_EFETIVO" | tail -1 | cut -d= -f2)
        [ -n "$PORTA_DASH" ] && echo "       dashboard em http://localhost:$PORTA_DASH"
    else
        erro "falha ao recriar os servicos"
        echo "$SAIDA" | tail -3 | sed 's/^/       /'
        exit 1
    fi
fi


# ------------------------------------------------------------------ validar
echo
echo "4. A TELEMETRIA ESTA CHEGANDO?"
echo "--------------------------------------------------"

SERIES=$(curl -s 'http://localhost:9090/api/v1/query?query=count(traces_span_metrics_calls_total)' 2>/dev/null \
         | grep -oE '"value":\[[0-9.]+,"[0-9]+"' | grep -oE '"[0-9]+"$' | tr -d '"')

if [ -z "$SERIES" ] || [ "$SERIES" = "0" ]; then
    aviso "nenhuma metrica derivada ainda."
    echo
    echo "       Isso e' ESPERADO sem transito: as metricas nascem dos traces."
    echo "       Gere carga e os paineis se preenchem em ~30s:"
    echo
    echo "         bash $AQUI/carga.sh --cenario todos --usuarios 5 --tempo 45s"
else
    ok "$SERIES series derivadas dos traces"
fi


# ------------------------------------------------------------------ acesso
IP=$(curl -s --max-time 3 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
H="${IP:-localhost}"

titulo "ACESSO"
echo
echo "  Grafana       http://$H:3001"
echo "  Prometheus    http://$H:9090"
echo
echo "  Service Map   Explore > Tempo > Service Graph"
echo "  Logs          Drilldown > Logs"
echo
[ -n "$IP" ] && echo "  (libere 3001 e 9090 no Security Group)" && echo
