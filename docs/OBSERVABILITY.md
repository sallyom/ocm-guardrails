# Observability with OpenTelemetry and MLflow

This guide documents the production observability setup for OpenClaw and Moltbook using OpenTelemetry collector sidecars and MLflow Tracking.

## Architecture Overview

The observability stack uses **sidecar-based OTEL collectors** that send traces directly to MLflow:

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod: openclaw-xxxxxxxxx-xxxxx (openclaw namespace)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────────────────┐ │
│  │  Gateway         │  OTLP   │  OTEL Collector Sidecar      │ │
│  │  Container       │──────▶  │  (auto-injected)             │ │
│  │                  │  :4318  │                              │ │
│  │  diagnostics-    │         │  - Batches traces            │ │
│  │  otel plugin     │         │  - Adds metadata             │ │
│  └──────────────────┘         │  - Exports to MLflow         │ │
│                               └──────────────────────────────┘ │
│                                         │                       │
└─────────────────────────────────────────┼───────────────────────┘
                                          │
                                          ▼ OTLP/HTTP (HTTPS)
┌─────────────────────────────────────────────────────────────────┐
│ MLflow Tracking Server (demo-mlflow-agent-tracing namespace)    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Route: mlflow-route-mlflow.apps.CLUSTER_DOMAIN                │
│  Endpoint: /v1/traces (OTLP standard path)                     │
│                                                                 │
│  Features:                                                      │
│  ✅ Trace ingestion via OTLP                                    │
│  ✅ Automatic span→trace conversion                             │
│  ✅ LLM-specific trace metadata                                 │
│  ✅ Request/Response column population                          │
│  ✅ Session grouping for multi-turn conversations               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

The same pattern applies to Moltbook pods in the `moltbook` namespace.

## Why Sidecars?

### Benefits

1. **Zero application changes**: Apps send to `localhost:4318` - no network complexity
2. **Automatic injection**: OpenTelemetry Operator injects sidecars based on pod annotations
3. **Resource isolation**: Each pod has its own collector with dedicated resources
4. **Batch optimization**: Sidecars batch traces before sending to reduce network overhead
5. **Metadata enrichment**: Add namespace, environment, and MLflow-specific attributes
6. **Direct to MLflow**: No intermediate collectors - simpler architecture

### How It Works

1. **Pod annotation** triggers sidecar injection:

2. **OpenTelemetry Operator** sees the annotation and injects a sidecar container

3. **Application** sends OTLP traces to `http://localhost:4318/v1/traces`

4. **Sidecar** receives, processes, and forwards to MLflow

## Components

### 1. OpenClaw Gateway (openclaw namespace)

**Built-in OTLP instrumentation** via `extensions/diagnostics-otel`:

- **Span creation**: Root spans for each message.process event
- **Nested tool spans**: Tool usage creates child spans under the root
- **LLM metadata**: Captures model, provider, usage, cost
- **MLflow-specific attributes**:
  - `mlflow.spanInputs` (OpenAI chat message format: `{"role":"user","content":"..."}`)
  - `mlflow.spanOutputs` (OpenAI chat message format: `{"role":"assistant","content":"..."}`)
  - `mlflow.trace.session` (for multi-turn conversation grouping)
  - `gen_ai.prompt` and `gen_ai.completion` (raw text)

**Configuration** (in `openclaw.json`):
```json
{
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "endpoint": "http://localhost:4318",
      "traces": true,
      "metrics": true,
      "logs": false
    }
  }
}
```

### 2. OTEL Collector Sidecar (openclaw namespace)

**Auto-injected** by OpenTelemetry Operator based on pod annotation.

**Configuration** (`observability/openclaw-otel-sidecar.yaml`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: openclaw-sidecar
  namespace: openclaw
spec:
  mode: sidecar

  config: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 127.0.0.1:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 100

      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64

      resource:
        attributes:
          - key: service.namespace
            value: openclaw
            action: upsert
          - key: deployment.environment
            value: production
            action: upsert

    exporters:
      otlphttp:
        endpoint: https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "openclaw"
        tls:
          insecure: false

      debug:
        verbosity: detailed

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [otlphttp, debug]
```

**Key points**:
- Listens on `localhost:4318` (only accessible within pod)
- Batches traces for efficiency
- Adds namespace and environment metadata
- Sends to MLflow OTLP endpoint (path `/v1/traces` auto-appended)
- Custom headers for MLflow experiment/workspace routing

### 3. Moltbook API (moltbook namespace)

**Same sidecar pattern** as OpenClaw.

**Configuration** (`observability/moltbook-otel-sidecar.yaml`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: moltbook-sidecar
  namespace: moltbook
spec:
  mode: sidecar

  config: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 127.0.0.1:4318

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1024

      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64

      probabilistic_sampler:
        sampling_percentage: 10.0  # Sample 10% of traces

      resource:
        attributes:
          - key: service.namespace
            value: moltbook
            action: upsert
          - key: mlflow.experimentName
            value: OpenClaw
            action: upsert

    exporters:
      otlphttp:
        endpoint: https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "moltbook"
        tls:
          insecure: false

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, probabilistic_sampler, resource, batch]
          exporters: [otlphttp, debug]
```

**Differences from OpenClaw**:
- **10% sampling** (probabilistic_sampler) to reduce trace volume
- Larger batch size (1024 vs 100)
- Different MLflow workspace header

### 4. MLflow Tracking Server

**OTLP Ingestion**:
- Endpoint: `https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN/v1/traces`
- Accepts OTLP traces via HTTP/Protobuf
- Automatically converts spans to MLflow traces

**MLflow UI Features**:
- **Traces tab**: Browse all traces with filters
- **Request/Response columns**: Populated from `mlflow.spanInputs`/`mlflow.spanOutputs` on ROOT span
- **Session column**: Groups multi-turn conversations via `mlflow.trace.session` attribute
- **Nested span hierarchy**: Tools appear as children under LLM spans
- **Metadata**: Model, provider, usage, cost, duration

**Known Limitations**:
- User/Prompt columns don't populate from OTLP (MLflow UI limitation)
- Trace-level attributes must be on ROOT span, not child spans
- Must use OpenAI chat message format for Input/Output: `{"role":"user","content":"..."}`

## Deployment

### Prerequisites

1. **OpenTelemetry Operator** installed in cluster

2. **MLflow** with OTLP endpoint accessible

3. **Network connectivity** from openclaw/moltbook namespaces to MLflow route

### Deploy OTEL Collector Sidecars

```bash
# Deploy OpenClaw sidecar configuration
oc apply -f observability/openclaw-otel-sidecar.yaml

# Deploy Moltbook sidecar configuration
oc apply -f observability/moltbook-otel-sidecar.yaml
```

### Update Application Deployments

Add sidecar injection annotation to pod templates:

**OpenClaw** (`manifests/openclaw/base/openclaw-deployment.yaml`):
```yaml
spec:
  template:
    metadata:
      annotations:
        sidecar.opentelemetry.io/inject: "openclaw-sidecar"
```

**Moltbook** (deployment manifest):
```yaml
spec:
  template:
    metadata:
      annotations:
        sidecar.opentelemetry.io/inject: "moltbook-sidecar"
```

### Update Cluster-Specific Values

Replace `CLUSTER_DOMAIN` with your actual cluster domain:
```yaml
exporters:
  otlphttp:
    endpoint: https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN
```

### Verify Traces in MLflow

1. Access MLflow UI: `https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN`
2. Navigate to **Traces** tab
3. Filter by workspace: `openclaw` or `moltbook`
4. Click a trace to see:
   - Request/Response columns populated
   - Nested span hierarchy (message.process → llm → tool spans)
   - Metadata (model, usage, cost)

## Configuration Reference

### Sidecar Resource Limits

**Recommended values**:
```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 256Mi
    cpu: 200m
```

Increase if experiencing OOM or CPU throttling.

### Batch Processing

**Balance latency vs throughput**:
```yaml
batch:
  timeout: 5s          # Max time to wait before sending batch
  send_batch_size: 100 # Max traces per batch
```

- Lower timeout = lower latency, more network overhead
- Higher batch size = better throughput, higher memory usage

### Sampling

**Reduce trace volume** (Moltbook example):
```yaml
probabilistic_sampler:
  sampling_percentage: 10.0  # Sample 10% of traces
```

Useful for high-traffic services.

### MLflow Headers

**Route traces to experiments/workspaces**:
```yaml
headers:
  x-mlflow-experiment-id: "4"      # MLflow experiment ID
  x-mlflow-workspace: "openclaw"   # Arbitrary workspace tag
```

## Best Practices

1. **Use sidecars for applications**: Simplest pattern, no network complexity
2. **Batch aggressively**: Reduces network overhead and MLflow ingestion load
3. **Sample high-volume services**: Use probabilistic sampling for high-traffic APIs
4. **Monitor sidecar health**: Set up alerts for OOM or high CPU
5. **Set MLflow attributes on ROOT span**: Only root span attributes become trace-level metadata
6. **Use OpenAI chat format**: MLflow expects `{"role":"user","content":"..."}` for Input/Output columns
7. **Handle tool phases correctly**: Agent emits `phase="result"` not `"end"`

## Context Propagation (Distributed Tracing)

OpenClaw now supports **W3C Trace Context** propagation to downstream services, enabling end-to-end distributed tracing across:
- **OpenClaw → vLLM**: See LLM inference as nested spans under agent traces
- **OpenClaw → Moltbook**: See API calls as nested spans (when Moltbook has OTLP instrumentation)
- **OpenClaw → Any OTLP-instrumented service**: Full request path visibility

### How It Works

When OpenClaw makes an HTTP request to an LLM provider (like vLLM):

1. **OpenClaw** gets the active OpenTelemetry span context
2. **Trace context injector** formats W3C `traceparent` header:
   ```
   traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
   ```
3. **HTTP request** includes the header
4. **vLLM** (or other service) extracts the header and creates child spans
5. **MLflow** displays the full nested trace hierarchy

### vLLM Configuration

vLLM has built-in OpenTelemetry support. To enable trace context extraction:

**Environment variables** (vLLM deployment):
```yaml
            env:
            - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
              value: 'https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN/v1/traces'
            - name: OTEL_EXPORTER_OTLP_TRACES_HEADERS
              value: x-mlflow-experiment-id=2
            - name: OTEL_SERVICE_NAME
              value: vllm-gpt-oss-20b
            - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
              value: http/protobuf
```

**vLLM startup** (if using direct MLflow export):
```bash
            args:
            - |
              pip install 'opentelemetry-sdk>=1.26.0,<1.27.0' \
                'opentelemetry-api>=1.26.0,<1.27.0' \
                'opentelemetry-exporter-otlp>=1.26.0,<1.27.0' \
                'opentelemetry-semantic-conventions-ai>=0.4.1,<0.5.0' && \
              vllm serve openai/gpt-oss-20b \
                --tool-call-parser openai \
                --enable-auto-tool-choice \
                --otlp-traces-endpoint https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN/v1/traces \
                --collect-detailed-traces all
```

### Nested Trace Example

**Before context propagation** (separate traces):
```
Trace 1 (OpenClaw):
└─ message.process (root)
   └─ llm (child)
   └─ tool.exec (child)

Trace 2 (vLLM) - SEPARATE:
└─ /v1/chat/completions (root)
   └─ model.forward (child)
```

**After context propagation** (nested):
```
Trace 1 (OpenClaw):
└─ message.process (root)
   └─ llm (child)
      └─ /v1/chat/completions (NESTED - from vLLM)
         └─ model.forward (child)
         └─ tokenization (child)
   └─ tool.exec (child)
```

## Related Documentation

- [OpenClaw Diagnostics Plugin](../extensions/diagnostics-otel/)
- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [MLflow Tracing](https://mlflow.org/docs/latest/llms/tracing/index.html)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
