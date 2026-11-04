#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { printf "${BLUE}[*]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
log_error()   { printf "${RED}[-]${NC} %s\n" "$*" >&2; }

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
PORT=""
NAMESPACE="default"
TIMEOUT=300
SKIP_DEPLOY=false
CLEANUP_AFTER=false
RUN_PYTHON=false
PREFLIGHT_ONLY=false
DEPLOYER="helm"

PF_PID=""

usage() {
    cat <<'EOF'
Usage:
  test-k8s.sh [options]

Automated test runner for SGLang Kubernetes deployments.
Performs preflight checks, deploys or connects to pod, port-forwards,
and executes end-to-end OpenAI-compatible API assertions.

Options:
  --model MODEL       Model name/ID (default: Qwen/Qwen3-0.6B).
  --name NAME         API-visible model alias (default: qwen-small).
  --port PORT         Local port to forward to (default: 30000).
  --namespace NS      Kubernetes namespace (default: default).
  --timeout SECS      Timeout in seconds waiting for pod readiness (default: 300).
  --deployer TOOL     Deployer to use: 'helm' (default) or 'kubectl'.
  --skip-deploy       Skip deployment and test against an existing running pod/service.
  --cleanup           Delete the deployment and secrets after testing finishes.
  --python            Run the Python API test suite.
  --preflight-only    Run only cluster and environment preflight checks without deploying.
  -h, --help          Show this help text.

Examples:
  ./src/test-k8s.sh
  ./src/test-k8s.sh --skip-deploy
  ./src/test-k8s.sh --python
  ./src/test-k8s.sh --preflight-only
  ./src/test-k8s.sh --cleanup
EOF
}

die() {
    log_error "$1"
    exit 2
}

# Cleanup handler for port-forward and optional resource teardown
cleanup_handler() {
    local exit_code=$?
    if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
        log_info "Terminating background port-forward (PID: $PF_PID)..."
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi

    if [[ "$CLEANUP_AFTER" == true ]]; then
        log_info "Teardown requested (--cleanup). Deleting Kubernetes deployment..."
        "${SCRIPT_DIR}/run-sglang-k8s.sh" --delete --namespace "$NAMESPACE" >/dev/null 2>&1 || true
        log_success "Cleanup complete."
    fi

    exit "$exit_code"
}

trap cleanup_handler EXIT INT TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --port)
            [[ $# -ge 2 && -n "$2" ]] || die "--port requires a value"
            PORT="$2"
            shift 2
            ;;
        --namespace|-n)
            [[ $# -ge 2 && -n "$2" ]] || die "--namespace requires a value"
            NAMESPACE="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 && -n "$2" ]] || die "--timeout requires a value"
            TIMEOUT="$2"
            shift 2
            ;;
        --deployer)
            [[ $# -ge 2 && -n "$2" ]] || die "--deployer requires a value"
            DEPLOYER="$2"
            shift 2
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --cleanup)
            CLEANUP_AFTER=true
            shift
            ;;
        --python)
            RUN_PYTHON=true
            shift
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=true
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

printf "${BOLD}====================================================${NC}\n"
printf "${BOLD}        SGLang Kubernetes Automated Test Runner      ${NC}\n"
printf "${BOLD}====================================================${NC}\n"
printf "Model:           %s\n" "$MODEL"
printf "Served Name:     %s\n" "$SERVED_NAME"
printf "Target Port:     %s\n" "$PORT"
printf "Namespace:       %s\n" "$NAMESPACE"
printf "Skip Deploy:     %s\n" "$SKIP_DEPLOY"
printf "Run Python:      %s\n" "$RUN_PYTHON"
printf "Cleanup Deploy:  %s\n" "$CLEANUP_AFTER"
printf "Timeout:         %ds\n\n" "$TIMEOUT"

# ==============================================================================
# Phase 1: Preflight Verification
# ==============================================================================
log_info "Phase 1: Running cluster & tooling preflight checks..."

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
    die "Kubectl binary not found. Install kubectl or microk8s."
fi
log_success "Kubectl detected: $($KUBECTL version --client -o yaml 2>/dev/null | grep -m1 'gitVersion' || echo 'available')"

if ! "$KUBECTL" get nodes >/dev/null 2>&1; then
    die "Failed to connect to Kubernetes cluster via $KUBECTL."
fi
NODE_NAME="$("$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo 'unknown')"
log_success "Cluster connected. Primary node: $NODE_NAME"

if command -v "$HELM" >/dev/null 2>&1; then
    if "$HELM" version >/dev/null 2>&1; then
        log_success "Helm connected: $($HELM version --short 2>/dev/null || echo 'available')"
    else
        log_warn "Helm found ($HELM) but cluster connection test failed."
    fi
else
    log_warn "Helm not found in PATH. Deployer fallback to kubectl manifests."
fi

HAS_GPU=false
GPU_ALLOC="$("$KUBECTL" get nodes -o custom-columns=GPUS:.status.allocatable."nvidia\.com/gpu" --no-headers 2>/dev/null || echo "")"
if [[ -n "$GPU_ALLOC" && "$GPU_ALLOC" != "<none>" && "$GPU_ALLOC" != "0" ]]; then
    HAS_GPU=true
    log_success "Node GPU resource allocatable: nvidia.com/gpu = $GPU_ALLOC"
else
    log_warn "Node GPU resource 'nvidia.com/gpu' is NOT currently allocatable on $NODE_NAME."
    if command -v microk8s >/dev/null 2>&1; then
        log_warn "If using MicroK8s, enable GPU support by running:"
        printf "    ${CYAN}microk8s enable gpu${NC}\n"
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    die "'curl' command is required for endpoint testing."
fi

if [[ "$RUN_PYTHON" == true ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
        die "python3 is required when using --python flag."
    fi
    if ! python3 -c "import requests" >/dev/null 2>&1; then
        log_warn "Python 'requests' library not found. Install via: pip install requests"
    else
        log_success "Python 3 and requests library available."
    fi
fi

if [[ "$PREFLIGHT_ONLY" == true ]]; then
    log_success "Preflight checks complete (--preflight-only)."
    exit 0
fi

if [[ "$HAS_GPU" == false && "$SKIP_DEPLOY" == false ]]; then
    log_error "Cannot deploy GPU workload without allocatable 'nvidia.com/gpu' resources."
    log_error "Please enable GPU on your cluster first (e.g. 'microk8s enable gpu')."
    log_error "To test an existing CPU/mock service instead, re-run with --skip-deploy."
    exit 1
fi

# ==============================================================================
# Phase 2: Deployment Orchestration
# ==============================================================================
if [[ "$SKIP_DEPLOY" == false ]]; then
    log_info "Phase 2: Deploying SGLang via ${SCRIPT_DIR}/run-sglang-k8s.sh..."
    "${SCRIPT_DIR}/run-sglang-k8s.sh" \
        --model "$MODEL" \
        --name "$SERVED_NAME" \
        --port "$PORT" \
        --namespace "$NAMESPACE" \
        --deployer "$DEPLOYER"
else
    log_info "Phase 2: Skipping deployment (--skip-deploy specified)."
fi

# ==============================================================================
# Phase 3: Pod Readiness Polling
# ==============================================================================
log_info "Phase 3: Waiting for SGLang pod to reach Ready status (Timeout: ${TIMEOUT}s)..."

get_pod_name() {
    local name
    name="$("$KUBECTL" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$name" ]]; then
        name="$("$KUBECTL" -n "$NAMESPACE" get pods -l "app=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    echo "$name"
}

start_time=$(date +%s)
pod_ready=false

while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [[ $elapsed -ge $TIMEOUT ]]; then
        break
    fi

    POD_NAME="$(get_pod_name)"
    if [[ -n "$POD_NAME" ]]; then
        POD_PHASE="$("$KUBECTL" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")"
        CONTAINER_READY="$("$KUBECTL" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")"
        WAIT_REASON="$("$KUBECTL" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")"
        RESTARTS="$("$KUBECTL" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")"

        if [[ "$CONTAINER_READY" == "true" ]]; then
            pod_ready=true
            log_success "Pod $POD_NAME is READY! (elapsed: ${elapsed}s)"
            break
        else
            state_info="${POD_PHASE}"
            if [[ -n "$WAIT_REASON" ]]; then
                state_info="${state_info}:${WAIT_REASON}"
            fi
            if [[ "$RESTARTS" =~ ^[0-9]+$ && "$RESTARTS" -gt 0 ]]; then
                state_info="${state_info} (restarts: ${RESTARTS})"
            fi
            printf "\r${BLUE}[*]${NC} Pod: %s (State: %s, Ready: %s) [%ds/%ds]...   " "$POD_NAME" "$state_info" "$CONTAINER_READY" "$elapsed" "$TIMEOUT"

            if [[ "$WAIT_REASON" =~ (CrashLoopBackOff|ImagePullBackOff|ErrImagePull) && "$elapsed" -ge 30 ]]; then
                echo ""
                log_error "Container entered failed state: ${WAIT_REASON} (Pod: ${POD_NAME})"
                log_warn "Recent pod events:"
                "$KUBECTL" -n "$NAMESPACE" describe pod "$POD_NAME" | tail -n 25 || true
                log_warn "Pod logs:"
                "$KUBECTL" -n "$NAMESPACE" logs --tail=50 "$POD_NAME" 2>/dev/null || true
                exit 1
            fi
        fi
    else
        printf "\r${BLUE}[*]${NC} Waiting for pod creation in namespace '%s' [%ds/%ds]...   " "$NAMESPACE" "$elapsed" "$TIMEOUT"
    fi

    sleep 5
done
echo ""

if [[ "$pod_ready" == false ]]; then
    log_error "Timeout reached waiting for SGLang pod readiness."
    POD_NAME="$(get_pod_name)"
    if [[ -n "$POD_NAME" ]]; then
        log_warn "Recent events for $POD_NAME:"
        "$KUBECTL" -n "$NAMESPACE" describe pod "$POD_NAME" | tail -n 25 || true
        log_warn "Recent pod container logs:"
        "$KUBECTL" -n "$NAMESPACE" logs --tail=40 "$POD_NAME" 2>/dev/null || true
    fi
    exit 1
fi

# ==============================================================================
# Phase 4: Port-Forwarding Setup
# ==============================================================================
log_info "Phase 4: Establishing background port-forwarding to local port $PORT..."

SVC_NAME="$("$KUBECTL" -n "$NAMESPACE" get svc -l "app.kubernetes.io/name=sglang" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$SVC_NAME" ]]; then
    SVC_NAME="sglang-service"
fi

if command -v nc >/dev/null 2>&1 && nc -z localhost "$PORT" 2>/dev/null; then
    log_warn "Port $PORT is already open on localhost. Checking if existing service is reachable..."
else
    PF_LOG=$(mktemp /tmp/sglang-pf-XXXXXX.log)
    "$KUBECTL" -n "$NAMESPACE" port-forward "svc/${SVC_NAME}" "${PORT}:${PORT}" >"$PF_LOG" 2>&1 &
    PF_PID=$!
    log_info "Background port-forward started (PID: $PF_PID, Log: $PF_LOG)"
fi

log_info "Verifying HTTP endpoint connectivity at http://localhost:${PORT}..."
conn_ok=false
for i in {1..10}; do
    if curl -s -f "http://localhost:${PORT}/health" >/dev/null 2>&1; then
        conn_ok=true
        log_success "Local HTTP connection confirmed on port $PORT."
        break
    fi
    sleep 2
done

if [[ "$conn_ok" == false ]]; then
    POD_IP="$("$KUBECTL" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")"
    if [[ -n "$POD_IP" ]] && curl -s -f "http://${POD_IP}:${PORT}/health" >/dev/null 2>&1; then
        log_warn "kubectl port-forward experienced a cluster proxy issue, but Pod IP (${POD_IP}) is directly reachable."
        log_info "Establishing local bridge on port ${PORT} to pod ${POD_IP}:${PORT}..."
        if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
            kill "$PF_PID" 2>/dev/null || true
        fi
        if command -v socat >/dev/null 2>&1; then
            socat "TCP-LISTEN:${PORT},fork,reuseaddr" "TCP:${POD_IP}:${PORT}" >/dev/null 2>&1 &
            PF_PID=$!
        else
            python3 -c "
import socket, threading
l = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
l.bind(('127.0.0.1', ${PORT}))
l.listen(50)
def pipe(src, dst):
    try:
        while True:
            d = src.recv(4096)
            if not d: break
            dst.sendall(d)
    except: pass
    finally:
        src.close()
        dst.close()
while True:
    c, _ = l.accept()
    r = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        r.connect(('${POD_IP}', ${PORT}))
        threading.Thread(target=pipe, args=(c, r), daemon=True).start()
        threading.Thread(target=pipe, args=(r, c), daemon=True).start()
    except:
        c.close()
" &
            PF_PID=$!
        fi
        sleep 1
        if curl -s -f "http://localhost:${PORT}/health" >/dev/null 2>&1; then
            conn_ok=true
            log_success "Local bridge established at http://localhost:${PORT}."
        fi
    fi
fi

if [[ "$conn_ok" == false ]]; then
    log_error "Failed to connect to http://localhost:${PORT}/health after port-forwarding."
    if [[ -n "${PF_LOG:-}" && -f "$PF_LOG" ]]; then
        cat "$PF_LOG" >&2
    fi
    exit 1
fi

# ==============================================================================
# Phase 5: Test Execution & Assertions
# ==============================================================================
log_info "Phase 5: Executing API Assertions against http://localhost:${PORT}..."

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local endpoint="$2"
    local method="$3"
    local payload="${4:-}"
    local validate_regex="${5:-}"

    printf "${BOLD}Test: %s${NC} (%s %s) ... " "$test_name" "$method" "$endpoint"

    local start_ts
    start_ts=$(date +%s%N 2>/dev/null || date +%s)
    local http_code
    local response_body

    if [[ "$method" == "GET" ]]; then
        response_body=$(curl -s -w "\n%{http_code}" -X GET "http://localhost:${PORT}${endpoint}" || echo "000")
    else
        response_body=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:${PORT}${endpoint}" \
            -H "Content-Type: application/json" \
            -d "$payload" || echo "000")
    fi

    http_code=$(echo "$response_body" | tail -n 1)
    local body
    body=$(echo "$response_body" | sed '$d')

    local end_ts
    end_ts=$(date +%s%N 2>/dev/null || date +%s)
    local duration_ms=0
    if [[ ${#start_ts} -gt 10 && ${#end_ts} -gt 10 ]]; then
        duration_ms=$(( (end_ts - start_ts) / 1000000 ))
    fi

    if [[ "$http_code" =~ ^20[0-9]$ ]]; then
        if [[ -n "$validate_regex" ]]; then
            if echo "$body" | grep -Eq "$validate_regex"; then
                printf "${GREEN}PASS${NC} (HTTP %s, %dms)\n" "$http_code" "$duration_ms"
                TESTS_PASSED=$((TESTS_PASSED + 1))
                return 0
            else
                printf "${RED}FAIL${NC} (Regex mismatch: '%s')\n" "$validate_regex"
                printf "    Response: %s\n" "$body"
                TESTS_FAILED=$((TESTS_FAILED + 1))
                return 1
            fi
        else
            printf "${GREEN}PASS${NC} (HTTP %s, %dms)\n" "$http_code" "$duration_ms"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        fi
    else
        printf "${RED}FAIL${NC} (HTTP %s)\n" "$http_code"
        printf "    Response: %s\n" "$body"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

run_test "Health Endpoint" "/health" "GET" "" ""
run_test "Model Discovery" "/v1/models" "GET" "" "(\"id\":|\"object\":\"list\")"

CHAT_PAYLOAD=$(cat <<EOF
{
  "model": "${SERVED_NAME}",
  "messages": [
    {"role": "user", "content": "Reply with the exact word PONG and nothing else."}
  ],
  "max_tokens": 16,
  "temperature": 0.0
}
EOF
)
run_test "Chat Completion" "/v1/chat/completions" "POST" "$CHAT_PAYLOAD" "(\"content\":|\"choices\":)"

# ==============================================================================
# Phase 6: Optional Python Test Suite (--python)
# ==============================================================================
if [[ "$RUN_PYTHON" == true ]]; then
    log_info "Phase 6: Executing Python test suite via src/test-sglang.py..."
    if python3 "${SCRIPT_DIR}/test-sglang.py" --url "http://localhost:${PORT}/v1" --mode all --model "$SERVED_NAME"; then
        log_success "Python test suite executed successfully!"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "Python test suite encountered errors."
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

# ==============================================================================
# Summary Report
# ==============================================================================
printf "\n${BOLD}====================================================${NC}\n"
printf "${BOLD}               Test Execution Summary                ${NC}\n"
printf "${BOLD}====================================================${NC}\n"
printf "Total Tests Run:    %d\n" $((TESTS_PASSED + TESTS_FAILED))
printf "Passed:             ${GREEN}%d${NC}\n" "$TESTS_PASSED"
printf "Failed:             ${RED}%d${NC}\n" "$TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
    printf "\n${GREEN}${BOLD}[SUCCESS] All Kubernetes SGLang tests passed!${NC}\n\n"
    exit 0
else
    printf "\n${RED}${BOLD}[FAILURE] Some Kubernetes SGLang tests failed.${NC}\n\n"
    exit 1
fi
