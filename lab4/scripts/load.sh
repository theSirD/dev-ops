#!/usr/bin/env bash
# k6 as an in-cluster Job (no port-forward); --detach prints the job, --attach waits for it
set -euo pipefail

NS="${NS:-shop}"
RATE="${RATE:-10}"
DURATION="${DURATION:-3m}"
SLA_P95_MS="${SLA_P95_MS:-2000}"
SLA_ERROR_RATE="${SLA_ERROR_RATE:-0.01}"
BASE_URL="${BASE_URL:-http://api:8000}"
IMAGE="${LOAD_IMAGE:-lab3.local/shop-load:v1}"

wait_for_job() {
  local job="$1" deadline=$((SECONDS + 7200))
  while (( SECONDS < deadline )); do
    local succeeded failed
    succeeded=$(kubectl -n "$NS" get "job/$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    failed=$(kubectl -n "$NS" get "job/$job" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [[ "${succeeded:-0}" -ge 1 ]] && { kubectl -n "$NS" logs "job/$job"; return 0; }
    [[ "${failed:-0}" -ge 1 ]]    && { kubectl -n "$NS" logs "job/$job"; return 1; }
    sleep 5
  done
  echo "timed out waiting for job/$job" >&2
  return 2
}

if [[ "${1:-}" == "--attach" ]]; then
  wait_for_job "${2:?job name required}"
  exit $?
fi

detach=false
[[ "${1:-}" == "--detach" ]] && detach=true

JOB="order-load-$(date +%s)"

kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: shop
    app.kubernetes.io/instance: shop
    app.kubernetes.io/component: load
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shop
        app.kubernetes.io/instance: shop
        app.kubernetes.io/component: load
    spec:
      restartPolicy: Never
      priorityClassName: shop-critical
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: k6
          image: ${IMAGE}
          imagePullPolicy: Never
          args: ["run", "--no-usage-report", "/scripts/order.js"]
          env:
            - {name: BASE_URL,       value: "${BASE_URL}"}
            - {name: RATE,           value: "${RATE}"}
            - {name: DURATION,       value: "${DURATION}"}
            - {name: SLA_P95_MS,     value: "${SLA_P95_MS}"}
            - {name: SLA_ERROR_RATE, value: "${SLA_ERROR_RATE}"}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: 500m, memory: 256Mi}
          securityContext:
            privileged: false
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
EOF

if $detach; then
  echo "$JOB"
  exit 0
fi

echo "k6 -> ${BASE_URL} rate=${RATE}/s duration=${DURATION} sla=p95<${SLA_P95_MS}ms,err<${SLA_ERROR_RATE} (job/${JOB})"
wait_for_job "$JOB"
