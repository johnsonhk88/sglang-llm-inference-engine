#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

readonly DEFAULT_IMAGE="lmsysorg/sglang:latest"
readonly DEFAULT_PORT="30000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load .env or src/.env if present
for env_file in ".env" "src/.env" "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/../.env"; do
    if [[ -f "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file" 2>/dev/null || true
        set +a
        break
    fi
done

image="$DEFAULT_IMAGE"
port="$DEFAULT_PORT"
base_url=""
model=""
profile="smoke"
backend="sglang-oai-chat"
num_prompts=""
max_concurrency=""
input_len=""
output_len=""
metrics_only=false
dry_run=false
bench_args=()

usage() {
    cat <<'EOF'
Usage:
  bench-sglang.sh [options] [sglang.benchmark.serving args...]

Load-test a running SGLang server and print tokens/s, TTFT, and TPOT.
Uses the official image: python3 -m sglang.benchmark.serving

Options:
  --profile NAME      smoke (default) or throughput.
  --model NAME        API-visible model name (default: first /v1/models id).
  --port PORT         Server port (default: 30000).
  --url URL           Full base URL (overrides --port), e.g. http://127.0.0.1:30000.
  --image IMAGE       Bench runner image (default: lmsysorg/sglang:latest).
  --backend NAME      Bench backend (default: sglang-oai-chat).
  --num-prompts N     Override profile prompt count.
  --max-concurrency N Override in-flight concurrency.
  --input-len N       Random dataset input tokens.
  --output-len N      Random dataset output tokens.
  --metrics-only      Print /metrics tok/s snapshot and exit.
  --dry-run           Print the bench command without running it.
  -h, --help          Show this help text.

Profiles:
  smoke       32 prompts, 256/128 tokens, concurrency 4
  throughput  200 prompts, 1024/256 tokens, concurrency 16, request-rate inf

Examples:
  ./src/bench-sglang.sh
  ./src/bench-sglang.sh --profile throughput --model qwen-small
  ./src/bench-sglang.sh --metrics-only
EOF
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            [[ $# -ge 2 && -n "$2" ]] || die "--profile requires a value"
            profile="$2"
            shift 2
            ;;
        --model)
            [[ $# -ge 2 && -n "$2" ]] || die "--model requires a value"
            model="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 && -n "$2" ]] || die "--port requires a value"
            port="$2"
            shift 2
            ;;
        --url)
            [[ $# -ge 2 && -n "$2" ]] || die "--url requires a value"
            base_url="$2"
            shift 2
            ;;
        --image)
            [[ $# -ge 2 && -n "$2" ]] || die "--image requires a value"
            image="$2"
            shift 2
            ;;
        --backend)
            [[ $# -ge 2 && -n "$2" ]] || die "--backend requires a value"
            backend="$2"
            shift 2
            ;;
        --num-prompts)
            [[ $# -ge 2 && -n "$2" ]] || die "--num-prompts requires a value"
            num_prompts="$2"
            shift 2
            ;;
        --max-concurrency)
            [[ $# -ge 2 && -n "$2" ]] || die "--max-concurrency requires a value"
            max_concurrency="$2"
            shift 2
            ;;
        --input-len)
            [[ $# -ge 2 && -n "$2" ]] || die "--input-len requires a value"
            input_len="$2"
            shift 2
            ;;
        --output-len)
            [[ $# -ge 2 && -n "$2" ]] || die "--output-len requires a value"
            output_len="$2"
            shift 2
            ;;
        --metrics-only)
            metrics_only=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            bench_args+=("$@")
            break
            ;;
        *)
            bench_args+=("$1")
            shift
            ;;
    esac
done

case "$profile" in
    smoke)
        num_prompts="${num_prompts:-32}"
        max_concurrency="${max_concurrency:-4}"
        input_len="${input_len:-256}"
        output_len="${output_len:-128}"
        request_rate=""
        ;;
    throughput)
        num_prompts="${num_prompts:-200}"
        max_concurrency="${max_concurrency:-16}"
        input_len="${input_len:-1024}"
        output_len="${output_len:-256}"
        request_rate="inf"
        ;;
    *)
        die "Unknown profile: $profile (use smoke or throughput)"
        ;;
esac

if [[ -z "$base_url" ]]; then
    base_url="http://127.0.0.1:${port}"
else
    base_url="${base_url%/}"
    if [[ "$base_url" == */v1 ]]; then
        base_url="${base_url%/v1}"
    fi
    if [[ "$base_url" =~ :([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    fi
fi

print_metrics() {
    local label="$1"
    echo "=== $label ($base_url/metrics) ==="
    if ! curl -sf --max-time 5 "$base_url/metrics" >/tmp/sglang-metrics.out; then
        echo "[!] /metrics not reachable. Start the server with --enable-metrics."
        return 1
    fi
    grep -E '^sglang:(gen_throughput|prompt_tokens_total|generation_tokens_total|num_running_reqs|num_queue_reqs|token_usage)[{ ]' \
        /tmp/sglang-metrics.out || true
}

if [[ "$metrics_only" == true ]]; then
    print_metrics "SGLang live metrics"
    exit 0
fi

if [[ "$dry_run" == false ]]; then
    if ! curl -sf --max-time 5 "$base_url/health" >/dev/null; then
        die "SGLang is not reachable at $base_url/health. Start it with ./src/run-sglang-docker.sh first."
    fi
    if [[ -z "$model" ]]; then
        model="$(curl -sf --max-time 10 "$base_url/v1/models" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["data"][0]["id"])' 2>/dev/null || true)"
        [[ -n "$model" ]] || die "Could not discover a model from $base_url/v1/models. Pass --model."
        echo "[+] Discovered model: $model"
    fi
    print_metrics "Metrics before bench" || true
    echo
else
    model="${model:-qwen-small}"
fi

cmd=(
    docker run --rm --network host
    "$image"
    python3 -m sglang.benchmark.serving
    --backend "$backend"
    --base-url "$base_url"
    --model "$model"
    --dataset-name random
    --num-prompts "$num_prompts"
    --random-input-len "$input_len"
    --random-output-len "$output_len"
    --max-concurrency "$max_concurrency"
)
if [[ -n "$request_rate" ]]; then
    cmd+=(--request-rate "$request_rate")
fi
cmd+=("${bench_args[@]+"${bench_args[@]}"}")

echo "[*] Profile: $profile"
echo "[*] Command: ${cmd[*]}"
echo

if [[ "$dry_run" == true ]]; then
    exit 0
fi

"${cmd[@]}"

echo
print_metrics "Metrics after bench" || true
echo
echo "[+] Quote client Output token throughput (tok/s) from the bench summary."
echo "    sglang:gen_throughput is a live gauge; counters + Grafana rate() are steadier."
