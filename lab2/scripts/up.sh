#!/usr/bin/env bash
# Bring up kind + the full Lab 2 observability stack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-lab2}"
IMAGE_NAME="${IMAGE_NAME:-lab2-api:latest}"
KUBE_PROMETHEUS_STACK_VERSION="92.2.0"
LOKI_VERSION="7.3.0"
ALLOY_VERSION="1.13.1"
JAEGER_VERSION="4.14.1"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need docker
need kind
need kubectl
need helm

echo "==> ensuring kind cluster '${CLUSTER_NAME}'"
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --config "${ROOT}/kind-config.yaml"
else
  echo "    cluster already exists"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
fi

echo "==> building api image ${IMAGE_NAME}"
docker build -t "${IMAGE_NAME}" "${ROOT}/api"

echo "==> loading image into kind"
kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

echo "==> helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> installing kube-prometheus-stack"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
  --namespace monitoring \
  --create-namespace \
  --values "${ROOT}/helm/kube-prometheus-stack-values.yaml" \
  --wait --timeout 10m

echo "==> installing loki"
helm upgrade --install loki grafana/loki \
  --version "${LOKI_VERSION}" \
  --namespace monitoring \
  --values "${ROOT}/helm/loki-values.yaml" \
  --wait --timeout 10m

echo "==> installing alloy (log collector DaemonSet)"
helm upgrade --install alloy grafana/alloy \
  --version "${ALLOY_VERSION}" \
  --namespace monitoring \
  --values "${ROOT}/helm/alloy-values.yaml" \
  --wait --timeout 5m

echo "==> installing jaeger"
helm upgrade --install jaeger jaegertracing/jaeger \
  --version "${JAEGER_VERSION}" \
  --namespace monitoring \
  --values "${ROOT}/helm/jaeger-values.yaml" \
  --wait --timeout 5m

echo "==> installing Jaeger service aliases"
helm upgrade --install jaeger-services "${ROOT}/charts/jaeger-services" \
  --namespace monitoring \
  --take-ownership \
  --wait --timeout 3m

echo "==> installing alert webhook receiver"
helm upgrade --install alert-webhook "${ROOT}/charts/webhook" \
  --namespace monitoring \
  --wait --timeout 3m

echo "==> installing karma"
helm upgrade --install karma "${ROOT}/charts/karma" \
  --namespace monitoring \
  --values "${ROOT}/helm/karma-values.yaml" \
  --wait --timeout 3m

echo "==> installing api"
helm upgrade --install api "${ROOT}/charts/api" \
  --namespace app \
  --create-namespace \
  --wait --timeout 5m

echo "==> waiting for api pods"
kubectl -n app rollout restart deployment/api
kubectl -n app rollout status deploy/api --timeout=180s

cat <<EOF

Stack is up.

Useful port-forwards (run in separate terminals):
  kubectl -n app port-forward svc/api 8000:8000
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
  kubectl -n monitoring port-forward svc/jaeger-query 16686:16686
  kubectl -n monitoring port-forward svc/karma 8080:8080

Grafana:  http://localhost:3000  (admin / admin)
Prometheus: http://localhost:9090
Alertmanager: http://localhost:9093
Jaeger: http://localhost:16686
Karma: http://localhost:8080
API: http://localhost:8000

Generate traffic:
  ${ROOT}/scripts/traffic.sh all
EOF
