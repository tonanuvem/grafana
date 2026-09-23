#!/usr/bin/env python3
# =============================================================================
# Anota os dashboards do lab com a query que alimenta cada painel
# =============================================================================
#   python3 stack/grafana/anotar-queries.py
#
# O aluno ve o numero, mas nao ve de onde ele sai. Este script pega a query de
# cada painel e a coloca em dois lugares:
#
#   - no ⓘ do painel, como texto, para ler sem sair do dashboard;
#   - num link "Abrir no Explore", que abre a query pronta para editar.
#
# E' um script e nao uma edicao manual porque a query fica DUPLICADA: se
# alguem mudar o painel e nao mudar a descricao, o guia passa a mentir. Rodar
# de novo conserta. A anotacao e' delimitada por um marcador, entao rodar duas
# vezes nao empilha texto.
# =============================================================================

import io
import json
import os
import urllib.parse

AQUI = os.path.dirname(os.path.abspath(__file__))
DASHBOARDS = os.path.join(AQUI, "dashboards")

MARCA = "\n\n---\n**De onde vem este número**\n\n"


def datasource_do(painel, alvo):
    ds = alvo.get("datasource") or painel.get("datasource") or {}
    if isinstance(ds, str):
        return {"type": "prometheus", "uid": ds}
    return {"type": ds.get("type", "prometheus"), "uid": ds.get("uid", "prom")}


def url_do_explore(painel):
    alvos = [t for t in (painel.get("targets") or []) if t.get("expr")]
    if not alvos:
        return None
    ds = datasource_do(painel, alvos[0])
    panes = {
        "a": {
            "datasource": ds["uid"],
            "queries": [
                {"refId": t.get("refId", chr(65 + i)), "expr": t["expr"],
                 "datasource": ds}
                for i, t in enumerate(alvos)
            ],
            "range": {"from": "now-1h", "to": "now"},
        }
    }
    return "/explore?schemaVersion=1&orgId=1&panes=" + urllib.parse.quote(
        json.dumps(panes, separators=(",", ":")))


def anotar(painel):
    alvos = [t for t in (painel.get("targets") or []) if t.get("expr")]
    if not alvos:
        return False

    # Corta uma anotacao anterior antes de escrever a nova.
    desc = (painel.get("description") or "").split(MARCA)[0].rstrip()

    linhas = []
    for t in alvos:
        legenda = t.get("legendFormat")
        if legenda and len(alvos) > 1:
            linhas.append("*%s*" % legenda)
        linhas.append("```\n%s\n```" % t["expr"].strip())
    painel["description"] = desc + MARCA + "\n".join(linhas)

    url = url_do_explore(painel)
    if url:
        # Substitui so' o link que este script cria; outros links do painel,
        # se houver, continuam onde estao.
        outros = [l for l in (painel.get("links") or [])
                  if l.get("title") != "Abrir no Explore"]
        painel["links"] = outros + [
            {"title": "Abrir no Explore", "url": url, "targetBlank": True}
        ]
    return True


def percorrer(paineis):
    n = 0
    for p in paineis:
        if p.get("type") == "row":
            n += percorrer(p.get("panels") or [])
            continue
        if anotar(p):
            n += 1
    return n


def main():
    for nome in sorted(os.listdir(DASHBOARDS)):
        if not nome.endswith(".json"):
            continue
        caminho = os.path.join(DASHBOARDS, nome)
        d = json.load(io.open(caminho, encoding="utf-8"))
        n = percorrer(d.get("panels") or [])
        io.open(caminho, "w", encoding="utf-8").write(
            json.dumps(d, indent=2, ensure_ascii=False) + "\n")
        print("  %-28s %2d paineis anotados" % (nome, n))


if __name__ == "__main__":
    main()
