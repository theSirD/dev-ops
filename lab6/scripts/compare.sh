#!/usr/bin/env bash
# Part 8: baseline against mesh, averaged over the two saved runs of each (measurements/*.txt).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/measurements" <<'PY'
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])

def load(prefix):
    runs = []
    for f in sorted(d.glob(f"{prefix}-*.txt")):
        t = f.read_text()
        num = lambda pat: float(re.search(pat, t).group(1))
        runs.append({
            "p50": num(r"p50 / p95\s+([\d.]+) ms"), "p95": num(r"p50 / p95\s+[\d.]+ ms / ([\d.]+) ms"),
            "api_cpu": num(r"api containers\s+CPU (\d+) m"), "api_mem": num(r"api containers.*memory (\d+) MiB"),
            "px_cpu": num(r"api sidecars\s+CPU (\d+) m"), "px_mem": num(r"api sidecars.*memory (\d+) MiB"),
            "cl_cpu": num(r"client sidecar\s+CPU (\d+) m"), "cl_mem": num(r"client sidecar.*memory (\d+) MiB"),
            "cp_cpu": num(r"linkerd control\s+CPU (\d+) m"), "cp_mem": num(r"linkerd control.*memory (\d+) MiB"),
        })
    return {k: sum(r[k] for r in runs) / len(runs) for k in runs[0]}, len(runs)

b, nb = load("baseline"); m, nm = load("mesh")
print(f"10 req/s for 3 min, 2 api replicas; mean of {nb} baseline and {nm} mesh runs\n")
print(f"{'':28s}{'baseline':>10s}{'mesh':>10s}{'delta':>10s}{'':>8s}")
def row(name, key, unit, base=None, mesh=None):
    bv = b[key] if base is None else base; mv = m[key] if mesh is None else mesh
    pct = f"{(mv-bv)/bv*100:+.0f} %" if bv else ""
    print(f"{name:28s}{bv:>8.1f}{unit:>2s}{mv:>8.1f}{unit:>2s}{mv-bv:>+8.1f}{unit:>2s}  {pct}")
row("latency p50", "p50", "ms"); row("latency p95", "p95", "ms")
row("api containers CPU", "api_cpu", "m"); row("api containers memory", "api_mem", "Mi")
proxies_cpu = m["px_cpu"] + m["cl_cpu"]; proxies_mem = m["px_mem"] + m["cl_mem"]
print(f"{'proxy sidecars CPU':28s}{0:>8.1f}{'m':>2s}{proxies_cpu:>8.1f}{'m':>2s}{proxies_cpu:>+8.1f}{'m':>2s}  (api {m['px_cpu']:.0f} + client {m['cl_cpu']:.0f})")
print(f"{'proxy sidecars memory':28s}{0:>8.1f}{'Mi':>2s}{proxies_mem:>8.1f}{'Mi':>2s}{proxies_mem:>+8.1f}{'Mi':>2s}  (api {m['px_mem']:.0f} + client {m['cl_mem']:.0f})")
print(f"{'linkerd control plane CPU':28s}{0:>8.1f}{'m':>2s}{m['cp_cpu']:>8.1f}{'m':>2s}{m['cp_cpu']:>+8.1f}{'m':>2s}")
print(f"{'linkerd control plane memory':28s}{0:>8.1f}{'Mi':>2s}{m['cp_mem']:>8.1f}{'Mi':>2s}{m['cp_mem']:>+8.1f}{'Mi':>2s}")
tot_b = b["api_cpu"]; tot_m = m["api_cpu"] + proxies_cpu + m["cp_cpu"]
mem_b = b["api_mem"]; mem_m = m["api_mem"] + proxies_mem + m["cp_mem"]
print(f"\n{'TOTAL CPU':28s}{tot_b:>8.1f}{'m':>2s}{tot_m:>8.1f}{'m':>2s}{tot_m-tot_b:>+8.1f}{'m':>2s}  {(tot_m-tot_b)/tot_b*100:+.0f} %")
print(f"{'TOTAL memory':28s}{mem_b:>8.1f}{'Mi':>2s}{mem_m:>8.1f}{'Mi':>2s}{mem_m-mem_b:>+8.1f}{'Mi':>2s}  {(mem_m-mem_b)/mem_b*100:+.0f} %")
PY
