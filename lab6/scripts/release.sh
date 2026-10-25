#!/usr/bin/env bash
# Part 7: replace v2 pods at weight 0, then open the canary at 10% (old pods stay out of the gate's window)
#   ./scripts/release.sh bad | good
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  bad)  FAIL=true ;;
  good) FAIL=false ;;
  *) echo "usage: $0 {bad|good}" >&2; exit 1 ;;
esac

helm upgrade shop "$ROOT/charts/shop" -n shop --reuse-values \
  --set-string api.versions.v2.env.FAIL="$FAIL" \
  --set api.canary.weight=0 --wait --timeout 6m >/dev/null
echo "v2 deployed (FAIL=$FAIL), no traffic yet"

helm upgrade shop "$ROOT/charts/shop" -n shop --reuse-values \
  --set api.canary.weight=10 --wait --timeout 6m >/dev/null
echo "canary opened at 10% of the traffic"
