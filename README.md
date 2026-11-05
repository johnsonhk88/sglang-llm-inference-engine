# SGLang LLM Inference Engine

Scripts for running and testing [SGLang](https://github.com/sgl-project/sglang) with Docker, Kubernetes, the CLI, and Python.

## Available Launchers

| Launcher / Interface | Deployment Target | Default Port | Primary Endpoints |
| --- | --- | --- | --- |
| `src/run-sglang-docker.sh` | Docker (Text LLMs) | `30000` | `/health`, `/v1/models`, `/v1/chat/completions`, `/metrics` |
| `src/run-sglang-k8s.sh` | Kubernetes / MicroK8s (Helm & Manifests) | `30000` | Production `ClusterIP` (with port-forward) or `NodePort` |
| `src/test-k8s.sh` | Kubernetes Automated Test Runner | `30000` | Preflight, Pod Readiness, API Assertions, & Teardown |
| `src/bench-sglang.sh` | Tokens/s load test (`sglang.benchmark.serving`) | `30000` | Output tok/s, TTFT, TPOT |
| `helm/sglang/` | Helm Chart | Configurable | Parameterized K8s Deployment & Service |
| `k8s/` | Raw Declarative K8s Manifests | Configurable | Standalone YAML & Kustomize manifests |
| `monitoring/` | Docker Compose Prometheus/Grafana/DCGM | `9090` / `3000` | SGLang `/metrics`, GPU, CPU, RAM |

The Docker launcher:

- Passes arbitrary SGLang parameters through to `python3 -m sglang.launch_server`.
- Re-executes under Bash automatically when called via `sh`.
- Maps container ports, sets `--shm-size 32g`, and mounts the local Hugging Face model cache (`~/.cache/huggingface`).
- Forwards `HF_TOKEN` from the shell environment.
- Adds `--enable-metrics` so `/metrics` is available for Prometheus.

---

## Prerequisites

Install and verify the following before starting either launcher:

1. **NVIDIA GPU** with a **CUDA 13-compatible** driver. Official `lmsysorg/sglang` images ship CUDA 13.
2. **Docker Engine**.
3. **NVIDIA Container Toolkit**, ensuring Docker supports `--gpus all`.
4. **Hugging Face Account & Token** for gated/private models.

Export your Hugging Face token in your terminal:

```bash
export HF_TOKEN="hf_your_token_here"
```

Verify Docker GPU acceleration (toolkit check only; the SGLang image still needs a CUDA 13 driver):

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

Offline docs/Helm/script checks (no GPU required):

```bash
bash tests/run.sh
```

---

## 1. Text LLM Serving (`run-sglang-docker.sh`)

Use this script for standard text-based autoregressive models.

### Step-by-Step Quickstart

#### Step 1: Start a Model

```bash
./src/run-sglang-docker.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --mem-fraction-static 0.2
```

*(You can also run via `bash src/run-sglang-docker.sh ...` or `sh src/run-sglang-docker.sh ...`)*

Wait for `The server is fired up and ready to roll!`

#### Step 2: Verify Server Readiness

In another terminal:

```bash
curl http://localhost:30000/health
curl http://localhost:30000/v1/models
curl -s http://localhost:30000/metrics | head
```

#### Step 3: Send a Chat Request

```bash
curl -X POST "http://localhost:30000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

The terminal running Docker remains attached. `Ctrl+C` stops and removes the container because the launcher uses `--rm`.

### Options Reference

```text
Usage:
  run-sglang-docker.sh --model MODEL [launcher options] [SGLang options...]
```

| Option | Default | Description |
| --- | --- | --- |
| `--model MODEL` | Required | Hugging Face model ID or local model path (`--model-path`). |
| `--name NAME` | SGLang default | API-visible name (passed as `--served-model-name`). |
| `--hf-token TOKEN` | `$HF_TOKEN` | Hugging Face access token (alias: `--token`). |
| `--image IMAGE` | `lmsysorg/sglang:latest` | Docker image to run. |
| `--port PORT` | `30000` | Host and container port mapping. |
| `--shm-size SIZE` | `32g` | Docker shared memory size. |
| `-h`, `--help` | None | Show usage help. |

`--enable-metrics` is added automatically so `/metrics` is available for Prometheus. All remaining arguments (e.g. `--mem-fraction-static`, `--context-length`, `--tp-size`) are passed directly to SGLang inside the container.

The container always listens on `0.0.0.0` so host port mapping works. SGLang's own default host is `127.0.0.1`.

---

## 2. Python Testing Tools

Install LiteLLM (optional, recommended):

```bash
pip install litellm requests
```

### Python CLI Runner (`src/test-sglang.py`)

```bash
# 1. Health check & model listing
python3 src/test-sglang.py --mode models

# 2. Chat completion
python3 src/test-sglang.py --mode chat --model qwen-small

# 3. Run health, models, and chat
python3 src/test-sglang.py --mode all
```

Use `python3 src/test-sglang.py --help` for all options.

### LiteLLM snippet

```python
import litellm

response = litellm.completion(
    model="openai/qwen-small",
    api_base="http://localhost:30000/v1",
    api_key="none",
    messages=[
        {"role": "user", "content": "What is the capital of France?"}
    ],
)
print(response.choices[0].message.content)
```

---

## 3. Kubernetes Deployment (`k8s/` & `helm/sglang/`)

Production-ready Kubernetes deployment supporting both raw manifests and a Helm chart.

### Prerequisite: Enable GPU (MicroK8s)

If using MicroK8s on this machine, enable GPU support first:

```bash
microk8s enable gpu
```

### Quickstart via Helper Script (`src/run-sglang-k8s.sh`)

Uses production `ClusterIP` by default:

```bash
# 1. Deploy Text LLM
./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small

# 2. Check status & stream pod logs
./src/run-sglang-k8s.sh --status
./src/run-sglang-k8s.sh --logs

# 3. Port-forward ClusterIP service to local port
./src/run-sglang-k8s.sh --port-forward
```

### Deploying via Helm

```bash
helm upgrade --install sglang ./helm/sglang \
  --set model=Qwen/Qwen3-0.6B \
  --set servedModelName=qwen-small
```

### Step-by-Step Kubernetes Testing Guide

#### Option A: Automated Testing Runner (`src/test-k8s.sh`)

```bash
# 1. Run cluster and GPU preflight checks only
./src/test-k8s.sh --preflight-only

# 2. Run automated test suite (Qwen/Qwen3-0.6B)
./src/test-k8s.sh

# 3. Test with Python assertions enabled
./src/test-k8s.sh --python

# 4. Test an existing deployment without re-deploying
./src/test-k8s.sh --skip-deploy

# 5. Run test and automatically clean up resources on completion
./src/test-k8s.sh --cleanup
```

#### Option B: Manual Step-by-Step Testing

##### Step 1: Ensure Cluster GPU Support

```bash
microk8s enable gpu
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

##### Step 2: Deploy SGLang

```bash
./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

##### Step 3: Monitor Pod Readiness & Logs

```bash
./src/run-sglang-k8s.sh --status
./src/run-sglang-k8s.sh --logs
```

##### Step 4: Port-Forward Service

```bash
./src/run-sglang-k8s.sh --port-forward
```

##### Step 5: Test Endpoints via curl

```bash
curl http://localhost:30000/health
curl http://localhost:30000/v1/models
curl -X POST "http://localhost:30000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

##### Step 6: Test with the Python Test Suite

```bash
python3 src/test-sglang.py --url http://localhost:30000/v1 --mode all
```

See [`k8s/USAGE.md`](k8s/USAGE.md) for serving options and client integration. Cluster manifests and Helm parameters are documented in [`k8s/README.md`](k8s/README.md).

---

## 4. Tokens/s Benchmark (`src/bench-sglang.sh`)

With a server already running on port `30000`:

```bash
# Smoke: 32 prompts, 256 in / 128 out, concurrency 4
./src/bench-sglang.sh --model qwen-small

# Saturate the GPU
./src/bench-sglang.sh --profile throughput --model qwen-small

# Live Prometheus snapshot (no load)
./src/bench-sglang.sh --metrics-only
```

The bench runner uses `docker run --network host lmsysorg/sglang:latest python3 -m sglang.benchmark.serving`. Quote **Output token throughput (tok/s)** from the summary. TTFT and TPOT are in the same report. For Kubernetes ClusterIP, run `./src/run-sglang-k8s.sh --port-forward` first.

| Option | Default | Description |
| --- | --- | --- |
| `--profile NAME` | `smoke` | `smoke` (32 prompts, 256/128, concurrency 4) or `throughput` (200 prompts, 1024/256, concurrency 16). |
| `--model NAME` | first `/v1/models` id | API-visible alias (`qwen-small`), not the Hugging Face repo id. |
| `--port PORT` | `30000` | Server port. |
| `--url URL` | `http://127.0.0.1:30000` | Full base URL (overrides `--port`). |
| `--metrics-only` | off | Print `/metrics` snapshot; do not run the load test. |
| `--dry-run` | off | Print the bench command without running it. |

---

## 5. Prometheus Monitoring (`monitoring/`)

Prometheus scrapes SGLang's `/metrics` endpoint; Grafana is only the visualization layer. DCGM and node-exporter add GPU and host metrics. Full operator guide: [`monitoring/README.md`](monitoring/README.md).

### Step 1: Confirm SGLang exposes metrics

The Docker launcher and Helm chart add `--enable-metrics` automatically. For a manual launch:

```bash
python3 -m sglang.launch_server \
  --model-path Qwen/Qwen3-0.6B \
  --host 0.0.0.0 \
  --port 30000 \
  --enable-metrics
```

```bash
curl -s http://localhost:30000/metrics | head
```

A 404 means `--enable-metrics` is missing. Use `--host 0.0.0.0` when Prometheus runs in another container or on another host.

### Step 2: Start Prometheus, Grafana, DCGM, and node-exporter

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

| Service | URL |
| --- | --- |
| Prometheus | http://localhost:9090 |
| Grafana (`admin` / `admin`) | http://localhost:3000 |
| Dashboard **SGLang Capacity** | http://localhost:3000/d/sglang-capacity |

The SGLang scrape job is defined in [`monitoring/prometheus/prometheus.yml`](monitoring/prometheus/prometheus.yml):

```yaml
- job_name: sglang
  metrics_path: /metrics
  static_configs:
    - targets: ["host.docker.internal:30000"]
```

Open http://localhost:9090/targets and confirm `sglang` is **UP**, or query:

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job="sglang"}'
```

`"1"` is healthy; `"0"` means the scrape failed. See **Last error** on the target page. To scrape a different host or port, edit `prometheus.yml` and restart Prometheus.

### Step 3: Query serving metrics

Paste these into the Prometheus UI (http://localhost:9090):

| Question | PromQL |
| --- | --- |
| Running / waiting requests | `sum(sglang:num_running_reqs)` / `sum(sglang:num_queue_reqs)` |
| Prompt tokens/s | `sum(rate(sglang:prompt_tokens_total[1m]))` |
| Generation tokens/s | `sum(rate(sglang:generation_tokens_total[1m]))` |
| KV-cache fill | `avg(sglang:token_usage)` |
| TTFT p95 | `histogram_quantile(0.95, sum by (le) (rate(sglang:time_to_first_token_seconds_bucket[5m])))` |
| GPU utilization | `DCGM_FI_DEV_GPU_UTIL` |
| GPU VRAM used | `DCGM_FI_DEV_FB_USED * 1024 * 1024` |

Counters stay at 0 until traffic arrives:

```bash
./src/bench-sglang.sh --profile throughput --model qwen-small
```

### Step 4: Open the dashboard

Grafana is at http://localhost:3000 (`admin` / `admin`). Open **SGLang Capacity** (`/d/sglang-capacity`). You will see:

- **Token throughput** — prompt and generation tokens/s (`rate()` of counters)
- **Queue** — requests running vs waiting
- **GPU** — KV-cache fill, DCGM utilization, framebuffer (VRAM)
- **CPU / RAM** — node-exporter host CPU and available memory

If SGLang is on Kubernetes `ClusterIP`, port-forward `30000` before starting this compose stack so Prometheus can scrape `host.docker.internal:30000`.

### Kubernetes

The chart does **not** install Prometheus. Install Prometheus Operator (kube-prometheus-stack, or `microk8s enable observability`), then opt in:

```bash
helm upgrade --install sglang ./helm/sglang \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

The ServiceMonitor label must match the Prometheus release selector. Verify the target in Prometheus. Full steps: [`monitoring/README.md#8-kubernetes`](monitoring/README.md#8-kubernetes) and [`k8s/README.md`](k8s/README.md#prometheus-scraping-servicemonitor).

PromQL reference, scrape tuning, and alert examples: [`monitoring/README.md`](monitoring/README.md).

---

## Troubleshooting

### `set: Illegal option -o pipefail`

The launchers re-exec under Bash. You can run them via:

- `./src/run-sglang-docker.sh ...`
- `bash src/run-sglang-docker.sh ...`
- `sh src/run-sglang-docker.sh ...`

### Flag Syntax Tip: Avoid Spaces in `--name`

- **Correct**: `--name qwen-small`
- **Incorrect**: `-- name qwen-small`

### GPU Out-of-Memory (OOM)

- Lower `--mem-fraction-static` (e.g. `0.7` or `0.2` for smoke tests).
- Lower `--context-length` (e.g. `2048` or `4096`).
- For large models, use multi-GPU tensor parallelism: `--tp-size <num_gpus>`.
- Use quantized checkpoints (AWQ, FP8, GPTQ) where available.

### Port Conflicts

If port `30000` is in use, supply `--port <new_port>`:

```bash
./src/run-sglang-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small --port 30001
```

### Shared Memory Too Small

SGLang needs `/dev/shm` for tensor-parallel communication. The Docker launcher defaults to `--shm-size 32g`. Kubernetes manifests mount an in-memory `emptyDir` at `/dev/shm`.

### CUDA 13 Driver

Current `lmsysorg/sglang:latest` images require a CUDA 13-capable NVIDIA driver. CUDA 12 images (`-cu12` / `-cu129`) are no longer published.

### Bench cannot reach the server

`bench-sglang.sh` talks to `http://127.0.0.1:30000`. For Kubernetes ClusterIP, start port-forward first. If `/metrics` is empty or 404, the server was started without `--enable-metrics` (Docker and Helm enable it by default).

### Kubernetes Troubleshooting

See [`k8s/DEBUG_GUIDE.md`](k8s/DEBUG_GUIDE.md) for GPU addon issues, Helm without KUBECONFIG, hostPath cache, and probe failures.

---

## Documentation map

| Doc | Contents |
| --- | --- |
| [`k8s/README.md`](k8s/README.md) | Helm values, raw manifests, probes, ServiceMonitor |
| [`k8s/USAGE.md`](k8s/USAGE.md) | Client access (ClusterIP / NodePort / in-cluster) and API examples |
| [`k8s/DEBUG_GUIDE.md`](k8s/DEBUG_GUIDE.md) | GPU, shm, CUDA 13, cache, metrics scrape failures |
| [`monitoring/README.md`](monitoring/README.md) | Prometheus scraping, PromQL, alerts, Grafana dashboard, Docker Compose stack |
