#!/usr/bin/env bash
# Hit api endpoints to exercise metrics / logs / traces / alerts.
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
MODE="${1:-all}"

need_curl() {
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required" >&2
    exit 1
  }
}

hit() {
  local path="$1"
  local n="${2:-1}"
  local i
  for ((i = 1; i <= n; i++)); do
    code="$(curl -s -o /tmp/lab2-traffic.out -w '%{http_code}' "${BASE_URL}${path}" || true)"
    echo "$(date -u +%H:%M:%S) ${path} -> ${code}"
  done
}

need_curl

case "${MODE}" in
  health) hit /health 1 ;;
  fail) hit /fail 30 ;;
  slow) hit /slow 10 ;;
  load) hit /load 5 ;;
  down) hit "/down?seconds=180" 1 ;;
  all)
    hit /health 5
    hit /fail 40
    hit /slow 12
    hit /load 3
    ;;
  alerts)
    # Keep error + latency high long enough for PrometheusRule `for:` windows.
    echo "Generating alert traffic for ~3 minutes..."
    end=$((SECONDS + 180))
    while ((SECONDS < end)); do
      hit /fail 8
      hit /slow 4
      hit /load 1
      sleep 2
    done
    ;;
  *)
    echo "usage: $0 {health|fail|slow|load|down|all|alerts}" >&2
    exit 1
    ;;
esac
