#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl create namespace policy-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null

for manifest in "$ROOT"/invalid-manifests/*.yaml; do
  echo "==> expecting rejection: $(basename "$manifest")"
  if kubectl -n policy-test apply -f "$manifest"; then
    echo "policy did not reject $(basename "$manifest")" >&2
    kubectl -n policy-test delete -f "$manifest" --ignore-not-found >/dev/null
    exit 1
  fi
done
