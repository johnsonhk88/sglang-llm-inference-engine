#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cd "${ROOT}"

for script in src/run-sglang-docker.sh src/run-sglang-k8s.sh src/test-k8s.sh src/test.sh src/test-sglang.py src/bench-sglang.sh; do
  [[ -f "$script" ]] || fail "missing $script"
  bash -n "$script" 2>/dev/null || python3 -m py_compile "$script" || fail "syntax check failed: $script"
done
pass "launcher scripts exist and parse"

help_out="$(bash src/run-sglang-docker.sh --help)"
printf '%s\n' "$help_out" | grep -q -- '--model MODEL' || fail "docker help missing --model"
printf '%s\n' "$help_out" | grep -q 'lmsysorg/sglang:latest' || fail "docker help missing default image"
printf '%s\n' "$help_out" | grep -q '30000' || fail "docker help missing default port"
pass "docker launcher --help"

k8s_help="$(bash src/run-sglang-k8s.sh --help)"
printf '%s\n' "$k8s_help" | grep -q -- '--port-forward' || fail "k8s help missing --port-forward"
printf '%s\n' "$k8s_help" | grep -q -- '--mem-fraction' || fail "k8s help missing --mem-fraction"
pass "k8s launcher --help"

set +e
bash src/run-sglang-docker.sh >/tmp/sglang-docker-missing-model.out 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "docker launcher should fail without --model"
grep -q -- '--model is required' /tmp/sglang-docker-missing-model.out \
  || fail "docker launcher missing-model error text"
pass "docker launcher requires --model"

python3 -m py_compile src/test-sglang.py
pass "python tester compiles"

bench_help="$(bash src/bench-sglang.sh --help)"
printf '%s\n' "$bench_help" | grep -q -- '--profile' || fail "bench help missing --profile"
printf '%s\n' "$bench_help" | grep -q -- '--metrics-only' || fail "bench help missing --metrics-only"
pass "bench launcher --help"

dry="$(bash src/bench-sglang.sh --dry-run --profile smoke --model qwen-small)"
printf '%s\n' "$dry" | grep -q 'sglang.benchmark.serving' || fail "dry-run missing sglang.benchmark.serving"
printf '%s\n' "$dry" | grep -q -- '--backend sglang-oai-chat' || fail "dry-run missing sglang-oai-chat"
printf '%s\n' "$dry" | grep -q -- '--num-prompts 32' || fail "smoke profile missing 32 prompts"
printf '%s\n' "$dry" | grep -q -- '--random-input-len 256' || fail "smoke profile missing input 256"
pass "bench dry-run smoke profile"

thru="$(bash src/bench-sglang.sh --dry-run --profile throughput --model qwen-small)"
printf '%s\n' "$thru" | grep -q -- '--num-prompts 200' || fail "throughput profile missing 200 prompts"
printf '%s\n' "$thru" | grep -q -- '--request-rate inf' || fail "throughput profile missing request-rate inf"
pass "bench dry-run throughput profile"

echo "All launcher tests passed."
