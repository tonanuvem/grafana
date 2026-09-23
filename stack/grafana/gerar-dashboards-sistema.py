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


def podar(paineis, vivas, cortados):
    saida = []
    for p in paineis:
        if p.get("type") == "row":
            if p.get("panels"):
                p["panels"] = podar(p["panels"], vivas, cortados)
            saida.append(p)
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


def compactar(paineis):
    """Reencaixa os paineis da esquerda para a direita, sem buracos.

    A poda tira paineis do meio de uma linha e os que sobram mantem o `x`
    original: no dashboard do collector, cortar "Metric Points" de Receivers
    deixava um vao de 8 colunas entre os dois paineis restantes. O Grafana nao
    reflui sozinho -- a posicao e' explicita no JSON.
    """
    y = 0
    i = 0
    while i < len(paineis):
        p = paineis[i]
        if p.get("type") == "row":
            p["gridPos"] = {"x": 0, "y": y, "w": 24, "h": 1}
            y += 1
            i += 1
            continue

        grupo = []
        while i < len(paineis) and paineis[i].get("type") != "row":
            grupo.append(paineis[i])
            i += 1

        x = 0
        altura_linha = 0
        for q in grupo:
            g = q.get("gridPos") or {}
            w = min(int(g.get("w", 8)), 24)
            h = int(g.get("h", 8))
            if x + w > 24:
                y += altura_linha
                x = 0
                altura_linha = 0
            q["gridPos"] = {"x": x, "y": y, "w": w, "h": h}
            x += w
            altura_linha = max(altura_linha, h)
        y += altura_linha
    return paineis


def preparar(ident, uid, titulo, tags, vivas, manter_rows=None):
    d = baixar(ident, FONTES[ident])
    for chave in ("__inputs", "__requires", "id"):
        d.pop(chave, None)
    d = normalizar_ds(d)
    d.update({"uid": uid, "title": titulo, "tags": tags, "editable": True,
              "refresh": "30s", "time": {"from": "now-1h", "to": "now"}})
    ajustar_variaveis(d)
    d = resolver_marcadores(d)

    paineis = d.get("panels", [])
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

    cortados = []
    paineis = tirar_linhas_vazias(podar(paineis, vivas, cortados))

    paineis.insert(0, {
        "type": "text", "title": "", "transparent": True,
        "gridPos": {"h": 3, "w": 24, "x": 0, "y": 0},
        "options": {"mode": "markdown", "content": AVISO},
    })
    d["panels"] = compactar(paineis)

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

    preparar("15983", "sys-otelcol", "Pipeline · OpenTelemetry Collector",
             ["lab", "sistema", "pipeline"], vivas)
    preparar("1860", "sys-node", "Host · Node Exporter",
             ["lab", "sistema", "host"], vivas,
             manter_rows={"Quick CPU / Mem / Disk",
                          "Basic CPU / Mem / Net / Disk"})
    preparar("15798", "sys-docker", "Containers · Docker",
             ["lab", "sistema", "containers"], vivas)


if __name__ == "__main__":
    main()
