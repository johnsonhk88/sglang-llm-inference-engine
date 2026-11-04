#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

readonly DEFAULT_IMAGE="lmsysorg/sglang:latest"
readonly DEFAULT_PORT="30000"
readonly DEFAULT_SHM_SIZE="32g"

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

model=""
served_name=""
image="$DEFAULT_IMAGE"
port="$DEFAULT_PORT"
shm_size="$DEFAULT_SHM_SIZE"
hf_token="${HF_TOKEN:-${HT_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
if [[ -z "$hf_token" && -f "${HOME}/.cache/huggingface/token" ]]; then
    hf_token="$(tr -d ' \r\n' < "${HOME}/.cache/huggingface/token" 2>/dev/null || true)"
fi
sglang_args=()

usage() {
    cat <<'EOF'
Usage:
  run-sglang-docker.sh --model MODEL [launcher options] [SGLang options...]

Required:
  --model MODEL       Hugging Face model ID or local model path.

Launcher options:
  --name NAME         API-visible model name (--served-model-name).
  --image IMAGE       Docker image (default: lmsysorg/sglang:latest).
  --port PORT         Host/container port (default: 30000).
  --shm-size SIZE     Docker --shm-size (default: 32g).
  --hf-token TOKEN    Hugging Face token (alias: --token).
  -h, --help          Show this help text.

All other arguments are passed to SGLang unchanged. For example:
  run-sglang-docker.sh --model Qwen/Qwen3-0.6B \
      --name qwen-small --mem-fraction-static 0.2

--enable-metrics is added automatically so /metrics is available for
Prometheus. Pass it yourself if you want to be explicit.
EOF
}

die() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            [[ $# -ge 2 && -n "$2" ]] || die "--model requires a value"
            model="$2"
            shift 2
            ;;
        --model=*)
            model="${1#*=}"
            [[ -n "$model" ]] || die "--model requires a value"
            shift
            ;;
        --name)
            [[ $# -ge 2 && -n "$2" ]] || die "--name requires a value"
            served_name="$2"
            shift 2
            ;;
        --name=*)
            served_name="${1#*=}"
            [[ -n "$served_name" ]] || die "--name requires a value"
            shift
            ;;
        --image)
            [[ $# -ge 2 && -n "$2" ]] || die "--image requires a value"
            image="$2"
            shift 2
            ;;
        --image=*)
            image="${1#*=}"
            [[ -n "$image" ]] || die "--image requires a value"
            shift
            ;;
        --port)
            [[ $# -ge 2 && -n "$2" ]] || die "--port requires a value"
            port="$2"
            shift 2
            ;;
        --port=*)
            port="${1#*=}"
            [[ -n "$port" ]] || die "--port requires a value"
            shift
            ;;
        --shm-size)
            [[ $# -ge 2 && -n "$2" ]] || die "--shm-size requires a value"
            shm_size="$2"
            shift 2
            ;;
        --shm-size=*)
            shm_size="${1#*=}"
            [[ -n "$shm_size" ]] || die "--shm-size requires a value"
            shift
            ;;
        --hf-token|--token)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            hf_token="$2"
            shift 2
            ;;
        --hf-token=*|--token=*)
            hf_token="${1#*=}"
            [[ -n "$hf_token" ]] || die "${1%%=*} requires a value"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            sglang_args+=("$@")
            break
            ;;
        *)
            sglang_args+=("$1")
            shift
            ;;
    esac
done

[[ -n "$model" ]] || die "--model is required"

if [[ -n "$hf_token" ]]; then
    echo "[+] Using Hugging Face token for authenticated high-speed download."
else
    echo "[!] Warning: No HF_TOKEN provided. Downloads may be rate-limited by Hugging Face."
    echo "    Tip: pass --hf-token <token> or export HF_TOKEN=\"hf_...\" for faster downloads."
fi

docker_args=(
    run
    -it
    --rm
    --gpus all
    --shm-size "$shm_size"
    -v "${HOME}/.cache/huggingface:/root/.cache/huggingface"
    --env "HF_TOKEN=${hf_token}"
    --env "HUGGING_FACE_HUB_TOKEN=${hf_token}"
    --env "HF_XET_HIGH_PERFORMANCE=1"
    -p "${port}:${port}"
    --ipc=host
    "$image"
    python3
    -m
    sglang.launch_server
    --model-path "$model"
    --host "0.0.0.0"
    --port "$port"
)

if [[ -n "$served_name" ]]; then
    docker_args+=(--served-model-name "$served_name")
fi

has_metrics=false
for arg in "${sglang_args[@]+"${sglang_args[@]}"}"; do
    if [[ "$arg" == "--enable-metrics" ]]; then
        has_metrics=true
        break
    fi
done
if [[ "$has_metrics" == false ]]; then
    sglang_args+=(--enable-metrics)
fi

docker_args+=("${sglang_args[@]}")

exec docker "${docker_args[@]}"
