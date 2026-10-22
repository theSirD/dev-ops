#!/usr/bin/env bash
# Parts 4-7 demos; every change goes through helm upgrade
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-shop}"
CHART="$ROOT/charts/shop"
WORKER_NODE="${WORKER_NODE:-lab2-worker}"

helm_set() { helm upgrade shop "$CHART" -n "$NS" --reset-values "$@"; }

status() {
  kubectl -n "$NS" get pods -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,QOS:.status.qosClass,PRIORITY:.spec.priorityClassName,NODE:.spec.nodeName' \
    --sort-by=.metadata.name
}

case "${1:-}" in
  spread)
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=api -o wide
    echo
    echo "distinct nodes hosting api replicas:"
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=api \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u
    echo
    kubectl -n "$NS" get pod -l app.kubernetes.io/component=api \
      -o jsonpath='{.items[0].spec.topologySpreadConstraints}' | python3 -m json.tool
    ;;

  scarcity)
    # only batch.replicas changes; the scheduler counts requests, not usage
    replicas="${2:-6}"
    helm_set --set batch.replicas="$replicas" --wait=false
    echo "waiting for Pending batch replicas..."
    for _ in $(seq 1 24); do
      pending=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=batch \
        --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')
      [[ "$pending" -gt 0 ]] && break
      sleep 5
    done
    echo
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=batch -o wide
    echo
    echo "QoS of batch (must be Burstable):"
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=batch \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}' | sort -u
    echo
    echo "why they do not fit:"
    kubectl -n "$NS" get events --field-selector=reason=FailedScheduling \
      --sort-by=.lastTimestamp -o wide | tail -10 || true
    echo
    echo "allocated (requests) vs allocatable, per node:"
    for node in "${WORKER_NODE}" "${WORKER_NODE%-worker}-control-plane"; do
      echo "--- $node"
      kubectl describe node "$node" | sed -n '/Allocated resources/,/^Events/p' | head -8
    done
    ;;

  preempt)
    # cluster is full, so new api replicas preempt shop-low batch
    batch_replicas="${2:-6}"
    api_replicas="${3:-10}"
    before=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=batch \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
    helm_set --set batch.replicas="$batch_replicas" --set api.replicas="$api_replicas" --wait=false
    echo "waiting for preemption events..."
    for _ in $(seq 1 24); do
      if kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
         | grep -qi "preempt"; then break; fi
      sleep 5
    done
    echo
    echo "preemption events (high-priority api taking room from shop-low batch):"
    kubectl -n "$NS" get events --sort-by=.lastTimestamp -o wide | grep -iE "preempt" | tail -20 || true
    echo
    echo "batch pods that disappeared:"
    comm -23 <(echo "$before") <(kubectl -n "$NS" get pods -l app.kubernetes.io/component=batch \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort) || true
    echo
    kubectl -n "$NS" get pods -o wide
    ;;

  pressure)
    # memoryMb stays below the 2Gi limit, so kubelet evicts instead of cgroup OOM
    mb="${2:-1300}"
    replicas="${3:-2}"
    helm_set \
      --set batch.replicas="$replicas" \
      --set batch.memoryMb="$mb" \
      --set-string "batch.nodeSelector.kubernetes\\.io/hostname=${WORKER_NODE}" \
      --wait=false
    echo "batch limit = 2Gi (values.yaml), requested RSS = ${mb}Mi -> eviction must come from the kubelet, not the cgroup"
    echo "waiting for MemoryPressure / Evicted on ${WORKER_NODE} (up to ~4m)..."
    for _ in $(seq 1 48); do
      cond=$(kubectl get node "$WORKER_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null || true)
      evicted=$(kubectl -n "$NS" get pods -o json 2>/dev/null \
        | python3 -c 'import json,sys; print(sum(1 for p in json.load(sys.stdin)["items"] if p["status"].get("reason")=="Evicted"))' 2>/dev/null || echo 0)
      printf 'MemoryPressure=%s evicted_pods=%s\n' "${cond:-Unknown}" "$evicted"
      [[ "$evicted" -gt 0 ]] && break
      sleep 5
    done
    echo
    echo "node condition:"
    kubectl describe node "$WORKER_NODE" | grep -iE "MemoryPressure" | head -3
    echo
    echo "eviction events:"
    kubectl -n "$NS" get events --sort-by=.lastTimestamp -o wide \
      | grep -iE "Evicted|OOMKill|MemoryPressure" | tail -20 || true
    echo
    echo "who got evicted (reason/message):"
    kubectl -n "$NS" get pods -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    st = p["status"]
    if st.get("reason") == "Evicted":
        print(p["metadata"]["name"], "|", st.get("reason"), "|", st.get("message", "")[:120])
'
    echo
    echo "critical path (must still be Running/Guaranteed):"
    kubectl -n "$NS" get pods -l 'app.kubernetes.io/component in (api,worker)' -o wide
    kubectl -n "$NS" get pods -l cnpg.io/cluster=postgres -o wide
    ;;

  status)
    status
    ;;

  reset)
    # back to values.yaml (this also removes the k6 job)
    helm_set --wait --timeout 8m
    kubectl -n "$NS" delete pods --field-selector=status.phase=Failed --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NS" delete pods --field-selector=status.phase=Succeeded --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NS" delete job -l app.kubernetes.io/component=load --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status deployment/api --timeout=180s
    kubectl -n "$NS" rollout status deployment/worker --timeout=180s
    kubectl -n "$NS" rollout status deployment/batch --timeout=180s
    echo
    status
    ;;

  *)
    echo "usage: $0 {spread|scarcity [replicas]|preempt [batchReplicas] [apiReplicas]|pressure [memoryMb] [replicas]|status|reset}" >&2
    exit 1
    ;;
esac
