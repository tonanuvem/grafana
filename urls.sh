IP=$(curl -s --max-time 4 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
H="${IP:-localhost}"

#echo
# echo "  Guia do aluno  http://$H:8031"
echo
echo "=================================================="
echo " GRAFANA STACK (OBSERVABILIDADE)"
echo "=================================================="
echo
echo "  Grafana        http://$H:3001"
echo
echo "  Prometheus     http://$H:9090"
echo
echo "  Alertmanager   http://$H:9093"
echo
