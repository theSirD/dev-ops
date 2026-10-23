#!/usr/bin/env bash
# Parts 3 and 5: try each source -> destination, compare with the matrix; exit 0 = all green
set -uo pipefail

NS=shop
IMG=nicolaka/netshoot
API=api.shop.svc:8000
WORKER=worker.shop.svc:8000
PG=postgres-rw.shop.svc:5432

cleanup() {
  kubectl -n "$NS" delete pod stray --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n client delete pod probe --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n monitoring delete pod probe --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

run_probe() {
  kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1" >/dev/null
  kubectl -n "$1" delete pod "$2" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$1" run "$2" --image="$IMG" --restart=Never --command -- sleep 3600 >/dev/null
}
run_probe client probe
run_probe "$NS" stray
run_probe monitoring probe
kubectl -n client wait --for=condition=Ready pod/probe --timeout=180s >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/stray --timeout=180s >/dev/null
kubectl -n monitoring wait --for=condition=Ready pod/probe --timeout=180s >/dev/null

py_tcp='import socket,sys; h,p=sys.argv[1].rsplit(":",1); s=socket.socket(); s.settimeout(3); s.connect((h,int(p)))'
py_dns='import socket,sys; socket.getaddrinfo(sys.argv[1], None)'

from_netshoot() { kubectl -n "$1" exec "$2" -- timeout 5 nc -z -w 3 "${3%:*}" "${3##*:}" >/dev/null 2>&1; }
from_app()      { kubectl -n "$NS" exec "deploy/$1" -- python -c "$py_tcp" "$2" >/dev/null 2>&1; }
dns_from_app()  { kubectl -n "$NS" exec "deploy/$1" -- python -c "$py_dns" "$2" >/dev/null 2>&1; }
from_host()     { curl -fsS -m 3 "http://localhost:30080/health" >/dev/null 2>&1; }

fail=0
printf '%-26s %-30s %-9s %-9s %s\n' "SOURCE" "DESTINATION" "EXPECTED" "ACTUAL" ""
check() {
  local src="$1" dst="$2" want="$3"; shift 3
  local got=deny
  "$@" && got=allow
  local mark="✅"
  [[ "$got" == "$want" ]] || { mark="❌"; fail=1; }
  printf '%-26s %-30s %-9s %-9s %s\n' "$src" "$dst" "$want" "$got" "$mark"
}

check "client"           "api :8000"            allow from_netshoot client probe "$API"
check "host (NodePort)"  "api :30080"           allow from_host
check "monitoring"       "api :8000"            allow from_netshoot monitoring probe "$API"
check "stray (ns shop)"  "api :8000"            deny  from_netshoot "$NS" stray "$API"
check "api"              "postgres :5432"       allow from_app api "$PG"
check "worker"           "postgres :5432"       allow from_app worker "$PG"
check "stray (ns shop)"  "postgres :5432"       deny  from_netshoot "$NS" stray "$PG"
check "client"           "postgres :5432"       deny  from_netshoot client probe "$PG"
check "api"              "worker :8000"         deny  from_app api "$WORKER"
check "worker"           "api :8000"            deny  from_app worker "$API"
check "stray (ns shop)"  "worker :8000"         deny  from_netshoot "$NS" stray "$WORKER"
check "client"           "worker :8000"         deny  from_netshoot client probe "$WORKER"
check "api"              "DNS postgres-rw"      allow dns_from_app api postgres-rw.shop.svc
check "worker"           "DNS postgres-rw"      allow dns_from_app worker postgres-rw.shop.svc
check "api"              "internet 1.1.1.1:443" deny  from_app api 1.1.1.1:443
check "worker"           "internet 1.1.1.1:443" deny  from_app worker 1.1.1.1:443

echo
if (( fail == 0 )); then echo "matrix: all green"; else echo "matrix: MISMATCH"; fi
exit $fail
