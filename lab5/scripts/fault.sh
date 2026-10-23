#!/usr/bin/env bash
# Part 6: apply one random fault through chart values; reveal / reset
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK="$ROOT/scripts/.fault"
deploy() { helm upgrade shop "$ROOT/charts/shop" -n shop --reset-values "$@" --wait --timeout 5m >/dev/null; }

FAULTS=(
  "wrong-label|--set networkPolicy.postgres.allowFrom.api.app\\.kubernetes\\.io/component=apii"
  "wrong-port|--set networkPolicy.postgres.allowedPort=5433"
  "no-dns|--set networkPolicy.dns.enabled=false"
  "no-api-egress|--set networkPolicy.api.egressToPostgres=false"
)
DESCRIPTION=(
  "the allow rule for postgres selects api pods by a label nobody has"
  "the policies open port 5433 on postgres while the Service uses 5432"
  "the DNS egress allowance is removed"
  "the egress rule api -> postgres is removed (default-deny drops it)"
)

case "${1:-}" in
  reveal)
    [[ -f "$MARK" ]] || { echo "no fault applied" >&2; exit 1; }
    i=$(cat "$MARK")
    echo "${FAULTS[$i]%%|*}: ${DESCRIPTION[$i]}"
    ;;
  reset)
    deploy
    rm -f "$MARK"
    echo "values.yaml restored"
    ;;
  "")
    i=$((RANDOM % ${#FAULTS[@]}))
    deploy ${FAULTS[$i]#*|}
    echo "$i" > "$MARK"
    echo "a fault has been applied. Orders should now be failing; find out why."
    ;;
  *)
    echo "usage: $0 [reveal|reset]" >&2
    exit 1
    ;;
esac
