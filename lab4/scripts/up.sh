#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER_NAME:-lab2}"
EVICTION_MEMORY="${EVICTION_MEMORY:-3500Mi}"

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

kind get clusters | grep -qx "$CLUSTER" || {
  echo "kind cluster $CLUSTER is required; start Lab 2 first" >&2
  exit 1
}

nodes=$(kubectl get nodes -o name | wc -l | tr -d ' ')
echo "cluster $CLUSTER has $nodes node(s) — Part 2 asks for strictly 1-2"
[[ "$nodes" -le 2 ]] || { echo "more than 2 nodes" >&2; exit 1; }

# Part 2: untaint control-plane so api can spread over both nodes
kubectl taint nodes \
  --selector=node-role.kubernetes.io/control-plane \
  node-role.kubernetes.io/control-plane:NoSchedule- \
  --overwrite=true 2>/dev/null || true

# kind ships without memory eviction; Part 7 needs it
for node in "${CLUSTER}-control-plane" "${CLUSTER}-worker"; do
  docker inspect "$node" >/dev/null 2>&1 || continue
  docker exec "$node" bash -s "$EVICTION_MEMORY" <<'INNER' || true
set -e
threshold="$1"
cfg=/var/lib/kubelet/config.yaml
if grep -q "memory.available" "$cfg"; then
  sed -i "s|memory.available:.*|memory.available: ${threshold}|" "$cfg"
else
  sed -i "s|^evictionHard:|evictionHard:\n  memory.available: ${threshold}|" "$cfg"
fi
systemctl restart kubelet
INNER
  printf '%s evictionHard.memory.available = ' "$node"
  docker exec "$node" sh -c 'grep -m1 "memory.available" /var/lib/kubelet/config.yaml | tr -d " "' || true
done
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

docker build -t lab3.local/shop-api:v1 "$ROOT/api"
docker build -t lab3.local/shop-worker:v1 "$ROOT/worker"
docker build -t lab3.local/shop-batch:v1 "$ROOT/batch"
docker build -t lab3.local/shop-load:v1 -f "$ROOT/load/Dockerfile" "$ROOT"
for image in shop-api shop-worker shop-batch shop-load; do
  kind load docker-image "lab3.local/${image}:v1" --name "$CLUSTER"
done

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
  --namespace shop --create-namespace --reset-values \
  --wait --timeout 8m

kubectl -n shop rollout status deployment/api --timeout=180s
kubectl -n shop rollout status deployment/worker --timeout=180s
kubectl -n shop rollout status deployment/batch --timeout=180s

echo
kubectl -n shop get pods -o custom-columns=\
'NAME:.metadata.name,QOS:.status.qosClass,PRIORITY:.spec.priorityClassName,NODE:.spec.nodeName'
echo
echo "load:   ./scripts/load.sh                 (k6 POST /order from inside the cluster)"
echo "demos:  ./scripts/demo.sh {spread|scarcity|preempt|pressure|status|reset}"
