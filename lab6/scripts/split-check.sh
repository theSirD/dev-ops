#!/usr/bin/env bash
# Part 5: ask GET /version N times from a meshed pod and count the answers.
set -euo pipefail

N="${1:-200}"
NS=client
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl annotate namespace "$NS" linkerd.io/inject=enabled --overwrite >/dev/null
kubectl -n "$NS" delete pod versions --ignore-not-found --wait=true >/dev/null 2>&1

kubectl -n "$NS" run versions --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/versions --timeout=120s >/dev/null

kubectl -n "$NS" exec versions -c versions -- sh -c \
  "for i in \$(seq 1 $N); do curl -s http://api.shop.svc:8000/version; echo; done" \
  | sort | uniq -c | awk -v n="$N" '{printf "%-4s %4d  (%.0f%%)\n", $2, $1, 100*$1/n}'

kubectl -n "$NS" delete pod versions --wait=false >/dev/null
