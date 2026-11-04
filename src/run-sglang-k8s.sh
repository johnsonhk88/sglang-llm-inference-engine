#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# Auto-configure KUBECONFIG if not set and ~/.kube/config does not exist
if [[ -z "${KUBECONFIG:-}" && ! -f "${HOME}/.kube/config" ]]; then
    if [[ -r "/var/snap/microk8s/current/credentials/client.config" ]]; then
        export KUBECONFIG="/var/snap/microk8s/current/credentials/client.config"
    elif command -v microk8s >/dev/null 2>&1; then
        mkdir -p "${HOME}/.kube" 2>/dev/null || true
        microk8s config > "${HOME}/.kube/config" 2>/dev/null || true
        chmod 600 "${HOME}/.kube/config" 2>/dev/null || true
    fi
fi

# Detect kubectl and helm
KUBECTL="${KUBECTL_BIN:-$(which kubectl 2>/dev/null || which microk8s.kubectl 2>/dev/null || echo "kubectl")}"
HELM="${HELM_BIN:-$(which helm 2>/dev/null || which microk8s.helm3 2>/dev/null || echo "helm")}"

# Defaults
MODEL=""
SERVED_NAME=""
SERVICE_TYPE="ClusterIP"
PORT=""
NODE_PORT=""
GPU_COUNT="1"
MEM_FRACTION="0.8"
HF_TOKEN_VAL="${HF_TOKEN:-${HT_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
ACTION="deploy"
DEPLOYER="helm" # 'helm' or 'kubectl'
DRY_RUN=false
NAMESPACE="default"

usage() {
    cat <<'EOF'
Usage:
  run-sglang-k8s.sh [options]
  run-sglang-k8s.sh --status | --logs | --port-forward | --delete

Actions:
  (default)           Deploy SGLang onto Kubernetes.
  --status            Check status of pods and services.
  --logs              Stream live logs from the SGLang pod.
  --port-forward      Forward ClusterIP service to localhost.
  --delete            Delete the SGLang deployment & service.

Model:
  --model MODEL       Model ID (default: Qwen/Qwen3-0.6B).
  --name NAME         API-visible model name (alias).

Kubernetes & Networking:
  --service-type TYPE Service type: ClusterIP (default) or NodePort.
  --port PORT         Service port (default: 30000).
  --nodeport PORT     NodePort when using --service-type NodePort (e.g. 30300).
  --namespace NS      Kubernetes namespace (default: default).
  --gpu COUNT         Number of GPUs to allocate (default: 1).
  --mem-fraction NUM  SGLang --mem-fraction-static (default: 0.8).
  --hf-token TOKEN    Hugging Face access token.
  --deployer TOOL     Deployment tool: 'helm' (default) or 'kubectl'.
  --dry-run           Render generated Kubernetes manifests without applying.
  -h, --help          Show this help text.

Examples:
  # 1. Deploy with production ClusterIP
  ./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small

  # 2. Port-forward ClusterIP to test locally
  ./src/run-sglang-k8s.sh --port-forward

  # 3. View status and stream logs
  ./src/run-sglang-k8s.sh --status
  ./src/run-sglang-k8s.sh --logs
EOF
}

die() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)
            ACTION="status"
            shift
            ;;
        --logs)
            ACTION="logs"
            shift
            ;;
        --port-forward)
            ACTION="port-forward"
            shift
            ;;
        --delete|--uninstall)
            ACTION="delete"
            shift
            ;;
        --model)
            [[ $# -ge 2 && -n "$2" ]] || die "--model requires a value"
            MODEL="$2"
            shift 2
            ;;
        --name)
            [[ $# -ge 2 && -n "$2" ]] || die "--name requires a value"
            SERVED_NAME="$2"
            shift 2
            ;;
        --service-type)
            [[ $# -ge 2 && -n "$2" ]] || die "--service-type requires a value"
            SERVICE_TYPE="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 && -n "$2" ]] || die "--port requires a value"
            PORT="$2"
            shift 2
            ;;
        --nodeport)
            [[ $# -ge 2 && -n "$2" ]] || die "--nodeport requires a value"
            NODE_PORT="$2"
            shift 2
            ;;
        --namespace|-n)
            [[ $# -ge 2 && -n "$2" ]] || die "--namespace requires a value"
            NAMESPACE="$2"
            shift 2
            ;;
        --gpu)
            [[ $# -ge 2 && -n "$2" ]] || die "--gpu requires a value"
            GPU_COUNT="$2"
            shift 2
            ;;
        --mem-fraction|--gpu-util)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            MEM_FRACTION="$2"
            shift 2
            ;;
        --hf-token|--token)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            HF_TOKEN_VAL="$2"
            shift 2
            ;;
        --deployer)
            [[ $# -ge 2 && -n "$2" ]] || die "--deployer requires a value"
            DEPLOYER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

PORT="${PORT:-30000}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
SERVED_NAME="${SERVED_NAME:-qwen-small}"

# ----------------- Action: Status -----------------
if [[ "$ACTION" == "status" ]]; then
    echo "=== SGLang Kubernetes Status ==="
    "$KUBECTL" -n "$NAMESPACE" get pods,svc,deploy -l "app.kubernetes.io/name=sglang" 2>/dev/null || true
    "$KUBECTL" -n "$NAMESPACE" get pods,svc,deploy -l "app=sglang" 2>/dev/null || true
    exit 0
fi

# ----------------- Action: Logs -----------------
if [[ "$ACTION" == "logs" ]]; then
    echo "=== Streaming SGLang Pod Logs ==="
    pod_name="$("$KUBECTL" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$pod_name" ]]; then
        pod_name="$("$KUBECTL" -n "$NAMESPACE" get pods -l "app=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    if [[ -z "$pod_name" ]]; then
        echo "Error: No SGLang pod found running in namespace '$NAMESPACE'." >&2
        exit 1
    fi
    echo "Tailing logs for pod: $pod_name"
    exec "$KUBECTL" -n "$NAMESPACE" logs -f "$pod_name"
fi

# ----------------- Action: Port Forward -----------------
if [[ "$ACTION" == "port-forward" ]]; then
    svc_name="$("$KUBECTL" -n "$NAMESPACE" get svc -l "app.kubernetes.io/name=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$svc_name" ]]; then
        svc_name="sglang-service"
    fi
    echo "=== Port-Forwarding $svc_name (${PORT}:${PORT}) ==="
    echo "Endpoint will be reachable at http://localhost:${PORT}/v1/models"
    echo "Press Ctrl+C to stop port-forwarding."
    exec "$KUBECTL" -n "$NAMESPACE" port-forward "svc/${svc_name}" "${PORT}:${PORT}"
fi

# ----------------- Action: Delete / Uninstall -----------------
if [[ "$ACTION" == "delete" ]]; then
    echo "=== Deleting SGLang Resources ==="
    if command -v "$HELM" >/dev/null 2>&1 && "$HELM" status sglang -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "[*] Uninstalling Helm release 'sglang'..."
        "$HELM" uninstall sglang -n "$NAMESPACE"
    else
        echo "[*] Deleting raw manifests..."
        "$KUBECTL" delete -k "${REPO_ROOT}/k8s" -n "$NAMESPACE" --ignore-not-found=true
        "$KUBECTL" delete secret hf-token-secret -n "$NAMESPACE" --ignore-not-found=true
    fi
    echo "[+] Done."
    exit 0
fi

# ----------------- Action: Deploy -----------------
echo "=== SGLang Kubernetes Launcher ==="
echo "Model:            $MODEL"
echo "API Alias:        $SERVED_NAME"
echo "Port:             $PORT"
echo "Service Type:     $SERVICE_TYPE"
echo "Namespace:        $NAMESPACE"
echo "Deployer:         $DEPLOYER"
echo "Mem Fraction:     $MEM_FRACTION"

# Check GPU capability on cluster
if ! "$KUBECTL" get nodes -o yaml 2>/dev/null | grep -q "nvidia.com/gpu"; then
    echo ""
    echo "[!] Notice: 'nvidia.com/gpu' was not detected in cluster node allocatables."
    echo "    If using MicroK8s on this machine, enable GPU support by running:"
    echo "      microk8s enable gpu"
    echo ""
fi

# Handle secret creation if HF_TOKEN is available
if [[ -n "$HF_TOKEN_VAL" && "$DRY_RUN" == false ]]; then
    echo "[*] Configuring Hugging Face token secret in namespace '$NAMESPACE'..."
    "$KUBECTL" create secret generic hf-token-secret \
        --namespace "$NAMESPACE" \
        --from-literal="HF_TOKEN=${HF_TOKEN_VAL}" \
        --dry-run=client -o yaml | "$KUBECTL" apply -f -
fi

# Execute deployment via Helm
if [[ "$DEPLOYER" == "helm" ]] && command -v "$HELM" >/dev/null 2>&1; then
    CHART_DIR="${REPO_ROOT}/helm/sglang"
    helm_args=(
        --set "model=${MODEL}"
        --set "servedModelName=${SERVED_NAME}"
        --set "service.type=${SERVICE_TYPE}"
        --set "service.port=${PORT}"
        --set "memFractionStatic=${MEM_FRACTION}"
        --set "resources.limits.nvidia\.com/gpu=${GPU_COUNT}"
        --set "resources.requests.nvidia\.com/gpu=${GPU_COUNT}"
    )

    if [[ -n "$NODE_PORT" ]]; then
        helm_args+=(--set "service.nodePort=${NODE_PORT}")
    fi

    if [[ -n "$HF_TOKEN_VAL" ]]; then
        helm_args+=(--set "existingSecret=hf-token-secret")
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "=== Helm Dry-Run Template Output ==="
        "$HELM" template sglang "$CHART_DIR" "${helm_args[@]}"
        exit 0
    fi

    echo "[*] Deploying Helm release 'sglang'..."
    "$HELM" upgrade --install sglang "$CHART_DIR" -n "$NAMESPACE" "${helm_args[@]}"

else
    MANIFEST="${REPO_ROOT}/k8s/sglang.yaml"
    if [[ "$DRY_RUN" == true ]]; then
        echo "=== Kubectl Dry-Run Manifest Output ==="
        "$KUBECTL" apply --dry-run=client -f "$MANIFEST" -o yaml
        exit 0
    fi

    echo "[*] Applying manifest $MANIFEST..."
    "$KUBECTL" apply -f "$MANIFEST" -n "$NAMESPACE"
fi

echo ""
echo "[+] Deployment submitted successfully!"
echo ""
echo "Next steps:"
echo "  1. View pod startup:      ./src/run-sglang-k8s.sh --status"
echo "  2. Stream download logs:  ./src/run-sglang-k8s.sh --logs"
if [[ "$SERVICE_TYPE" == "ClusterIP" ]]; then
    echo "  3. Start port-forwarding: ./src/run-sglang-k8s.sh --port-forward"
    echo "  4. Test endpoint:         curl http://localhost:${PORT}/v1/models"
fi
