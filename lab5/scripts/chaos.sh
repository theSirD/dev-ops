#!/usr/bin/env bash
# Part 2 chaos: delete a random api or worker pod every few seconds
set -euo pipefail

NS="${NS:-shop}"
DURATION="${1:-180}"
INTERVAL="${2:-5}"
end=$((SECONDS + DURATION))
kills=0

echo "time(utc)  deleted pod (ip)"
while (( SECONDS < end )); do
  pod=$(kubectl -n "$NS" get pods -l 'app.kubernetes.io/component in (api,worker)' \
    --field-selector=status.phase=Running --no-headers \
    -o custom-columns=NAME:.metadata.name,IP:.status.podIP,DEL:.metadata.deletionTimestamp \
    | awk '$3 == "<none>" {print $1, $2}' | sort -R | head -n 1 || true)
  if [[ -n "$pod" ]]; then
    name=${pod% *}; ip=${pod#* }
    kubectl -n "$NS" delete pod "$name" --wait=false >/dev/null
    kills=$((kills + 1))
    printf '%s  %s (%s)\n' "$(date -u +%H:%M:%S)" "$name" "$ip"
  fi
  sleep "$INTERVAL"
done
echo "pods deleted: $kills"
