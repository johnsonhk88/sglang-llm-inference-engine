# How to Use Kubernetes SGLang for LLM Serving

This guide explains how to use the Kubernetes deployment (`helm/sglang/` and `src/run-sglang-k8s.sh`) to serve LLMs, send inference requests, and perform day-to-day operations.

---

## 1. Quick Overview

Once deployed, SGLang on Kubernetes behaves like an OpenAI-compatible API server running inside the cluster:

| Property | Default |
| --- | --- |
| **Service Name** | `sglang` (Helm) / `sglang-service` (raw manifest) |
| **Port** | `30000` |
| **Default Model** | `Qwen/Qwen3-0.6B` |
| **Default Model Alias** | `qwen-small` |
| **Primary Endpoints** | `/health`, `/v1/models`, `/v1/chat/completions`, `/metrics` |

---

## 2. Deploying a Model

From the repository root:

```bash
./src/run-sglang-k8s.sh --model Qwen/Qwen3-0.6B --name qwen-small
```

Larger model:

```bash
./src/run-sglang-k8s.sh --model Qwen/Qwen3-4B-Instruct-2507 --name qwen-4b --mem-fraction 0.8
```

### Monitoring Startup

```bash
./src/run-sglang-k8s.sh --status
./src/run-sglang-k8s.sh --logs
```

---

## 3. Client Access Methods

The serving engine uses `ClusterIP` by default.

### Method A: Local Port-Forward (Same Host / Laptop)

```bash
./src/run-sglang-k8s.sh --port-forward
```

API base:

```text
http://localhost:30000/v1
```

### Method B: NodePort (LAN / Remote Clients)

```bash
./src/run-sglang-k8s.sh \
  --model Qwen/Qwen3-0.6B \
  --name qwen-small \
  --service-type NodePort \
  --nodeport 30300
```

Clients connect to:

```text
http://<node-ip>:30300/v1
```

### Method C: In-Cluster Access (Other Pods / Services)

```text
http://sglang.default.svc.cluster.local:30000/v1
```

---

## 4. Client Request Examples

### curl (Chat Completions)

```bash
curl -X POST "http://localhost:30000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-small",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "max_tokens": 128
  }'
```

### Python (`requests`)

```python
import requests

response = requests.post(
    "http://localhost:30000/v1/chat/completions",
    json={
        "model": "qwen-small",
        "messages": [
            {"role": "system", "content": "You are a helpful coding assistant."},
            {"role": "user", "content": "Write a Python function to check for prime numbers."}
        ],
        "temperature": 0.2,
    },
)

print(response.json()["choices"][0]["message"]["content"])
```

### Python (`litellm`)

```python
import litellm

response = litellm.completion(
    model="openai/qwen-small",
    api_base="http://localhost:30000/v1",
    api_key="none",
    messages=[
        {"role": "user", "content": "Explain Kubernetes pods in two sentences."}
    ],
)

print(response.choices[0].message.content)
```

> **Note on Model Name:** Always pass the `--name` value (`qwen-small`), not the full Hugging Face ID (`Qwen/Qwen3-0.6B`), in the `"model"` field of API requests.

---

## 5. Daily Operations & Management

### Check Serving Health

```bash
./src/test-k8s.sh --skip-deploy --python

curl -s http://localhost:30000/health
curl -s http://localhost:30000/v1/models | jq .
```

### Tokens/s and live metrics

Keep port-forward running (`./src/run-sglang-k8s.sh --port-forward`), then:

```bash
./src/bench-sglang.sh --profile throughput --model qwen-small
./src/bench-sglang.sh --metrics-only
curl -s http://localhost:30000/metrics | grep sglang:gen_throughput
```

The Docker Compose Grafana stack scrapes host port `30000` through `host.docker.internal:30000`. Bring it up from the repository root and confirm `sglang` is UP at http://localhost:9090/targets:

```bash
docker compose -f monitoring/docker-compose.yml up -d
```

For an in-cluster Prometheus, port-forward its Service and query the same PromQL:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090 and run: up{job=~".*sglang.*"}
```

How to read the panels and write PromQL: [`monitoring/README.md`](../monitoring/README.md).

### Stop Serving Engine / Clean Up

```bash
./src/run-sglang-k8s.sh --delete
```

### Troubleshooting

If the pod encounters issues, see **[`k8s/DEBUG_GUIDE.md`](DEBUG_GUIDE.md)**.
