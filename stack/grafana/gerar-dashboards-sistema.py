#!/usr/bin/env python3
# =============================================================================
# Gera a pasta "LAB GRAFANA - System Health" a partir dos dashboards oficiais
# =============================================================================
#   python3 stack/grafana/gerar-dashboards-sistema.py
#
# Os tres dashboards desta pasta NAO sao escritos a mao: sao os oficiais da
# comunidade, baixados do grafana.com e adaptados. Este script e' o registro de
# COMO foram adaptados -- sem ele, ninguem consegue atualizar para uma revisao
# nova sem refazer a investigacao toda.
#
# Ele precisa do Prometheus do lab NO AR (localhost:9090), porque a poda de
# paineis e' feita contra as metricas que existem de verdade, e nao contra uma
# lista escrita a mao que envelhece em silencio.
#
# POR QUE ESTA PASTA EXISTE
# Ela e' a CONTRAPROVA da tese do Encontro 2: durante o incidente de login da
# Fase 2, todos estes paineis ficam verdes. Nao e' "mais dashboards".
# =============================================================================

import io
import json
import os
import re
import urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(AQUI, "dashboards-sistema")

# O cache do download fica FORA de DEST. O provider do Grafana le todo .json do
# diretorio que provisiona -- inclusive um arquivo comecando com ponto. Com o
# cache la' dentro, a pasta ganhava SEIS dashboards: os tres adaptados e os
# tres originais, estes ultimos apontando para o datasource do autor e sem
# nenhuma poda. MEDIDO numa instalacao real.
CACHE = os.path.join(AQUI, ".cache-dashboards")
PROM = os.environ.get("PROM_URL", "http://localhost:9090")

# Revisoes PINADAS. Sem isto o lab muda sozinho quando o autor publica uma
# revisao nova -- o mesmo motivo de pinar as imagens no docker-compose.
FONTES = {
    "15983": 30,   # OpenTelemetry Collector
    "1860": 45,    # Node Exporter Full
    "15798": 13,   # Docker monitoring
}

PALAVRAS = {
    "sum", "rate", "irate", "avg", "max", "min", "count", "by", "without",
    "increase", "histogram_quantile", "label_replace", "label_join", "topk",
    "bottomk", "delta", "clamp_max", "clamp_min", "time", "on", "ignoring",
    "group_left", "group_right", "abs", "round", "ceil", "floor", "quantile",
    "stddev", "stdvar", "changes", "predict_linear", "deriv", "idelta",
    "resets", "last_over_time", "avg_over_time", "max_over_time",
    "min_over_time", "sum_over_time", "count_over_time", "stddev_over_time",
    "quantile_over_time", "absent", "absent_over_time", "vector", "scalar",
    "sort", "sort_desc", "exp", "ln", "log2", "log10", "sqrt", "or", "and",
    "unless", "offset", "bool", "if", "default", "node", "instance", "job",
}

AVISO = (
    "### Saúde de sistema não é saúde de negócio\n"
    "Esta pasta mostra a infraestrutura. Guarde o horário do incidente da "
    "**Fase 2** e volte aqui: enquanto clientes não conseguiam entrar no "
    "banco, **tudo nestes painéis ficou verde**. Nenhum destes números "
    "teria aberto um chamado — e nenhum deles estava errado."
)


# -----------------------------------------------------------------------------
# Explicacoes por painel.
#
# Os dashboards da comunidade descrevem a METRICA; o aluno precisa do CONCEITO.
# O peso esta no 15983 de proposito: ele e' o unico que fala do pipeline de
# telemetria em si -- o assunto que o resto do encontro pressupoe funcionando.
# -----------------------------------------------------------------------------
EXPLICACOES = {
 "15983": {
  "Spans Rate":
    "**Receiver** é a porta de entrada do collector. `accepted` são os spans "
    "que ele recebeu e admitiu; `refused` são os que ele **recusou** — quase "
    "sempre porque a fila de saída encheu e ele empurrou a pressão de volta "
    "para a aplicação.\n\nRecusa aqui é perda de *telemetria*, não de "
    "negócio: o banco segue funcionando e ninguém reclama. Por isso ela é "
    "perigosa — todos os outros painéis deste lab passam a mentir por omissão, "
    "sem avisar ninguém.",
  "Log Records Rate":
    "A mesma leitura dos spans, para log. Repare que há mais de um receiver: "
    "`otlp` traz o que os serviços Python enviam, `fluent_forward` traz o que o "
    "log driver do Docker recolhe do Node e do nginx, e `faro` traz o que "
    "acontece no navegador do cliente.\n\nTrês origens, um só destino: é isso "
    "que permite a mesma consulta no Loki alcançar servidor e navegador.",
  "Logs Records Rate Rate":
    "**Processor** é o que acontece *entre* receber e exportar. `incoming` é o "
    "que entrou no processador; `outgoing` é o que saiu.\n\nA diferença entre "
    "as duas linhas é exatamente o que aquele processador descartou ou criou. "
    "Se elas se separam sem você ter pedido, há perda silenciosa no meio do "
    "caminho.",
  "Batch Send Size Heatmap":
    "O collector não envia span a span: ele junta em lotes. Cada faixa mostra "
    "quantos itens tinha cada lote enviado.\n\nLote grande usa menos rede e "
    "menos CPU, mas atrasa o dado — e atraso aqui vira atraso na detecção. É a "
    "mesma escolha do intervalo de coleta do Prometheus, do outro lado do "
    "pipeline.",
  "Batch Metrics 1":
    "Quantos lotes saíram e qual o tamanho médio. Compare com o mapa de calor "
    "ao lado: aqui está a média, lá está a distribuição — e é a distribuição "
    "que mostra a cauda.",
  "Batch Metrics 2":
    "Por que cada lote foi enviado. `size_trigger` significa que ele encheu e "
    "partiu; `timeout_trigger`, que não encheu mas o tempo acabou.\n\nCom "
    "trânsito baixo quase tudo é timeout: esse é o piso de latência da sua "
    "telemetria, e ele existe mesmo quando nada está errado.",
  "Exporter Queue Size":
    "**Exporter** é a porta de saída. Antes dela há uma **fila**, que absorve "
    "picos e indisponibilidade temporária do destino.\n\nFila subindo "
    "significa que o collector está produzindo mais rápido do que o Tempo ou o "
    "Loki conseguem engolir. Enquanto ela não enche, ninguém percebe nada.",
  "Exporter Queue Capacity":
    "O teto da fila. Sozinho não diz nada — ele só importa comparado com o "
    "tamanho atual, no painel ao lado.",
  "Exporter Queue Usage":
    "A razão entre os dois anteriores, e o número que vale acompanhar. "
    "Chegando a 100%, o próximo dado não entra na fila: vira `refused` lá no "
    "receiver, e a telemetria começa a ser descartada.\n\nÉ este painel que "
    "responde à pergunta *posso confiar no que os outros dashboards mostram?*",
  "Total RSS Memory":
    "Memória real do processo do collector. Ele guarda estado: o conector "
    "`service_graph` mantém pares cliente/servidor em memória por 30 segundos "
    "para conseguir parear as duas pontas de cada chamada.\n\nMais serviços e "
    "mais rotas custam memória aqui — observabilidade não é de graça.",
  "CPU Usage":
    "CPU do collector. Cada processador que você acrescenta à pipeline passa "
    "por aqui: o `transform` que normaliza o status HTTP e o `filter` que corta "
    "as bordas custam este número.",
  "Uptime by Service Instance":
    "Há quanto tempo o collector está de pé. Uma queda aqui zera as filas e "
    "perde o que estava nelas — e o buraco resultante nos outros dashboards não "
    "se parece com incidente de aplicação, se parece com silêncio.",
 },
 "1860": {
  "CPU Basic":
    "CPU do **host**, não dos containers. Este é o painel clássico de "
    "infraestrutura — e o ponto do encontro é que ele fica verde durante o "
    "incidente da Fase 2: recusar login não consome CPU.",
  "Memory Basic":
    "Memória do host. Repare em `Cache + Buffer`: é memória usada pelo sistema "
    "de arquivos e liberada sob pressão. Ler *memória cheia* aqui como problema "
    "é o erro mais comum deste painel.",
 },
 "15798": {
  "Running containers":
    "Quantos containers estão de pé. É o painel que muda quando você derruba um "
    "serviço — e um dos poucos desta pasta que reage ao que o lab faz.",
  "CPU Usage":
    "CPU por container. Serve para saber **quem** consome, não se o cliente "
    "conseguiu. A degradação desta aula é latência injetada por variável de "
    "ambiente: ela não aparece aqui, de propósito.",
 },
}


# Frase acrescentada ao TITULO da linha. Vai no titulo, e nao num painel de
# texto, porque a linha pode estar recolhida -- e recolhida e' justamente
# quando o aluno mais precisa saber o que ha' la' dentro.
TITULO_DE_LINHA = {
 "15983": {
  "Receivers": "por onde a telemetria entra no collector",
  "Processors": "o que acontece com ela entre entrar e sair",
  "Exporters": "por onde ela sai, e a fila que a segura antes disso",
  "Collector": "o custo do próprio processo que faz tudo isso",
  "Signal flows": "o desenho de cada pipeline, a partir do que passa por ela",
 },
}

# Texto inserido logo abaixo de uma linha, para explicar o que vem a seguir.
TEXTO_DE_LINHA = {
 "15983": {
  "Signal flows":
    "### O caminho que cada sinal percorre\n"
    "Cada grafo abaixo é **uma pipeline do collector**, desenhada a partir do "
    "que está realmente passando por ela — não de um diagrama escrito à mão.\n\n"
    "Leia da esquerda para a direita: os **receivers** (`otlp`, `fluent_forward`, "
    "`faro`) entregam aos **processors**, que entregam aos **exporters** "
    "(`otlp_grpc/tempo`, `otlp_http/loki`, `prometheus`). A espessura da ligação "
    "é o volume.\n\n"
    "São três grafos porque são três sinais independentes: **traces**, "
    "**métricas** e **logs** seguem caminhos diferentes dentro do mesmo "
    "processo.",
 },
}


def baixar(ident, revisao):
    os.makedirs(CACHE, exist_ok=True)
    destino = os.path.join(CACHE, "%s.json" % ident)
    if not os.path.exists(destino):
        url = "https://grafana.com/api/dashboards/%s/revisions/%s/download" % (
            ident, revisao)
        with urllib.request.urlopen(url, timeout=60) as r:
            io.open(destino, "wb").write(r.read())
    return json.load(io.open(destino, encoding="utf-8"))


def metricas_vivas():
    url = "%s/api/v1/label/__name__/values" % PROM
    return set(json.load(urllib.request.urlopen(url, timeout=30))["data"])


def metricas_de(expr):
    expr = re.sub(r"\$\{[^}]+\}", "", expr)
    expr = re.sub(r"\$[a-zA-Z_][a-zA-Z0-9_]*", "", expr)
    return {m for m in re.findall(r"\b([a-zA-Z_][a-zA-Z0-9_:]*)\b", expr)
            if m not in PALAVRAS and not m.isdigit()}


def tem_dado(painel, vivas):
    exprs = [t["expr"] for t in (painel.get("targets") or [])
             if isinstance(t.get("expr"), str)]
    if not exprs:
        return True          # texto, linha: nao consulta nada
    for e in exprs:
        nomes = metricas_de(e)
        if not nomes or (nomes & vivas):
            return True
    return False


def normalizar_ds(o, uid="prom"):
    """Troca a referencia de datasource do autor pela do lab.

    Os tres dashboards referenciam o datasource de tres jeitos diferentes:
    variavel (${datasource}, ${ds_prometheus}) e input de importacao
    (${DS_GRAFANACLOUD-...}). Todos viram o uid `prom`.
    """
    if isinstance(o, dict):
        if ("uid" in o and set(o) <= {"type", "uid"}
                and isinstance(o["uid"], str) and o["uid"].startswith("${")):
            return {"type": o.get("type", "prometheus"), "uid": uid}
        return {k: normalizar_ds(v, uid) for k, v in o.items()}
    if isinstance(o, list):
        return [normalizar_ds(v, uid) for v in o]
    if isinstance(o, str) and o.startswith("${DS_") and o.endswith("}"):
        return uid
    return o


def corrigir_cadvisor(o):
    """Troca o label `container` por `name` no dashboard de containers.

    O autor agrupa por `container`, que e' um label do kubelet -- o cAdvisor
    puro nao o emite. O resultado e' `sum by (container)` colapsando TUDO numa
    serie so', com o label vazio: o grafico mostra uma linha chamada "Value" em
    vez de uma por container, e o seletor de container nasce vazio.
    """
    if isinstance(o, dict):
        return {k: corrigir_cadvisor(v) for k, v in o.items()}
    if isinstance(o, list):
        return [corrigir_cadvisor(v) for v in o]
    if isinstance(o, str):
        return (o.replace("by (container)", "by (name)")
                 .replace('container=~"$container"', 'name=~"$container"')
                 .replace('instance=~"$node"},container)',
                          'instance=~"$node"},name)'))
    return o


def ajustar_variaveis(d):
    remover = []
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource":
            # Sem fixar, o aluno abre o dashboard e encontra um seletor vazio.
            v["current"] = {"text": "Prometheus", "value": "prom"}
            v["hide"] = 2

        # Ver resolver_marcadores(): estas duas saem do dashboard.
        if v.get("name") in ("divider", "suffix_total"):
            remover.append(v)
    for v in remover:
        d["templating"]["list"].remove(v)


def resolver_marcadores(o):
    """Substitui ${divider} e ${suffix_total} pelo valor real, nas proprias
    expressoes.

    O 15983 tenta descobrir em tempo de execucao se o collector separa palavras
    com ponto ou sublinhado, e se as metricas terminam em `_total`. Ele descobre
    lendo o label `service.instance.id` de otelcol_process_uptime -- que o nosso
    collector NAO emite (MEDIDO: a metrica so' traz __name__, instance e job).
    As variaveis ficavam vazias, o nome do label virava "otelsignal" em vez de
    "otel.signal", e tres paineis mostravam "No data" para sempre.

    Transformar as duas em variaveis `constant` NAO resolve: uma constante
    vazia quebra a interpolacao ("Variable format value not found" no console) e
    o dashboard inteiro deixa de renderizar -- MEDIDO. Por isso o valor entra
    direto na expressao e as variaveis somem.

    Os dois valores sao constantes conhecidas porque a versao do collector e'
    pinada, e ambos foram MEDIDOS: o label e' `otel.signal` e nenhuma metrica
    otelcol_* termina em `_total`.
    """
    if isinstance(o, dict):
        return {k: resolver_marcadores(v) for k, v in o.items()}
    if isinstance(o, list):
        return [resolver_marcadores(v) for v in o]
    if isinstance(o, str):
        for marcador in ("${divider:raw}", "${divider}", "$divider"):
            o = o.replace(marcador, ".")
        for marcador in ("${suffix_total}", "$suffix_total"):
            o = o.replace(marcador, "")
    return o


# Paineis podados por decisao, e nao por falta de metrica. A poda automatica
# nao os pega -- em ambos os casos a familia da metrica EXISTE.
#
#   15983 / "Metric Points": a familia otelcol_processor_incoming_items existe,
#   mas nao ha serie com otel.signal="metrics". A pipeline `metrics/derivadas`
#   nao tem processador nenhum, porque os receivers dela sao connectors.
#   Tentei resolver na origem, acrescentando um `batch` aquela pipeline: nao
#   resolve. MEDIDO -- o batch publica apenas otelcol_processor_batch_* e nunca
#   incoming/outgoing items.
#
#   15983 / "Service Instance Details": consulta os labels "service.instance.id"
#   e "service.version", que o nosso collector nao emite -- MEDIDO,
#   otelcol_process_uptime so' traz __name__, instance e job.
#
#   1860 / SWAP: a EC2 do laboratorio nao tem swap, entao os dois medidores
#   ficam em N/A, um deles em VERMELHO. Nao ha nada errado ali -- e' so' um
#   alarme falso permanente na primeira tela que o aluno abre.
#   A poda e' incondicional de proposito: se dependesse do valor medido, o
#   JSON versionado mudaria conforme a maquina onde o gerador rodou (esta,
#   por exemplo, tem 1 GiB de swap).
PODAR_EXPLICITO = {
    "15983": {"Metric Points ${metric:text}", "Service Instance Details"},
    "1860": {"SWAP Used", "SWAP Total"},
}


def podar(paineis, vivas, cortados, podar_tambem=frozenset()):
    saida = []
    for p in paineis:
        if p.get("type") == "row":
            if p.get("panels"):
                p["panels"] = podar(p["panels"], vivas, cortados, podar_tambem)
            saida.append(p)
        elif p.get("title") in podar_tambem:
            cortados.append(p.get("title"))
        elif tem_dado(p, vivas):
            saida.append(p)
        else:
            cortados.append(p.get("title") or p.get("type"))
    return saida


def tirar_linhas_vazias(paineis):
    """Remove linhas que ficaram sem painel algum depois da poda.

    Uma linha vazia e' pior que ausencia: o aluno expande esperando conteudo,
    nao encontra nada e conclui que o lab esta quebrado.
    """
    saida = []
    for i, p in enumerate(paineis):
        if p.get("type") == "row" and not p.get("panels"):
            resto = paineis[i + 1:]
            prox = next((q for q in resto if q.get("type") != "row"), None)
            prox_row = next((q for q in resto if q.get("type") == "row"), None)
            vazia = prox is None or (
                prox_row is not None
                and resto.index(prox_row) < resto.index(prox))
            if vazia:
                continue
        saida.append(p)
    return saida


def _linhas_da_secao(secao):
    """Divide uma secao em linhas para reencaixe.

    Agrupa pelo `y` de origem, que e' a intencao do autor. Dentro de um grupo
    com ALTURAS diferentes, separa por altura: o 1860 poe medidores altos e
    stats baixos lado a lado, e tratar os dois como uma linha so' deixava os
    stats orfaos num vao. Por fim une linhas vizinhas de mesma altura que
    caibam juntas -- e' o que reagrupa os quatro stats do 1860, que o autor
    tinha espalhado em duas sublinhas na margem direita.
    """
    por_y, ordem = {}, []
    for q in secao:
        yo = (q.get("gridPos") or {}).get("y", 0)
        if yo not in por_y:
            por_y[yo] = []
            ordem.append(yo)
        por_y[yo].append(q)

    linhas = []
    for yo in ordem:
        grupo = por_y[yo]
        alturas = []
        for q in grupo:
            h = int((q.get("gridPos") or {}).get("h", 8))
            if h not in alturas:
                alturas.append(h)
        for h in sorted(alturas, reverse=True):
            linhas.append([q for q in grupo
                           if int((q.get("gridPos") or {}).get("h", 8)) == h])

    unidas = []
    for linha in linhas:
        largura = sum(int((q.get("gridPos") or {}).get("w", 8)) for q in linha)
        altura = int((linha[0].get("gridPos") or {}).get("h", 8))
        if unidas:
            ant = unidas[-1]
            alt_ant = int((ant[0].get("gridPos") or {}).get("h", 8))
            larg_ant = sum(int((q.get("gridPos") or {}).get("w", 8)) for q in ant)
            if alt_ant == altura and larg_ant + largura <= 24:
                ant.extend(linha)
                continue
        unidas.append(list(linha))
    return unidas


def compactar(paineis):
    """Fecha os buracos que a poda abriu, sem redesenhar o que estava bom."""
    y = 0
    i = 0
    while i < len(paineis):
        p = paineis[i]
        if p.get("type") == "row":
            p["gridPos"] = {"x": 0, "y": y, "w": 24, "h": 1}
            y += 1
            i += 1
            continue

        secao = []
        while i < len(paineis) and paineis[i].get("type") != "row":
            secao.append(paineis[i])
            i += 1

        for linha in _linhas_da_secao(secao):
            larguras = [max(1, int((q.get("gridPos") or {}).get("w", 8)))
                        for q in linha]
            total = sum(larguras)
            alvo = min(24, max(int(linha[0].get("_alvo_linha", 24)), total))
            intacta = total == alvo
            if total < alvo:
                # Reparte proporcionalmente e entrega as colunas que sobram do
                # arredondamento uma a uma, para quem tem a maior fracao
                # pendente. Arredondar cada uma e jogar a diferenca no ultimo
                # painel deixava o ultimo com largura 1 -- ilegivel.
                exatos = [w * alvo / total for w in larguras]
                larguras = [max(1, int(e)) for e in exatos]
                resto = sorted(range(len(exatos)),
                               key=lambda k: exatos[k] - int(exatos[k]),
                               reverse=True)
                k = 0
                while sum(larguras) < alvo:
                    larguras[resto[k % len(resto)]] += 1
                    k += 1
            x = 0
            altura = 0
            for q, w in zip(linha, larguras):
                g = q.get("gridPos") or {}
                h = int(g.get("h", 8))
                q["gridPos"] = {"x": g.get("x", x) if intacta else x,
                                "y": y, "w": w, "h": h}
                x += w
                altura = max(altura, h)
            y += altura
    return paineis


def preparar(ident, uid, titulo, tags, vivas, manter_rows=None):
    d = baixar(ident, FONTES[ident])
    for chave in ("__inputs", "__requires", "id"):
        d.pop(chave, None)
    d = normalizar_ds(d)
    if ident == "15798":
        d = corrigir_cadvisor(d)
    d.update({"uid": uid, "title": titulo, "tags": tags, "editable": True,
              "refresh": "30s", "time": {"from": "now-1h", "to": "now"}})
    ajustar_variaveis(d)
    d = resolver_marcadores(d)

    paineis = d.get("panels", [])

    # Largura que a linha ocupava ANTES da poda. E' o alvo para reencaixar os
    # sobreviventes: se o autor deixou uma linha curta de proposito (dois stats
    # estreitos ao lado de um vao), esticar ate 24 estragaria o arranjo dele.
    largura_original = {}
    for q in paineis:
        if q.get("type") == "row":
            continue
        g = q.get("gridPos") or {}
        largura_original[g.get("y", 0)] = (
            largura_original.get(g.get("y", 0), 0) + int(g.get("w", 8)))
    for q in paineis:
        if q.get("type") != "row":
            q["_alvo_linha"] = largura_original.get(
                (q.get("gridPos") or {}).get("y", 0), 24)

    if manter_rows is not None:
        # O 1860 tem 31 paineis e 284 queries. As duas primeiras linhas ja' vem
        # expandidas e cobrem CPU, memoria, disco, rede e load; as outras 14
        # vem colapsadas e sao detalhe (NVMe, mmcblk, netstat). Cortar pela
        # propria estrutura do dashboard, e nao painel a painel.
        manter, guardando = [], True
        for p in paineis:
            if p.get("type") == "row":
                guardando = p.get("title") in manter_rows
                if guardando:
                    manter.append(p)
                continue
            if guardando:
                manter.append(p)
        paineis = manter

    for q in paineis:
        texto = EXPLICACOES.get(ident, {}).get(q.get("title"))
        if texto:
            q["description"] = texto

    cortados = []
    paineis = tirar_linhas_vazias(
        podar(paineis, vivas, cortados, PODAR_EXPLICITO.get(ident, frozenset())))

    # Uma frase no titulo da linha, visivel mesmo com a linha recolhida.
    for q in paineis:
        if q.get("type") == "row":
            frase = TITULO_DE_LINHA.get(ident, {}).get(q.get("title"))
            if frase:
                q["title"] = "%s \u2014 %s" % (q["title"], frase)

    # Texto explicativo logo abaixo da linha a que ele se refere.
    for titulo_linha, conteudo in TEXTO_DE_LINHA.get(ident, {}).items():
        for k, q in enumerate(paineis):
            if q.get("type") == "row" and q.get("title") == titulo_linha:
                paineis.insert(k + 1, {
                    "type": "text", "title": "", "transparent": True,
                    "gridPos": {"h": 5, "w": 24, "x": 0, "y": -1},
                    "options": {"mode": "markdown", "content": conteudo},
                })
                break

    paineis = compactar(paineis)

    # O cabecalho entra DEPOIS de compactar. Inserido antes, ele dividia o
    # `y` com a primeira linha do autor: no dashboard de containers os cinco
    # stats acabavam empurrados para as colunas 24 a 48, fora da grade, e o
    # Grafana os empilhava na margem direita.
    for q in paineis:
        q["gridPos"]["y"] += 3
    paineis.insert(0, {
        "type": "text", "title": "", "transparent": True,
        "gridPos": {"h": 3, "w": 24, "x": 0, "y": 0},
        "options": {"mode": "markdown", "content": AVISO},
    })
    d["panels"] = paineis
    for q in d["panels"]:
        q.pop("_alvo_linha", None)

    io.open(os.path.join(DEST, uid + ".json"), "w", encoding="utf-8").write(
        json.dumps(d, indent=2, ensure_ascii=False) + "\n")
    print("  %-38s %2d paineis de topo | %2d cortados"
          % (titulo, len(paineis), len(cortados)))
    return cortados


def main():
    os.makedirs(DEST, exist_ok=True)
    # Limpa o cache de uma versao anterior que o guardava dentro de DEST.
    for velho in os.listdir(DEST):
        if velho.startswith(".fonte-"):
            os.remove(os.path.join(DEST, velho))
            print("  removido do diretorio provisionado: %s" % velho)
    vivas = metricas_vivas()
    print("metricas vivas no Prometheus: %d\n" % len(vivas))
    if len(vivas) < 100:
        raise SystemExit(
            "  Poucas metricas. O stack esta no ar e ja' recebeu trafego?\n"
            "  As metricas de receiver do collector so' nascem com trafego.")

    # Numerados para dar ordem de leitura: do host para dentro, terminando no
    # pipeline que produz tudo o que os outros dashboards mostram.
    preparar("1860", "sys-node", "1 · Host",
             ["lab", "sistema", "host"], vivas,
             manter_rows={"Quick CPU / Mem / Disk",
                          "Basic CPU / Mem / Net / Disk"})
    preparar("15798", "sys-docker", "2 · Containers",
             ["lab", "sistema", "containers"], vivas)
    preparar("15983", "sys-otelcol", "3 · OpenTelemetry Collector",
             ["lab", "sistema", "pipeline"], vivas)


if __name__ == "__main__":
    main()
