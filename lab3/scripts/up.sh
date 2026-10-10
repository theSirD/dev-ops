#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER_NAME:-lab2}"

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

kind get clusters | grep -qx "$CLUSTER" || {
  echo "kind cluster $CLUSTER is required; start Lab 2 first" >&2
  exit 1
}

docker build -t lab3.local/shop-api:v1 "$ROOT/api"
docker build -t lab3.local/shop-worker:v1 "$ROOT/worker"
kind load docker-image lab3.local/shop-api:v1 --name "$CLUSTER"
kind load docker-image lab3.local/shop-worker:v1 --name "$CLUSTER"

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set admissionController.replicas=1 --wait --timeout 10m
kubectl apply -f "$ROOT/policies"

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --wait --timeout 5m

helm upgrade --install shop "$ROOT/charts/shop" \
  --namespace shop --create-namespace \
  --wait --timeout 8m

kubectl -n shop rollout status deployment/api --timeout=180s
kubectl -n shop rollout status deployment/worker --timeout=180s
echo "shop is ready; run: kubectl -n shop port-forward svc/api 8000:8000"
