"""Release gate: every INTERVAL seconds read v2's health from Prometheus and move the canary weight."""

import json
import os
import subprocess
import time
import urllib.parse
import urllib.request

PROM = os.getenv("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
NS = os.getenv("NAMESPACE", "shop")
RELEASE = os.getenv("RELEASE", "shop")
CHART = os.getenv("CHART", "/chart")
INTERVAL = int(os.getenv("INTERVAL_SECONDS", "15"))
STEPS = [int(s) for s in os.getenv("STEPS", "10,30,50,80,100").split(",")]
MAX_ERROR_RATE = float(os.getenv("MAX_ERROR_RATE", "0.05"))
PROMOTE_ERROR_RATE = float(os.getenv("PROMOTE_ERROR_RATE", "0.01"))
MAX_P95_MS = float(os.getenv("MAX_P95_MS", "500"))
MIN_REQUESTS = float(os.getenv("MIN_REQUESTS", "20"))
# v2 traffic from meshed clients (kubelet probes have no identity)
SEL = f'direction="inbound",namespace="{NS}",srv_port="8000",tls="true",version="v2"'


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def query(expr: str) -> float | None:
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as r:
        result = json.load(r)["data"]["result"]
    if not result or result[0]["value"][1] == "NaN":
        return None
    return float(result[0]["value"][1])


def current_weight() -> int:
    out = subprocess.run(
        ["helm", "get", "values", RELEASE, "-n", NS, "--all", "-o", "json"],
        capture_output=True, text=True, check=True,
    ).stdout
    return int(json.loads(out)["api"]["canary"]["weight"])


def set_weight(weight: int) -> None:
    subprocess.run(
        ["helm", "upgrade", RELEASE, CHART, "-n", NS, "--reuse-values",
         "--set", f"api.canary.weight={weight}"],
        capture_output=True, text=True, check=True,
    )


def decide(weight: int) -> None:
    requests = query(f"sum(increase(response_total{{{SEL}}}[1m]))") or 0.0
    failures = query(f'sum(increase(response_total{{{SEL},classification="failure"}}[1m]))') or 0.0
    p95 = query(f"histogram_quantile(0.95, sum(rate(response_latency_ms_bucket{{{SEL}}}[1m])) by (le))")
    error_rate = failures / requests if requests else 0.0
    state = f"weight={weight}% requests={requests:.0f} errors={error_rate:.1%} p95={p95 if p95 is None else round(p95)}ms"

    if requests < MIN_REQUESTS:
        log(f"WAIT      {state} (fewer than {MIN_REQUESTS:.0f} requests in the window)")
    elif error_rate > MAX_ERROR_RATE or (p95 is not None and p95 > MAX_P95_MS):
        set_weight(0)
        log(f"ROLLBACK  {state} -> 0%")
    elif error_rate < PROMOTE_ERROR_RATE:
        nxt = next((s for s in STEPS if s > weight), STEPS[-1])
        set_weight(nxt)
        log(f"PROMOTE   {state} -> {nxt}%")
    else:
        log(f"HOLD      {state} (errors between {PROMOTE_ERROR_RATE:.0%} and {MAX_ERROR_RATE:.0%})")


def main() -> None:
    log(f"gate started: steps={STEPS} rollback>{MAX_ERROR_RATE:.0%} errors or >{MAX_P95_MS:.0f}ms p95, promote<{PROMOTE_ERROR_RATE:.0%} errors")
    while True:
        try:
            weight = current_weight()
            if weight <= 0:
                log("IDLE      canary weight is 0% (no release in progress)")
            elif weight >= STEPS[-1]:
                log(f"DONE      v2 serves {weight}% of traffic")
            else:
                decide(weight)
        except Exception as error:  # keep the loop alive on a transient failure
            log(f"ERROR     {error}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
