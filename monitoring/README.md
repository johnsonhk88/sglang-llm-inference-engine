# SGLang Monitoring with Prometheus and Grafana

Prometheus scrapes SGLang's `/metrics` endpoint and stores the time series.
Grafana only visualizes what Prometheus stores. DCGM and node-exporter add GPU
and host health, so a single Prometheus query layer covers serving and hardware.

```text
SGLang /metrics :30000 ─┐
DCGM exporter   :9400   ├──► Prometheus :9090 ──► Grafana :3000
node-exporter   :9100   ┘
```

| Component | Role |
| --- | --- |
| SGLang | Serves the model and exposes request, token, latency, and KV-cache metrics. |
| Prometheus | Scrapes `/metrics` every 15s, stores samples, and evaluates PromQL / alerts. |
| DCGM exporter | NVIDIA GPU utilization and framebuffer (VRAM) metrics. |
| node-exporter | Host CPU, memory, filesystem, and network metrics. |
| Grafana | Dashboards over the Prometheus data source. |

SGLang exposes metrics only when `--enable-metrics` is set. This repo's Docker
launcher and Helm chart enable it by default.

## 1. Enable metrics on SGLang

Docker launcher (already enabled):

```bash
./src/run-sglang-docker.sh --model Qwen/Qwen3-0.6B --name qwen-small --mem-fraction-static 0.2
```

Manual or non-Docker launch:

```bash
python3 -m sglang.launch_server \
  --model-path Qwen/Qwen3-0.6B \
  --host 0.0.0.0 \
  --port 30000 \
  --enable-metrics
```

`--host 0.0.0.0` is required when Prometheus runs in another container or on
another machine. SGLang's default `127.0.0.1` is reachable only from the same
host (or container network namespace).

Verify the endpoint:

```bash
curl -s http://localhost:30000/metrics | head
./src/bench-sglang.sh --metrics-only
```

Expected output contains `# HELP sglang:` lines. A 404 means the server was
launched without `--enable-metrics` (Helm: `enableMetrics=false`).

Optional MFU estimates: add `--enable-mfu-metrics` to also export
`sglang:estimated_flops_per_gpu_total` and estimated GPU read/write byte
counters.

## 2. Start Prometheus + Grafana (Docker Compose)

From the repository root:

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

| Service | URL |
| --- | --- |
| Prometheus | http://localhost:9090 |
| Grafana (`admin` / `admin`) | http://localhost:3000 |
| SGLang dashboard | http://localhost:3000/d/sglang-capacity |
| DCGM exporter | http://localhost:9400/metrics |
| node-exporter | http://localhost:9100/metrics |

Grafana is optional. If you only need the Prometheus UI and API, start just the
Prometheus service (Compose also starts its exporter dependencies):

```bash
docker compose -f monitoring/docker-compose.yml up -d prometheus
```

The scrape jobs live in [`prometheus/prometheus.yml`](prometheus/prometheus.yml):

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: sglang
    metrics_path: /metrics
    static_configs:
      - targets:
          - host.docker.internal:30000
  - job_name: dcgm
    static_configs:
      - targets: [dcgm-exporter:9400]
  - job_name: node
    static_configs:
      - targets: [node-exporter:9100]
```

`host.docker.internal` is mapped to the Docker host in
[`docker-compose.yml`](docker-compose.yml) via
`extra_hosts: host.docker.internal:host-gateway`. That lets the Prometheus
container scrape SGLang's published host port.

### Confirm Prometheus is scraping

Open http://localhost:9090/targets and check that the `sglang` target is **UP**.
Or query the Prometheus API:

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job="sglang"}'
```

A healthy target returns `"value": [<timestamp>, "1"]`. A value of `"0"` means
the scrape failed; open the target's **Last error** in the UI for the reason.

### Generate load

Counters stay flat until requests arrive:

```bash
./src/bench-sglang.sh --profile throughput --model qwen-small
```

Stop the stack with:

```bash
docker compose -f monitoring/docker-compose.yml down
```

## 3. Point Prometheus at another SGLang host or port

Edit `scrape_configs` and restart Prometheus:

```yaml
scrape_configs:
  - job_name: sglang
    metrics_path: /metrics
    scheme: http
    scrape_interval: 15s
    scrape_timeout: 10s
    static_configs:
      - targets:
          - 192.168.1.50:30000
        labels:
          env: prod
```

Multiple replicas can share one job. Prometheus adds `instance` and `job`
labels automatically:

```yaml
    static_configs:
      - targets:
          - gpu-1:30000
          - gpu-2:30000
        labels:
          env: prod
```

Apply changes to the Compose stack:

```bash
docker compose -f monitoring/docker-compose.yml restart prometheus
```

Validate the config before restarting:

```bash
docker run --rm \
  -v "$PWD/monitoring/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  check config /etc/prometheus/prometheus.yml
```

If Prometheus runs outside this Compose stack, add the same job to your own
`prometheus.yml`, then reload with `kill -HUP <prometheus-pid>` or restart the
service.

Notes:

- Test reachability from the Prometheus container, not just from your laptop.
- If SGLang is on Kubernetes `ClusterIP`, run
  `./src/run-sglang-k8s.sh --port-forward` before starting the Compose stack, or
  the `sglang` target stays DOWN.
- Do not add a target label called `model_name`; SGLang already exports it.

## 4. PromQL for day-to-day monitoring

Open http://localhost:9090, paste a query, and use the **Graph** tab. Use
`rate()` for counters. At a 15s scrape interval, `[1m]` is four samples and
`[5m]` is steadier for alerts.

### Health and traffic

| Question | PromQL |
| --- | --- |
| Is Prometheus scraping SGLang? | `up{job="sglang"}` |
| Running requests | `sum(sglang:num_running_reqs)` |
| Queued / waiting requests | `sum(sglang:num_queue_reqs)` |
| Prompt tokens/s | `sum(rate(sglang:prompt_tokens_total[1m]))` |
| Generation tokens/s | `sum(rate(sglang:generation_tokens_total[1m]))` |
| Total tokens/s | `sum(rate(sglang:prompt_tokens_total[1m])) + sum(rate(sglang:generation_tokens_total[1m]))` |
| Decode throughput gauge | `sum(sglang:gen_throughput)` |

`sglang:gen_throughput` is emitted per scheduling step and is jumpy. Quote the
`rate()` counters for capacity numbers.

### Latency and cache

| Question | PromQL |
| --- | --- |
| TTFT p50 | `histogram_quantile(0.50, sum by (le) (rate(sglang:time_to_first_token_seconds_bucket[5m])))` |
| TTFT p95 | `histogram_quantile(0.95, sum by (le) (rate(sglang:time_to_first_token_seconds_bucket[5m])))` |
| E2E latency p95 | `histogram_quantile(0.95, sum by (le) (rate(sglang:e2e_request_latency_seconds_bucket[5m])))` |
| TPOT p95 | `histogram_quantile(0.95, sum by (model_name, is_streaming, le) (rate(sglang:request_time_per_output_token_seconds_bucket[5m])))` |
| KV-cache fill | `avg(sglang:token_usage)` |
| Prefix-cache hit rate | `avg(sglang:cache_hit_rate)` |
| Tokens held in KV cache | `sum(sglang:num_used_tokens)` |

For multiple replicas, group by `instance` to see which one is unhealthy:

```promql
sum by (instance) (sglang:num_queue_reqs)
```

### GPU and host

| Question | PromQL |
| --- | --- |
| GPU utilization | `DCGM_FI_DEV_GPU_UTIL` |
| GPU VRAM used | `DCGM_FI_DEV_FB_USED * 1024 * 1024` |
| Host CPU busy | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Host memory available | `node_memory_MemAvailable_bytes` |

### Optional MFU (requires `--enable-mfu-metrics`)

Average TFLOPS per GPU:

```promql
rate(sglang:estimated_flops_per_gpu_total[1m]) / 1e12
```

Estimated memory bandwidth in GB/s:

```promql
(rate(sglang:estimated_read_bytes_per_gpu_total[1m]) +
 rate(sglang:estimated_write_bytes_per_gpu_total[1m])) / 1e9
```

These are modeled estimates, not direct hardware counters.

## 5. Metric reference

| Metric | Type | Meaning |
| --- | --- | --- |
| `sglang:prompt_tokens_total` | Counter | Prefill (input) tokens processed. |
| `sglang:generation_tokens_total` | Counter | Generation (output) tokens produced. |
| `sglang:num_running_reqs` | Gauge | Requests currently executing. |
| `sglang:num_queue_reqs` | Gauge | Requests waiting in the scheduler queue. |
| `sglang:token_usage` | Gauge | KV-cache fill ratio, 0 to 1. |
| `sglang:num_used_tokens` | Gauge | Tokens currently held in KV cache. |
| `sglang:cache_hit_rate` | Gauge | Prefix-cache hit rate. |
| `sglang:gen_throughput` | Gauge | Instantaneous decode tokens/s. |
| `sglang:time_to_first_token_seconds` | Histogram | Time from request creation to first token. |
| `sglang:e2e_request_latency_seconds` | Histogram | End-to-end request latency. |
| `sglang:request_time_per_output_token_seconds` | Histogram | Per-request TPOT, split by `is_streaming`. |
| `sglang:estimated_flops_per_gpu_total` | Counter | Estimated FLOPs per GPU (MFU metrics enabled). |
| `sglang:estimated_read_bytes_per_gpu_total` | Counter | Estimated GPU read bytes (MFU metrics enabled). |
| `sglang:estimated_write_bytes_per_gpu_total` | Counter | Estimated GPU write bytes (MFU metrics enabled). |

Most serving series carry a `model_name` label. Some SGLang versions add rank
labels such as `tp_rank` and `pp_rank`. Metric names can change between
releases; after an upgrade, compare the dashboard against
`curl -s http://localhost:30000/metrics`.

Full reference:
[SGLang Production Metrics](https://docs.sglang.ai/references/production_metrics.html).

## 6. Alerting

Prometheus evaluates alert rules independently of Grafana. Save this as
`alerts.yml`, mount it into the Prometheus container, and add it to
`prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/alerts.yml
```

Mount the file into the Prometheus container. In `docker-compose.yml` that means
adding a volume next to the existing config mount:

```yaml
volumes:
  - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
  - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
```

Example rules (tune thresholds for your model and traffic):

```yaml
groups:
  - name: sglang
    rules:
      - alert: SGLangTargetDown
        expr: up{job="sglang"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "SGLang metrics endpoint is down"
          description: "{{ $labels.instance }} has been unreachable for 2 minutes."

      - alert: SGLangQueueBacklog
        expr: sum(sglang:num_queue_reqs) > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "SGLang request queue is backing up"
          description: "Queue depth is {{ $value }}. Lower concurrency or add replicas."

      - alert: SGLangTTFTP95High
        expr: histogram_quantile(0.95, sum by (le) (rate(sglang:time_to_first_token_seconds_bucket[5m]))) > 2
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "SGLang p95 TTFT is above 2s"
          description: "p95 TTFT is {{ $value | humanize }}s."

      - alert: SGLangKVCacheSaturated
        expr: avg(sglang:token_usage) > 0.9 and sum(sglang:num_queue_reqs) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "SGLang KV cache is saturated with requests waiting"
          description: "KV-cache fill is {{ $value | humanizePercentage }}."
```

After changing rules, restart or reload Prometheus. Check rule state at
http://localhost:9090/rules and firing alerts at
http://localhost:9090/alerts. Prometheus only evaluates rules; connect
Alertmanager if you want notifications in Slack, email, or PagerDuty.

## 7. Grafana dashboard

The **SGLang Capacity** dashboard is provisioned automatically
(http://localhost:3000/d/sglang-capacity). Panels:

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

## 8. Kubernetes

This chart does **not** install Prometheus Operator or DCGM. Install
kube-prometheus-stack (or enable MicroK8s observability), then opt in with Helm
values. kube-prometheus-stack only scrapes ServiceMonitors whose labels match
`release: <helm release>` — set `monitoring.serviceMonitor.labels` or Prometheus
never sees SGLang.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

```bash
helm upgrade --install sglang ./helm/sglang \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.labels.release=kube-prometheus-stack
```

Verify the ServiceMonitor exists and Prometheus discovered it:

```bash
kubectl get servicemonitor -l app.kubernetes.io/name=sglang
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/targets and search for sglang
```

If no target appears:

- `monitoring.serviceMonitor.labels.release` must equal the Helm release name of
  kube-prometheus-stack (`kube-prometheus-stack` above).
- The ServiceMonitor must be in a namespace watched by the Prometheus CR
  (`serviceMonitorNamespaceSelector`).
- The endpoint `port` must match the Service port name. The chart uses `http`.
- The SGLang pod must have been started with `--enable-metrics`.

The chart also supports a raw-manifest workflow. `k8s/sglang.yaml` exposes
`--enable-metrics` but does not create a ServiceMonitor. Add one manually:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sglang
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: sglang
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

If Prometheus is in-cluster but not managed by the Operator, scrape the Service
DNS name directly:

```yaml
scrape_configs:
  - job_name: sglang
    metrics_path: /metrics
    static_configs:
      - targets:
          - sglang-service.default.svc.cluster.local:30000
```

On MicroK8s:

```bash
microk8s enable gpu
microk8s enable observability
```

Import [`grafana/dashboards/sglang-capacity.json`](grafana/dashboards/sglang-capacity.json)
into cluster Grafana if it is not already provisioned.

## 9. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `/metrics` returns 404 | SGLang started without `--enable-metrics` (`enableMetrics=false` in Helm). |
| Prometheus target DOWN, `connection refused` | Nothing is listening on the target host/port, or SGLang was stopped. |
| Prometheus target DOWN, `context deadline exceeded` | Firewall, wrong host/port, DNS failure, or SGLang bound to `127.0.0.1`. |
| Target `host.docker.internal:30000` DOWN | SGLang is on Kubernetes `ClusterIP` with no port-forward, or the Compose stack was not used (so `host.docker.internal` is unresolved). |
| Grafana panels empty but Prometheus works | Datasource should be `http://prometheus:9090`; check metric names in `/metrics` after an SGLang upgrade. |
| ServiceMonitor is ignored | Its labels must match the Prometheus `serviceMonitorSelector`; its namespace must match `serviceMonitorNamespaceSelector`. |
| Counters stay at 0 | No requests yet — run `./src/bench-sglang.sh`. |
| Port 9090 or 3000 already allocated | Stop the conflicting service or change the host port in `docker-compose.yml`. |

Prometheus scrapes SGLang from inside its own container. A target that works
from your laptop with `curl` can still be DOWN in Prometheus; test from the
Prometheus container when debugging:

```bash
docker compose -f monitoring/docker-compose.yml exec prometheus \
  wget -qO- http://host.docker.internal:30000/metrics | head
```

## Production notes

- The Prometheus UI/API has no authentication or TLS by default. Keep port 9090
  on a private network or put it behind a reverse proxy.
- 15s scraping is a good default. Raise `scrape_timeout` if the metrics endpoint
  is slow under load.
- Set retention explicitly for long-running deployments:
  `--storage.tsdb.retention.time=30d`. Use `remote_write` if you need long-term
  storage or HA.
- Alert on symptoms operators can act on: target down, queue growth, TTFT, and
  KV-cache saturation. Avoid alerting on the jumpy `sglang:gen_throughput`
  gauge.
