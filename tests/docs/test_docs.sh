#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cd "${ROOT}"

grep -q 'run-sglang-docker.sh' README.md \
  || fail "README.md missing run-sglang-docker.sh"
grep -q 'run-sglang-k8s.sh' README.md k8s/README.md \
  || fail "run-sglang-k8s.sh missing from README.md or k8s/README.md"
grep -q 'lmsysorg/sglang:latest' README.md \
  || fail "README.md missing lmsysorg/sglang:latest"
grep -q '30000' README.md k8s/README.md k8s/USAGE.md \
  || fail "port 30000 missing from docs"
grep -q 'mem-fraction-static' README.md k8s/README.md \
  || fail "mem-fraction-static missing from README.md or k8s/README.md"
grep -q 'tensorParallelSize' k8s/README.md \
  || fail "tensorParallelSize missing from k8s/README.md"
grep -q 'maxRunningRequests' k8s/README.md \
  || fail "maxRunningRequests missing from k8s/README.md"
grep -q 'microk8s enable gpu' README.md k8s/README.md \
  || fail "microk8s enable gpu missing from README.md or k8s/README.md"
grep -q 'The server is fired up and ready to roll!' README.md k8s/DEBUG_GUIDE.md \
  || fail "ready-to-roll log line missing from README.md or k8s/DEBUG_GUIDE.md"
grep -q '0.0.0.0' README.md k8s/DEBUG_GUIDE.md \
  || fail "0.0.0.0 bind address missing from README.md or k8s/DEBUG_GUIDE.md"
grep -q 'test-k8s.sh' README.md k8s/README.md \
  || fail "test-k8s.sh missing from README.md or k8s/README.md"
grep -q 'ClusterIP' k8s/USAGE.md \
  || fail "ClusterIP missing from k8s/USAGE.md"
grep -q 'NodePort' k8s/USAGE.md \
  || fail "NodePort missing from k8s/USAGE.md"
grep -q 'docker compose -f monitoring/docker-compose.yml up -d' monitoring/README.md README.md \
  || fail "compose bring-up command missing from monitoring/README.md or README.md"
grep -q 'monitoring.enabled' k8s/README.md monitoring/README.md \
  || fail "monitoring.enabled missing from k8s/README.md or monitoring/README.md"
grep -q 'serviceMonitor.labels' monitoring/README.md \
  || fail "monitoring/README.md must show serviceMonitor.labels in Helm examples"
grep -q 'generation_tokens_total' monitoring/README.md README.md \
  || fail "generation_tokens_total missing from monitoring/README.md or README.md"
grep -q 'DCGM_FI_DEV_GPU_UTIL' monitoring/README.md \
  || fail "GPU util metric missing from monitoring/README.md"
grep -q 'Token throughput' README.md \
  || fail "README.md missing Token throughput in the monitoring how-to"
grep -q 'bench-sglang.sh' README.md monitoring/README.md \
  || fail "bench-sglang.sh missing from README.md or monitoring/README.md"
grep -q 'microk8s enable' monitoring/README.md \
  || fail "microk8s enable missing from monitoring/README.md"
grep -q '/metrics' README.md k8s/USAGE.md k8s/DEBUG_GUIDE.md \
  || fail "/metrics missing from README.md, k8s/USAGE.md, or k8s/DEBUG_GUIDE.md"
grep -q 'tests/run.sh' README.md \
  || fail "README.md missing tests/run.sh"
grep -q 'port-forward' README.md k8s/USAGE.md monitoring/README.md \
  || fail "port-forward missing from README.md, k8s/USAGE.md, or monitoring/README.md"
pass "operator documentation contains required SGLang contracts"
