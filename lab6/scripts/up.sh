#!/usr/bin/env bash
# Lab 6: one-node kind + Lab 2 monitoring + CNPG + shop without mesh (the baseline); stops lab2/lab5 nodes first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB2="$ROOT/../lab2"
CLUSTER="${CLUSTER_NAME:-lab6}"
PROM_STACK_VERSION="92.2.0"   # same as Lab 2

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

for node in lab2-control-plane lab2-worker lab5-control-plane lab5-worker; do
  docker ps -q -f "name=^${node}$" | grep -q . && { echo "stopping $node"; docker stop "$node" >/dev/null; }
done

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config "$ROOT/kind-config.yaml"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$PROM_STACK_VERSION" --namespace monitoring --create-namespace \
  --values "$LAB2/helm/kube-prometheus-stack-values.yaml" \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --wait --timeout 10m

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait --timeout 5m

docker build -t lab6.local/shop-api:v1 "$ROOT/api"
docker build -t lab6.local/shop-worker:v1 "$ROOT/worker"
for image in shop-api shop-worker; do
  kind load docker-image "lab6.local/${image}:v1" --name "$CLUSTER"
done

# values.yaml is the final state; the baseline is v1 alone, no mesh
helm upgrade --install shop "$ROOT/charts/shop" \
  --namespace shop --create-namespace --reset-values \
  --set mesh.enabled=false --set mesh.retries.enabled=false --set mesh.failureAccrual.enabled=false \
  --set api.versions.v2.enabled=false --set gate.enabled=false \
  --wait --timeout 8m

kubectl -n shop get pods -o wide
