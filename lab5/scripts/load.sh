#!/usr/bin/env bash
# Part 2 client load: k6 in namespace client calls api by Service name; metrics go to Prometheus
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=client
RATE="${RATE:-10}"
DURATION="${DURATION:-3m}"
BASE_URL="${BASE_URL:-http://api.shop.svc:8000}"
PROM_RW="${PROM_RW:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write}"

wait_for_job() {
  local job="$1"
  until [[ "$(kubectl -n "$NS" get "job/$job" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" =~ [1] ]]; do
    sleep 5
  done
  kubectl -n "$NS" logs "job/$job" | grep -A16 "SLA SUMMARY" || kubectl -n "$NS" logs "job/$job" | tail -20
  [[ "$(kubectl -n "$NS" get "job/$job" -o jsonpath='{.status.succeeded}')" == "1" ]]
}

if [[ "${1:-}" == "--attach" ]]; then
  wait_for_job "${2:?job name required}"
  exit $?
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap order-js --from-file=order.js="$ROOT/k6/order.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

JOB="order-load-$(date +%s)"
kubectl apply -f - >/dev/null <<EOF
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
EOF

if [[ "${1:-}" == "--detach" ]]; then
  echo "$JOB"
  exit 0
fi

echo "k6 -> ${BASE_URL} rate=${RATE}/s duration=${DURATION} (job/${JOB})"
wait_for_job "$JOB"
