# SGLang GPU / CPU / Memory Monitoring

Prometheus + Grafana + DCGM for capacity study. SGLang exposes `/metrics` when
`--enable-metrics` is set (Docker launcher and Helm chart do this by default).
Hardware GPU/CPU/RAM come from DCGM and node-exporter.

## Docker (local study)

Start SGLang, then the monitoring stack:

```bash
./src/run-sglang-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small --mem-fraction-static 0.2
docker compose -f monitoring/docker-compose.yml up -d
```

| Service | URL |
| --- | --- |
| Grafana (`admin` / `admin`) | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| DCGM exporter | http://localhost:9400/metrics |
| node-exporter | http://localhost:9100/metrics |

Dashboard **SGLang Capacity** is provisioned automatically
(http://localhost:3000/d/sglang-capacity). Prometheus scrapes
`host.docker.internal:30000` at `/metrics`. If SGLang is on Kubernetes
ClusterIP, run `./src/run-sglang-k8s.sh --port-forward` first or the
sglang scrape target stays DOWN.

Confirm scrape at http://localhost:9090/targets.

Generate load so the panels move:

```bash
./src/bench-sglang.sh --profile throughput --model qwen-small
```

### What the dashboard shows

| Panel | Metric | How to use it |
| --- | --- | --- |
| Requests running / waiting | `sglang:num_running_reqs`, `sglang:num_queue_reqs` | Queue growing → lower `--max-running-requests` or add copies. |
| Token throughput | `rate(sglang:prompt_tokens_total[1m])`, `rate(sglang:generation_tokens_total[1m])`, `sglang:gen_throughput` | Prompt vs generation toks/s. Quote the **rate()** series; the decode gauge is jumpy. |
| KV-cache usage | `sglang:token_usage` | Near 1.0 with rising wait → less concurrency or more GPU memory. |
| TTFT p95 | `sglang:time_to_first_token_seconds` | First-token latency under load. |
| DCGM GPU utilization | `DCGM_FI_DEV_GPU_UTIL` | GPU busy pattern over time. |
| DCGM GPU framebuffer used | `DCGM_FI_DEV_FB_USED` | VRAM in use. |
| Node CPU | `node_cpu_seconds_total` | Host CPU busy. |
| Node memory available | `node_memory_MemAvailable_bytes` | Host RAM left. |

Raw serving metrics without Grafana:

```bash
./src/bench-sglang.sh --metrics-only
curl -s http://localhost:30000/metrics | grep -E 'sglang:(gen_throughput|prompt_tokens_total|generation_tokens_total|num_running_reqs|num_queue_reqs|token_usage)'
```

Stop:

```bash
docker compose -f monitoring/docker-compose.yml down
```

## Kubernetes

This chart does **not** install Prometheus Operator or DCGM. Enable them on the
cluster, then opt in with Helm values. kube-prometheus-stack only scrapes
ServiceMonitors whose labels match `release: <helm release>` — set
`monitoring.serviceMonitor.labels` or Prometheus never sees SGLang.

```bash
helm upgrade --install sglang ./helm/sglang \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

Import [`monitoring/grafana/dashboards/sglang-capacity.json`](grafana/dashboards/sglang-capacity.json)
into cluster Grafana if it is not already provisioned.

On MicroK8s:

```bash
microk8s enable gpu
microk8s enable observability
```
