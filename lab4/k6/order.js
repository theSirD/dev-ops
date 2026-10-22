import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.BASE_URL || "http://api:8000";
const RATE = Number(__ENV.RATE || 10);
const DURATION = __ENV.DURATION || "3m";
const SLA_P95_MS = Number(__ENV.SLA_P95_MS || 2000);
const SLA_ERROR_RATE = Number(__ENV.SLA_ERROR_RATE || 0.01);

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ["med", "p(95)", "p(99)", "max", "count"],
  scenarios: {
    order_path: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: Math.max(10, RATE),
      maxVUs: Math.max(50, RATE * 4),
    },
  },
  // thresholds are the Part 8 SLA; k6 exits non-zero when they break
  thresholds: {
    "http_req_failed{name:POST /order}": [`rate<${SLA_ERROR_RATE}`],
    "http_req_duration{name:POST /order}": [`p(95)<${SLA_P95_MS}`],
  },
};

export default function () {
  const payload = JSON.stringify({
    customer: `k6-${__VU}`,
    item: `sku-${__ITER}`,
  });
  const res = http.post(`${BASE}/order`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { name: "POST /order" },
    timeout: "10s",
  });
  check(res, { "status 201": (r) => r.status === 201 });
}

export function handleSummary(data) {
  const m = data.metrics;
  const dur = m["http_req_duration{name:POST /order}"] || m.http_req_duration;
  const failed = m["http_req_failed{name:POST /order}"] || m.http_req_failed;
  const p95 = dur ? dur.values["p(95)"] : null;
  const errRate = failed ? failed.values.rate : null;
  const hold = p95 !== null && errRate !== null && p95 < SLA_P95_MS && errRate < SLA_ERROR_RATE;
  const out = {
    target: BASE,
    rate_per_s: RATE,
    duration: DURATION,
    requests: m.iterations ? m.iterations.values.count : null,
    error_rate: errRate,
    p50_ms: dur ? dur.values.med : null,
    p95_ms: p95,
    p99_ms: dur ? dur.values["p(99)"] : null,
    max_ms: dur ? dur.values.max : null,
    sla: { p95_ms_budget: SLA_P95_MS, error_rate_budget: SLA_ERROR_RATE, hold },
  };
  return { stdout: "\nSLA SUMMARY " + JSON.stringify(out, null, 2) + "\n" };
}
