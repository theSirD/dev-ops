#!/usr/bin/env bash
# Part 3: install Linkerd (CRDs, then control plane)
set -euo pipefail

command -v linkerd >/dev/null || { echo "missing linkerd CLI (brew install linkerd)" >&2; exit 1; }

# HTTPRoute (the split) comes from Gateway API, which Linkerd expects first
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
linkerd install --crds | kubectl apply -f -
# the CLI's default version-2.20 images are not published; native sidecar lets the k6 Job finish
linkerd install --set proxy.nativeSidecar=true --set linkerdVersion=edge-26.9.3 | kubectl apply -f -
linkerd check --wait 5m
