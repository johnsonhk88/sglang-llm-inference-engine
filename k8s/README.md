# Kubernetes Deployment for SGLang

This directory provides Kubernetes manifests and a Helm chart to deploy **SGLang** on a GPU cluster.

## Architecture & Features

- **Production-Ready Networking**: Uses `ClusterIP` by default to keep the serving engine on the cluster private network.
- **Shared Memory Volume (`/dev/shm`)**: Mounts an in-memory `emptyDir` at `/dev/shm` required for PyTorch tensor parallelism.
- **Cache Persistence**: Mounts the host cache (`~/.cache/huggingface`) via `hostPath` so models already downloaded are reused.
- **Probes**: Readiness (`/v1/models`) and liveness (`/health`) so Kubernetes only routes traffic once weights are loaded.
- **Automated GPU Scheduling**: Requests `nvidia.com/gpu: 1`.
- **Metrics**: `--enable-metrics` is on by default so `/metrics` is available for Prometheus.
- **Optional ServiceMonitor**: `--set monitoring.enabled=true` scrapes `/metrics` when Prometheus Operator CRDs exist.

---

## 1. Prerequisites (MicroK8s / Kubernetes)

### Enable GPU Support

If you are running MicroK8s, enable the NVIDIA GPU addon:

```bash
microk8s enable gpu
```

Verify that the node lists `nvidia.com/gpu` under allocatable resources:

```bash
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

### Set Hugging Face Token (Optional)

```bash
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="hf_your_token_here"
```

The helper script `./src/run-sglang-k8s.sh` creates this secret automatically if your token is defined in `.env`.

---

## 2. Quickstart via CLI Helper Script (`src/run-sglang-k8s.sh`)

```bash
./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

### Monitor & Stream Logs

```bash
./src/run-sglang-k8s.sh --status
./src/run-sglang-k8s.sh --logs
```

### Port-Forward & Test Locally

```bash
./src/run-sglang-k8s.sh --port-forward
```

In another terminal:

```bash
curl http://localhost:30000/health
curl http://localhost:30000/v1/models
curl -s http://localhost:30000/metrics | head
./src/bench-sglang.sh --model qwen-small
```

---

## 3. Deploying via Helm (`helm/sglang/`)

```bash
helm upgrade --install sglang ./helm/sglang \
  --set model=Qwen/Qwen3-0.6B \
  --set servedModelName=qwen-small \
  --set service.type=ClusterIP
```

### Optional: Use NodePort for Direct LAN Access

```bash
helm upgrade --install sglang ./helm/sglang \
  --set service.type=NodePort \
  --set service.nodePort=30300
```

Then access `http://<node-ip>:30300/v1/models`.

### Uninstall Helm Release

```bash
helm uninstall sglang
```

### Deploy-time serving knobs

These restart the pod; they are not autoscaled.

| Value | SGLang flag | Purpose |
| --- | --- | --- |
| `memFractionStatic` | `--mem-fraction-static` | Fraction of GPU memory for weights + KV cache. Lower this on OOM. |
| `maxRunningRequests` | `--max-running-requests` | Max concurrent running requests **per copy**. |
| `tensorParallelSize` | `--tp-size` | Split **one** model across GPUs. Match `resources.limits.nvidia.com/gpu` yourself. |
| `contextLength` | `--context-length` | Override model context length. |
| `enableMetrics` | `--enable-metrics` | Expose Prometheus `/metrics`. Default `true`. |
| `monitoring.enabled` | ServiceMonitor | Opt-in scrape. Default `false` so clusters without the CRD keep working. |
| `extraArgs` | passthrough | Extra `sglang.launch_server` flags. |

```bash
helm upgrade --install sglang ./helm/sglang \
  --set maxRunningRequests=32 \
  --set tensorParallelSize=2 \
  --set resources.limits."nvidia\.com/gpu"=2 \
  --set resources.requests."nvidia\.com/gpu"=2
```

Scrape metrics (requires Prometheus Operator on the cluster — not vendored):

```bash
helm upgrade --install sglang ./helm/sglang \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

Import [`monitoring/grafana/dashboards/sglang-capacity.json`](../monitoring/grafana/dashboards/sglang-capacity.json)
into cluster Grafana for GPU/CPU/RAM, KV-cache, waiting-request queue, and
token throughput. Panel-by-panel usage: [`monitoring/README.md`](../monitoring/README.md).

---

## 4. Deploying via Raw Manifests (`k8s/`)

```bash
kubectl apply -f k8s/sglang.yaml

# Or via Kustomize
kubectl apply -k k8s/
```

To delete:

```bash
kubectl delete -f k8s/sglang.yaml
```

---

## 5. Automated Testing Runner (`src/test-k8s.sh`)

```bash
./src/test-k8s.sh
./src/test-k8s.sh --skip-deploy
./src/test-k8s.sh --python
./src/test-k8s.sh --preflight-only
./src/test-k8s.sh --cleanup
```

---

## 6. Serving & Usage Guide

- **[k8s/USAGE.md](USAGE.md)**: Serving workflows, client access methods (ClusterIP, NodePort, In-Cluster), API examples, and tokens/s bench.
- **[k8s/DEBUG_GUIDE.md](DEBUG_GUIDE.md)**: GPU addon, Helm KUBECONFIG, shared memory, probe failures, and `/metrics` scrape.
- **[monitoring/README.md](../monitoring/README.md)**: Grafana **SGLang Capacity** dashboard and Docker Compose Prometheus.
