#!/usr/bin/env bash
# Lab 5: kind + Cilium + Lab 2 monitoring + CNPG + shop; stops the Lab 2/4 nodes to free the VM
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB2="$ROOT/../lab2"
CLUSTER="${CLUSTER_NAME:-lab5}"
CILIUM_VERSION="1.20.3"
PROM_STACK_VERSION="92.2.0"

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

for node in lab2-control-plane lab2-worker; do
  docker ps -q -f "name=^${node}$" | grep -q . && { echo "stopping $node (Lab 2/4 cluster)"; docker stop "$node" >/dev/null; }
done

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config "$ROOT/kind-config.yaml"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Part 1: pods on both nodes
kubectl taint nodes --selector=node-role.kubernetes.io/control-plane \
  node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --values "$ROOT/cilium-values.yaml" --wait --timeout 10m
kubectl wait --for=condition=Ready nodes --all --timeout=300s

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$PROM_STACK_VERSION" --namespace monitoring --create-namespace \
  --values "$LAB2/helm/kube-prometheus-stack-values.yaml" \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --wait --timeout 10m

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait --timeout 5m

docker build -t lab5.local/shop-api:v1 "$ROOT/api"
docker build -t lab5.local/shop-worker:v1 "$ROOT/worker"
for image in shop-api shop-worker; do
  kind load docker-image "lab5.local/${image}:v1" --name "$CLUSTER"
done

helm upgrade --install shop "$ROOT/charts/shop" \
  --namespace shop --create-namespace --reset-values --wait --timeout 8m

kubectl -n shop get pods -o wide
echo
echo "NodePort entry:  curl http://localhost:30080/health"
echo "Hubble UI:       cilium hubble ui  (or: kubectl -n kube-system port-forward svc/hubble-ui 12000:80)"
echo "Grafana:         kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   (admin/admin)"
echo "Prometheus:      kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
