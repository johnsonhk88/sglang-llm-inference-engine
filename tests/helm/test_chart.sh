#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="${ROOT}/helm/sglang"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v helm >/dev/null 2>&1 || fail "helm is required"

render_deploy() {
  helm template t "${CHART}" --show-only templates/deployment.yaml "$@"
}

render() {
  helm template t "${CHART}" "$@"
}

default_deploy="$(render_deploy)"
printf '%s\n' "${default_deploy}" | grep -q 'sglang.launch_server' || fail "default render missing sglang.launch_server"
printf '%s\n' "${default_deploy}" | grep -q -- '--model-path' || fail "default render missing --model-path"
printf '%s\n' "${default_deploy}" | grep -q -- '0.0.0.0' || fail "default render missing --host 0.0.0.0"
printf '%s\n' "${default_deploy}" | grep -q -- '--served-model-name' || fail "default render missing --served-model-name"
printf '%s\n' "${default_deploy}" | grep -q -- '--mem-fraction-static' || fail "default render missing --mem-fraction-static"
printf '%s\n' "${default_deploy}" | grep -q -- '--enable-metrics' || fail "default render missing --enable-metrics"
printf '%s\n' "${default_deploy}" | grep -q -- '--tp-size' && fail "default render must not contain --tp-size"
printf '%s\n' "${default_deploy}" | grep -q -- '--max-running-requests' && fail "default render must not contain --max-running-requests"
printf '%s\n' "${default_deploy}" | grep -q -- '--context-length' && fail "default render must not contain --context-length"
printf '%s\n' "${default_deploy}" | grep -q 'enableServiceLinks: false' || fail "default render must disable service links"
pass "default command, host, metrics, and omitted optional flags"

knobs="$(render_deploy --set maxRunningRequests=32 --set tensorParallelSize=2 --set contextLength=4096)"
printf '%s\n' "${knobs}" | grep -q -- '--max-running-requests' || fail "missing --max-running-requests"
printf '%s\n' "${knobs}" | grep -q -- '32' || fail "missing maxRunningRequests value 32"
printf '%s\n' "${knobs}" | grep -q -- '--tp-size' || fail "missing --tp-size"
printf '%s\n' "${knobs}" | grep -q -- '2' || fail "missing tensorParallelSize value 2"
printf '%s\n' "${knobs}" | grep -q -- '--context-length' || fail "missing --context-length"
printf '%s\n' "${knobs}" | grep -q -- '4096' || fail "missing contextLength value 4096"
pass "optional knobs render maxRunningRequests, tp-size, and contextLength"

no_metrics="$(render_deploy --set enableMetrics=false)"
printf '%s\n' "${no_metrics}" | grep -q -- '--enable-metrics' && fail "enableMetrics=false must omit --enable-metrics"
pass "enableMetrics=false omits --enable-metrics"

extra="$(render_deploy --set-json 'extraArgs=["--trust-remote-code"]')"
printf '%s\n' "${extra}" | grep -q -- '--trust-remote-code' || fail "extraArgs missing --trust-remote-code"
pass "extraArgs passthrough"

default_all="$(render)"
printf '%s\n' "${default_all}" | grep -q 'kind: Service' || fail "default render missing Service"
printf '%s\n' "${default_all}" | grep -q 'type: ClusterIP' || fail "default service type must be ClusterIP"
printf '%s\n' "${default_all}" | grep -q 'kind: Secret' && fail "default render must not include Secret without hfToken"
pass "default ClusterIP service and no secret"

nodeport="$(render --set service.type=NodePort --set service.nodePort=30300)"
printf '%s\n' "${nodeport}" | grep -q 'type: NodePort' || fail "NodePort type missing"
printf '%s\n' "${nodeport}" | grep -q 'nodePort: 30300' || fail "nodePort 30300 missing"
pass "NodePort renders nodePort 30300"

secret="$(render --set hfToken=hf_test_token)"
printf '%s\n' "${secret}" | grep -q 'kind: Secret' || fail "hfToken should create Secret"
printf '%s\n' "${secret}" | grep -q 'hf_test_token' || fail "Secret missing token value"
pass "hfToken creates Secret"

printf '%s\n' "${default_all}" | grep -q 'kind: ServiceMonitor' && fail "default render must not include ServiceMonitor"
pass "default omits ServiceMonitor"

monitored="$(render --set monitoring.enabled=true)"
printf '%s\n' "${monitored}" | grep -q 'kind: ServiceMonitor' || fail "monitoring.enabled=true missing kind: ServiceMonitor"
printf '%s\n' "${monitored}" | grep -q 'path: /metrics' || fail "ServiceMonitor missing path: /metrics"
printf '%s\n' "${monitored}" | grep -q 'port: http' || fail "ServiceMonitor missing port: http"
printf '%s\n' "${monitored}" | grep -q 'interval: 15s' || fail "ServiceMonitor missing interval: 15s"
pass "monitoring.enabled=true renders ServiceMonitor on /metrics"

echo "All helm chart tests passed."
