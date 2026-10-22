#!/usr/bin/env bash
# Part 3: krr report -> krr-report.txt (krr needs at least 1h of Prometheus data)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROM="${PROM_URL:-http://127.0.0.1:9090}"
WINDOW="${WINDOW:-1h}"
OUT="$ROOT/krr-report.txt"

curl -fsS "$PROM/-/healthy" >/dev/null || {
  echo "run: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090" >&2
  exit 1
}

{
  echo "# krr simple -n shop -r Deployment --history-duration 1 --timeframe_duration 0.25"
  COLUMNS=260 krr simple -n shop -r Deployment --prometheus-url "$PROM" \
    --history-duration 1 --timeframe_duration 0.25 -f table 2>/dev/null | sed -n '/┏/,$p'
  echo
  echo "# postgres (CNPG Cluster, not visible to krr): Simple formula on Prometheus, last $WINDOW"
  q() { curl -fsS --get "$PROM/api/v1/query" --data-urlencode "query=$1" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "n/a")'; }
  # CNPG pods are not a kind krr lists: same Simple formula on Prometheus
  cpu=$(q "quantile_over_time(0.95, max(rate(container_cpu_usage_seconds_total{namespace=\"shop\",pod=\"postgres-1\",container=\"postgres\"}[1m]))[$WINDOW:15s])")
  mem=$(q "max_over_time(max(container_memory_working_set_bytes{namespace=\"shop\",pod=\"postgres-1\",container=\"postgres\",image!=\"\"})[$WINDOW:15s])")
  python3 - "$cpu" "$mem" <<'PY'
import sys
cpu, mem = float(sys.argv[1]), float(sys.argv[2])
print(f"postgres: cpu p95 = {cpu*1000:.0f}m; memory peak {mem/2**20:.0f}Mi +15% = {mem*1.15/2**20:.0f}Mi (krr floor: 100Mi)")
PY
} | tee "$OUT"
