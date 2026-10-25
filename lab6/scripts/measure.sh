#!/usr/bin/env bash
# Parts 2 and 8: k6 order load, then CPU and memory of the same window from Prometheus.
#   ./scripts/measure.sh baseline | MESH=true ./scripts/measure.sh mesh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-run}"
RATE="${RATE:-10}"
DURATION="${DURATION:-3m}"
WINDOW="${WINDOW:-150s}"

prom() {
  local q
  q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=${q}" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "0")'
}

OUT=$(RATE="$RATE" DURATION="$DURATION" "$ROOT/scripts/load.sh")
sleep 20   # let Prometheus scrape the tail of the run

K6=$(printf '%s\n' "$OUT" | sed -n '/SLA SUMMARY/,/^}/p' | sed '1s/^SLA SUMMARY //')

python3 - "$LABEL" "$K6" \
  "$(prom "sum(rate(container_cpu_usage_seconds_total{namespace=\"shop\",container=\"api\"}[$WINDOW]))")" \
  "$(prom "sum(avg_over_time(container_memory_working_set_bytes{namespace=\"shop\",container=\"api\"}[$WINDOW]))")" \
  "$(prom "sum(rate(container_cpu_usage_seconds_total{namespace=\"shop\",container=\"linkerd-proxy\"}[$WINDOW]))")" \
  "$(prom "sum(avg_over_time(container_memory_working_set_bytes{namespace=\"shop\",container=\"linkerd-proxy\"}[$WINDOW]))")" \
  "$(prom "sum(rate(container_cpu_usage_seconds_total{namespace=\"client\",container=\"linkerd-proxy\"}[$WINDOW]))")" \
  "$(prom "sum(avg_over_time(container_memory_working_set_bytes{namespace=\"client\",container=\"linkerd-proxy\"}[$WINDOW]))")" \
  "$(prom "sum(rate(container_cpu_usage_seconds_total{namespace=\"linkerd\",container!=\"\"}[$WINDOW]))")" \
  "$(prom "sum(avg_over_time(container_memory_working_set_bytes{namespace=\"linkerd\",container!=\"\"}[$WINDOW]))")" <<'PY'
import json, sys
label, k6 = sys.argv[1], json.loads(sys.argv[2])
cpu_api, mem_api, cpu_px, mem_px, cpu_cpx, mem_cpx, cpu_cp, mem_cp = map(float, sys.argv[3:11])
mib = lambda b: b / 2**20
print(f"== {label}: {k6['rate_per_s']} req/s for {k6['duration']} ==")
print(f"requests            {k6['requests']}")
print(f"error rate          {k6['error_rate']*100:.2f} %")
print(f"latency p50 / p95   {k6['p50_ms']:.1f} ms / {k6['p95_ms']:.1f} ms")
print(f"api containers      CPU {cpu_api*1000:.0f} m   memory {mib(mem_api):.0f} MiB")
print(f"api sidecars        CPU {cpu_px*1000:.0f} m   memory {mib(mem_px):.0f} MiB")
print(f"client sidecar      CPU {cpu_cpx*1000:.0f} m   memory {mib(mem_cpx):.0f} MiB")
print(f"linkerd control     CPU {cpu_cp*1000:.0f} m   memory {mib(mem_cp):.0f} MiB")
PY
