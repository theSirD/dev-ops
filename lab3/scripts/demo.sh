#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-}"
case "$mode" in
  reconcile-api)
    kubectl -n shop delete pod "$(kubectl -n shop get pod -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')"
    kubectl -n shop rollout status deploy/api --timeout=180s
    ;;
  replicas)
    replicas="${2:?usage: $0 replicas <count>}"
    helm upgrade shop "$ROOT/charts/shop" -n shop --set api.replicas="$replicas" --wait
    kubectl -n shop get pods -l app.kubernetes.io/component=api
    ;;
  broken-rollout)
    helm upgrade shop "$ROOT/charts/shop" -n shop --set api.healthFail=true --wait=false
    kubectl -n shop rollout status deploy/api --timeout=45s || true
    helm history shop -n shop
    ;;
  rollback)
    revision="${2:?usage: $0 rollback <healthy-revision>}"
    helm rollback shop "$revision" -n shop --wait --timeout 5m
    ;;
  alert)
    for _ in $(seq 1 90); do
      curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/fail || true
      sleep 1
    done
    echo "Inspect Alertmanager or Karma for ShopApiErrorRate."
    ;;
  control-plane-down)
    docker stop lab2-control-plane
    ;;
  control-plane-up)
    docker start lab2-control-plane
    kubectl wait --for=condition=Ready node/lab2-control-plane --timeout=180s
    ;;
  *)
    echo "usage: $0 {reconcile-api|replicas <count>|broken-rollout|rollback <healthy-revision>|alert|control-plane-down|control-plane-up}" >&2
    exit 1
    ;;
esac
