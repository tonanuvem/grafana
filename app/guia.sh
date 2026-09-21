#!/usr/bin/env bash
# Sobe a pagina do LAB 2 num nginx.
#   bash guia.sh              porta 8031
#   bash guia.sh --porta 8041
#   bash guia.sh --parar
set -euo pipefail
cd "$(dirname "$0")"
IMAGEM=fiap-lab2-guia; CONTAINER=fiap-lab2-guia; PORTA="${PORTA:-8031}"; ACAO=subir
while [ $# -gt 0 ]; do
  case "$1" in
    --porta) PORTA="$2"; shift 2 ;;
    --parar) ACAO=parar; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERRO] opcao desconhecida: $1"; exit 1 ;;
  esac
done
if [ "$ACAO" = parar ]; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "[OK] $CONTAINER removido" || echo "[INFO] nao estava rodando"
  exit 0
fi
command -v docker >/dev/null || { echo "[ERRO] Docker nao encontrado"; exit 1; }
echo "[1/2] construindo"
docker build -q -t "$IMAGEM" . >/dev/null || { echo "[ERRO] build falhou. Rode sem -q para ver."; exit 1; }
echo "[2/2] subindo na porta $PORTA"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --restart unless-stopped -p "0.0.0.0:${PORTA}:80" "$IMAGEM" >/dev/null
IP=$(curl -s --max-time 4 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
echo
echo "  Guia do LAB 2:  http://${IP:-localhost}:${PORTA}"
echo
