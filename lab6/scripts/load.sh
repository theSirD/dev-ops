#!/usr/bin/env bash
# k6 Job in namespace client; MESH=true meshes it too (retries, split and client mTLS run in the caller's proxy)
#   ./scripts/load.sh | MESH=true ./scripts/load.sh --detach | ./scripts/load.sh --attach <job>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=client
RATE="${RATE:-10}"
DURATION="${DURATION:-3m}"
MESH="${MESH:-false}"
BASE_URL="${BASE_URL:-http://api.shop.svc:8000}"
PROM_RW="${PROM_RW:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write}"

wait_for_job() {
  local job="$1"
  until [[ "$(kubectl -n "$NS" get "job/$job" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" =~ [1] ]]; do
    sleep 5
  done
  kubectl -n "$NS" logs "job/$job" -c k6 | grep -A16 "SLA SUMMARY" || kubectl -n "$NS" logs "job/$job" -c k6 | tail -20
}

if [[ "${1:-}" == "--attach" ]]; then
  wait_for_job "${2:?job name required}"
  exit 0
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [[ "$MESH" == "true" ]]; then
  kubectl annotate namespace "$NS" linkerd.io/inject=enabled --overwrite >/dev/null
else
  kubectl annotate namespace "$NS" linkerd.io/inject- >/dev/null 2>&1 || true
fi
kubectl -n "$NS" create configmap order-js --from-file=order.js="$ROOT/k6/order.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

JOB="order-load-$(date +%s)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.57.0
          args: ["run", "--no-usage-report", "--out", "experimental-prometheus-rw", "/scripts/order.js"]
          env:
            - {name: BASE_URL, value: "${BASE_URL}"}
            - {name: RATE, value: "${RATE}"}
            - {name: DURATION, value: "${DURATION}"}
            - {name: K6_PROMETHEUS_RW_SERVER_URL, value: "${PROM_RW}"}
            - {name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),max"}
          volumeMounts:
            - {name: script, mountPath: /scripts}
      volumes:
        - name: script
          configMap: {name: order-js}
YAML

if [[ "${1:-}" == "--detach" ]]; then
  echo "$JOB"
  exit 0
fi

echo "k6 -> ${BASE_URL} rate=${RATE}/s duration=${DURATION} mesh=${MESH} (job/${JOB})"
wait_for_job "$JOB"
