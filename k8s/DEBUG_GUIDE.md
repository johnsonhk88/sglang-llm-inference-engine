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

## 9. `/metrics` missing or Prometheus target DOWN

**Symptom:** `curl http://localhost:30000/metrics` is 404, or the Prometheus target `host.docker.internal:30000` / `sglang` is DOWN.

**Causes and fixes:**

1. **SGLang started without metrics.** Docker and Helm enable `--enable-metrics` by default; check for `enableMetrics=false` or a custom `extraArgs` override.

   ```bash
   curl -s http://localhost:30000/metrics | head
   ```

   Expect `# HELP sglang:` lines. A 404 means the flag is missing.

2. **ClusterIP with no local forward.** Port-forward the Service, then retry:

   ```bash
   ./src/run-sglang-k8s.sh --port-forward
   curl -s http://localhost:30000/metrics | grep sglang:generation_tokens_total
   ```

3. **Wrong target host or port.** For the Docker Compose stack the target is `host.docker.internal:30000`. Check http://localhost:9090/targets and the target's **Last error**. `connection refused` means nothing is listening; `context deadline exceeded` points to a network, DNS, or firewall problem.

4. **ServiceMonitor not discovered.** Check that it exists and that its labels match the Prometheus `serviceMonitorSelector`:

   ```bash
   kubectl get servicemonitor -A
   kubectl get prometheus -A -o yaml | grep -A10 serviceMonitorSelector
   ```

   Also confirm the endpoint `port: http` matches the Service port name.

5. **No traffic yet.** Counters stay at 0 until requests arrive:

   ```bash
   ./src/bench-sglang.sh --model qwen-small
   ```

Query `up{job=~".*sglang.*"}` in Prometheus. `1` is healthy; `0` means Prometheus is running but the scrape failed.

If the target is a Kubernetes Service, test in-cluster reachability with a debug pod (adjust the Service name and namespace):

```bash
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://sglang-service.default.svc.cluster.local:30000/metrics | head
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
