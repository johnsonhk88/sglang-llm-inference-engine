# SGLang Kubernetes Debugging Guide

Real-world failure modes for this repo's Docker/Helm/MicroK8s path.

## 1. `nvidia.com/gpu` is not allocatable

**Symptom:** Pod stays `Pending` with `Insufficient nvidia.com/gpu`.

**Fix:**

```bash
microk8s enable gpu
kubectl get node -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable."nvidia\.com/gpu"
```

The NVIDIA device plugin must report at least `1` GPU. Host `nvidia-smi` working is not enough if the device plugin is not running.

## 2. Helm cannot talk to the cluster

**Symptom:** `Error: Kubernetes cluster unreachable` while `microk8s kubectl get nodes` works.

**Cause:** Helm uses `KUBECONFIG` / `~/.kube/config`. MicroK8s stores credentials under `/var/snap/microk8s/current/credentials/client.config`.

**Fix:** The launcher auto-exports that path when `~/.kube/config` is missing. You can also:

```bash
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
```

## 3. Container listens but host cannot connect

**Cause:** SGLang defaults `--host` to `127.0.0.1`. Traffic from the Service / port-forward never reaches the process.

**Fix:** This chart always passes `--host 0.0.0.0`. If you override `extraArgs` or the container command, keep that flag.

## 4. Shared memory (`/dev/shm`) too small

**Symptom:** Tensor-parallel jobs crash with bus errors or NCCL/shm failures.

**Fix:** Docker launcher uses `--shm-size 32g`. Kubernetes mounts `emptyDir` `medium: Memory` at `/dev/shm` (`shm.sizeLimit`, default `16Gi`). Raise it for multi-GPU:

```bash
helm upgrade --install sglang ./helm/sglang --set shm.sizeLimit=32Gi
```

## 5. Readiness probe never becomes Ready

SGLang can take several minutes to download weights and capture CUDA graphs.

This chart uses:

- Readiness: `GET /v1/models` with `failureThreshold: 60` (about 10 minutes after the initial delay).
- Liveness: `GET /health` with a 120s initial delay so Kubernetes does not kill a still-loading engine.

If the image pull is slow, watch:

```bash
./src/run-sglang-k8s.sh --logs
```

Wait for `The server is fired up and ready to roll!`

## 6. CUDA 13 driver mismatch

Official `lmsysorg/sglang:latest` images are CUDA 13. Older host drivers fail at container start with CUDA version errors.

Check host driver:

```bash
nvidia-smi
```

Pin an older image only if you must stay on CUDA 12, for example `lmsysorg/sglang:v0.5.19-cu129` (last CUDA 12 tag). Prefer upgrading the driver.

## 7. Hugging Face rate limits / gated models

Pass a token:

```bash
export HF_TOKEN="hf_..."
./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

The launcher creates `hf-token-secret` and the chart mounts `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN`.

## 8. hostPath cache permissions

Default cache path is `/home/johnsonhk88/.cache/huggingface`. Change it if you deploy on another node:

```bash
helm upgrade --install sglang ./helm/sglang \
  --set cache.hostPath=/path/to/.cache/huggingface
```

The directory must exist on the **GPU node** that schedules the pod.

## 9. `/metrics` missing or Grafana empty

**Symptom:** `curl http://localhost:30000/metrics` is 404, or Prometheus target `host.docker.internal:30000` is DOWN.

**Causes:**

- Docker/Helm `--enable-metrics` was turned off (`enableMetrics=false`).
- Kubernetes Service is ClusterIP and nothing is port-forwarded to localhost:30000.
- No traffic yet — counters stay at 0 until you run `./src/bench-sglang.sh`.

**Fix:**

```bash
./src/run-sglang-k8s.sh --port-forward
curl -s http://localhost:30000/metrics | grep sglang:generation_tokens_total
./src/bench-sglang.sh --model qwen-small
```

Check Prometheus targets at http://localhost:9090/targets after `docker compose -f monitoring/docker-compose.yml up -d`.

## Diagnostic cheat sheet

```bash
./src/run-sglang-k8s.sh --status
./src/run-sglang-k8s.sh --logs
kubectl describe pod -l app.kubernetes.io/name=sglang
kubectl get events --sort-by=.lastTimestamp | tail
./src/run-sglang-k8s.sh --dry-run
```
