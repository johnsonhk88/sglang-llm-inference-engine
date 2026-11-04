#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM="${ROOT}/monitoring/prometheus/prometheus.yml"
COMPOSE="${ROOT}/monitoring/docker-compose.yml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[[ -f "${PROM}" ]] || fail "missing ${PROM}"
[[ -f "${COMPOSE}" ]] || fail "missing ${COMPOSE}"

grep -q 'job_name: sglang' "${PROM}" || fail "prometheus.yml missing job_name: sglang"
grep -q 'host.docker.internal:30000' "${PROM}" || fail "prometheus.yml missing host.docker.internal:30000"
grep -q 'metrics_path: /metrics' "${PROM}" || fail "prometheus.yml missing metrics_path: /metrics"
grep -q 'dcgm-exporter:9400' "${PROM}" || fail "prometheus.yml missing dcgm-exporter:9400"
grep -q 'node-exporter:9100' "${PROM}" || fail "prometheus.yml missing node-exporter:9100"
pass "prometheus.yml scrape jobs"

grep -q 'prometheus:' "${COMPOSE}" || fail "compose missing prometheus service"
grep -q 'grafana:' "${COMPOSE}" || fail "compose missing grafana service"
grep -q 'dcgm-exporter:' "${COMPOSE}" || fail "compose missing dcgm-exporter service"
grep -q 'node-exporter:' "${COMPOSE}" || fail "compose missing node-exporter service"
grep -q '9090:9090' "${COMPOSE}" || fail "compose missing 9090:9090"
grep -q '3000:3000' "${COMPOSE}" || fail "compose missing 3000:3000"
pass "compose services and ports"

DASH="${ROOT}/monitoring/grafana/dashboards/sglang-capacity.json"
DS="${ROOT}/monitoring/grafana/provisioning/datasources/datasource.yml"
python3 -m json.tool "${DASH}" >/dev/null || fail "dashboard JSON is invalid"
grep -q '"uid": "sglang-capacity"' "${DASH}" || fail "dashboard missing uid sglang-capacity"
grep -q 'SGLang Capacity' "${DASH}" || fail "dashboard missing title SGLang Capacity"
grep -q 'sglang:num_queue_reqs' "${DASH}" || fail "dashboard missing sglang:num_queue_reqs"
grep -q 'sglang:num_running_reqs' "${DASH}" || fail "dashboard missing sglang:num_running_reqs"
grep -q 'sglang:prompt_tokens_total' "${DASH}" || fail "dashboard missing prompt_tokens_total"
grep -q 'sglang:generation_tokens_total' "${DASH}" || fail "dashboard missing generation_tokens_total"
grep -q 'sglang:gen_throughput' "${DASH}" || fail "dashboard missing gen_throughput"
grep -q 'sglang:token_usage' "${DASH}" || fail "dashboard missing token_usage"
grep -q 'sglang:time_to_first_token_seconds_bucket' "${DASH}" || fail "dashboard missing TTFT histogram"
grep -q 'DCGM_FI_DEV_GPU_UTIL' "${DASH}" || fail "dashboard missing DCGM_FI_DEV_GPU_UTIL"
grep -q 'DCGM_FI_DEV_FB_USED' "${DASH}" || fail "dashboard missing DCGM_FI_DEV_FB_USED"
grep -Fq 'DCGM_FI_DEV_FB_USED * 1024 * 1024' "${DASH}" || fail "FB_USED is megabytes; convert to bytes before unit bytes"
grep -q 'decbytes' "${DASH}" && fail "do not use decbytes for DCGM_FI_DEV_FB_USED (values are already MB)"
grep -q 'type: prometheus' "${DS}" || fail "datasource missing type: prometheus"
grep -q 'http://prometheus:9090' "${DS}" || fail "datasource missing http://prometheus:9090"
pass "grafana dashboard and datasource"
