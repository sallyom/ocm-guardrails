# CLAUDE.md - Guide for AI Assistants

> **Context and instructions for AI assistants working with this repository.**

## What This Repo Is

A reproducible demo of **AI agents running across hybrid platforms** — OpenShift, vanilla Kubernetes, and bare-metal Linux — connected via zero-trust [Google A2A](https://github.com/google/A2A) protocol powered by [Kagenti](https://github.com/kagenti/kagenti) (SPIFFE/SPIRE + Keycloak).

[OpenClaw](https://github.com/openclaw) is used as the agent runtime, but the network architecture (A2A, identity, observability) is designed to stand on its own and work with any agent framework.

### Deployment Targets

| Platform | Setup | What It Does |
|----------|-------|-------------|
| **OpenShift** | `./scripts/setup.sh` | Central gateway with agents, OAuth, routes, OTEL sidecar |
| **Kubernetes** | `./scripts/setup.sh --k8s` | Same as OpenShift minus OAuth/routes (KinD, minikube, etc.) |
| **Edge (RHEL/Fedora)** | `edge/scripts/setup-edge.sh` | Rootless Podman Quadlet, systemd --user, SELinux enforcing |

### The Network Vision

```
                    ┌──── OpenShift Cluster ────┐
                    │  Central Gateway          │
                    │  ├── Supervisor agents     │
                    │  ├── MLflow (traces)       │
                    │  ├── SPIRE Server          │
                    │  └── Keycloak              │
                    └────────┬──────────────────┘
                             │
                    A2A (SPIFFE mTLS, zero-trust)
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
    ┌─────┴─────┐    ┌──────┴─────┐    ┌───────┴────┐
    │ RHEL NUC  │    │ RHEL VM    │    │ K8s cluster │
    │ Quadlet   │    │ Quadlet    │    │ namespace   │
    │ agent     │    │ agent      │    │ agent       │
    └───────────┘    └────────────┘    └────────────┘
```

**Phased rollout:**
- Phase 1 (current): Edge agents with SSH-based lifecycle control from central gateway
- Phase 2: Multi-machine fleet coordination via supervisor agents
- Phase 3: Full zero-trust A2A via Kagenti SPIRE/SPIFFE across all platforms

## Getting Started

### OpenShift / Kubernetes

```bash
./scripts/setup.sh                    # OpenShift (interactive)
./scripts/setup.sh --k8s              # Vanilla Kubernetes
```

`setup.sh` prompts for namespace prefix, agent name, API keys, and optional Vertex AI / A2A config. It generates secrets into `.env` (git-ignored), runs `envsubst` on templates, and deploys via kustomize.

### Edge (RHEL / Fedora)

```bash
cd edge
./scripts/setup-edge.sh               # Interactive setup on the Linux machine
```

Installs `.kube` Quadlet files with Pod YAML, ConfigMaps, and a credentials ConfigMap into `~/.config/containers/systemd/`. Agent stays stopped until explicitly started (central supervisor controls lifecycle via SSH).

### Local Testing with KinD

```bash
./scripts/create-cluster.sh           # Creates a KinD cluster
./scripts/setup.sh --k8s              # Deploy OpenClaw to it
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
```

### Additional Agents

```bash
./scripts/setup-agents.sh             # OpenShift
./scripts/setup-agents.sh --k8s       # Kubernetes
```

### Other Scripts

| Script | Purpose |
|--------|---------|
| `./scripts/export-config.sh` | Export live `openclaw.json` from running pod |
| `./scripts/update-jobs.sh` | Update cron jobs without full re-deploy |
| `./scripts/teardown.sh` | Remove namespace, resources, PVCs |
| `./scripts/setup-nps-agent.sh` | Deploy NPS Agent (separate namespace) |
| `./scripts/build-and-push.sh` | Build images with podman (optional) |

All scripts accept `--k8s` for vanilla Kubernetes.

## Repository Structure

```
openclaw-infra/
├── scripts/                    # Deployment and management scripts
├── .env                        # Generated secrets (GIT-IGNORED)
├── manifests/
│   └── openclaw/
│       ├── base/               # Core: deployment, service, PVCs, quotas, A2A resources
│       ├── base-k8s/           # K8s-specific patches (strips OpenShift resources)
│       ├── patches/            # Optional patches (strip-a2a.yaml)
│       ├── overlays/
│       │   ├── openshift/      # OpenShift overlay (secrets, config, OAuth, routes)
│       │   └── k8s/            # Vanilla Kubernetes overlay
│       ├── agents/             # Agent configs, RBAC, cron jobs
│       ├── skills/             # Agent skills (NPS, A2A)
│       └── llm/                # vLLM reference deployment (GPU model server)
├── manifests/nps-agent/        # NPS Agent (separate namespace)
├── edge/
│   ├── quadlet/                # .kube Quadlet files + Pod/ConfigMap YAML templates
│   ├── config/                 # openclaw.json, OTEL, AGENTS.md templates
│   └── scripts/                # setup-edge.sh
├── observability/              # OTEL sidecar and collector templates
└── docs/                       # Architecture and reference docs
```

## Key Design Decisions

### envsubst Template System

- `.envsubst` files contain `${VAR}` placeholders and are committed to Git
- `.env` contains real secrets and is git-ignored
- Setup scripts run `envsubst` with explicit variable lists to protect non-env placeholders like `{agentId}`
- Generated `.yaml` files are git-ignored

### Config Lifecycle (K8s and Edge)

```
.envsubst template    -->    ConfigMap    -->    PVC (live config)
(source of truth)          (K8s object         /home/node/.openclaw/openclaw.json
                           or YAML file)       init container copies
                                               on EVERY start
```

- The init container copies `openclaw.json`, `AGENTS.md`, and `agent.json` from ConfigMap mounts into the PVC on every start
- UI changes write to PVC only — they are lost on next restart
- Use `./scripts/export-config.sh` to capture live config before it gets overwritten

### Per-User Namespaces (K8s)

Each user gets `<prefix>-openclaw`. The `${OPENCLAW_PREFIX}` variable is used throughout templates. Agent IDs follow the pattern `<prefix>_<agent_name>`.

### Edge Security Posture

- Rootless Podman (no root anywhere)
- SELinux: Enforcing
- Tool exec allowlist — agents can only run read-only system commands
- API keys automatically sanitized from child processes
- Loopback-only gateway (default)
- `Restart=no` — agent can't self-activate, only central supervisor via SSH

### K8s vs OpenShift

The `base/` directory contains all resources including A2A. Overlays and patches strip what's not needed:
- `base-k8s/` strips OpenShift-specific resources (Route, OAuthClient, SCC, oauth-proxy)
- `base-k8s/` sets `fsGroup: 1000` and `runAsUser/runAsGroup: 1000` on init-config for correct PVC ownership
- `patches/strip-a2a.yaml` removes A2A containers/volumes (applied by default unless `--with-a2a`)

### Agent Registration Ordering

In `setup-agents.sh`, ConfigMaps are applied AFTER the kustomize config patch. The base kustomization includes a default `shadowman-agent` ConfigMap that would overwrite custom agent ConfigMaps if applied later.

## A2A (Zero-Trust Agent Communication)

Cross-namespace and cross-platform agent communication using [Google A2A](https://github.com/google/A2A) protocol with [Kagenti](https://github.com/kagenti/kagenti) for zero-trust identity. **Requires SPIRE + Keycloak infrastructure on the cluster.**

```bash
./scripts/setup.sh --with-a2a              # OpenShift
./scripts/setup.sh --k8s --with-a2a        # Kubernetes
```

When A2A is enabled:
- 5 additional sidecar containers: a2a-bridge, proxy-init, spiffe-helper, client-registration, envoy-proxy
- AuthBridge exchanges SPIFFE workload identities for OAuth tokens via Keycloak
- Custom SCC applied (OpenShift) for AuthBridge capabilities (NET_ADMIN, NET_RAW)
- A2A skill installed into agent workspaces

When A2A is disabled (default):
- `strip-a2a.yaml` removes all A2A containers/volumes via kustomize strategic merge patches
- Default deployment has 2 containers: gateway + init-config (OpenShift adds oauth-proxy)

## Observability

All platforms emit OTLP traces to MLflow:
- **OpenShift/K8s**: OTEL sidecar collector forwards to central MLflow
- **Edge**: Local OTEL collector Quadlet forwards to MLflow route on OpenShift
- `diagnostics.otel.captureContent: true` required in config for trace inputs/outputs to appear in MLflow

## Pre-Built Agents

| Agent | ID Pattern | Description | Schedule |
|-------|-----------|-------------|----------|
| Default | `<prefix>_<custom_name>` | Interactive agent (customizable name) | On-demand |
| Resource Optimizer | `<prefix>_resource_optimizer` | K8s resource analysis | Every 8 hours |
| MLOps Monitor | `<prefix>_mlops_monitor` | NPS Agent monitoring via MLflow | Every 6 hours |

## Environment Variables (.env)

| Variable | Source | Purpose |
|----------|--------|---------|
| `OPENCLAW_PREFIX` | User prompt | Namespace name, agent ID prefix |
| `OPENCLAW_NAMESPACE` | Derived: `<prefix>-openclaw` | All K8s resources |
| `OPENCLAW_GATEWAY_TOKEN` | Auto-generated | Gateway auth |
| `CLUSTER_DOMAIN` | Auto-detected (OpenShift) or empty | Routes, OAuth redirects |
| `ANTHROPIC_API_KEY` | User prompt (optional) | Agents using Claude |
| `MODEL_ENDPOINT` | User prompt or default | In-cluster model provider URL |
| `VERTEX_ENABLED` | User prompt (default: `false`) | Google Vertex AI |
| `VERTEX_PROVIDER` | User prompt (default: `google`) | `google` for Gemini, `anthropic` for Claude via Vertex |
| `GOOGLE_CLOUD_PROJECT` | User prompt (if Vertex) | GCP project ID |
| `A2A_ENABLED` | `--with-a2a` flag (default: `false`) | A2A communication |
| `KEYCLOAK_URL` | User prompt (if A2A) | Keycloak server URL |
| `KEYCLOAK_REALM` | User prompt (if A2A) | Keycloak realm name |
| `SHADOWMAN_CUSTOM_NAME` | User prompt in setup-agents.sh | Default agent ID |
| `SHADOWMAN_DISPLAY_NAME` | User prompt in setup-agents.sh | Default agent display name |
| `DEFAULT_AGENT_MODEL` | Derived from API key availability | Model ID for agents |

## Critical Files

| File | Purpose |
|------|---------|
| `manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst` | Main gateway config (models, agents, tools) |
| `manifests/openclaw/overlays/k8s/config-patch.yaml.envsubst` | K8s gateway config |
| `manifests/openclaw/agents/agents-config-patch.yaml.envsubst` | Agent list overlay |
| `manifests/openclaw/base/openclaw-deployment.yaml` | Gateway deployment with init container |
| `manifests/openclaw/base-k8s/deployment-k8s-patch.yaml` | K8s deployment patch |
| `manifests/openclaw/patches/strip-a2a.yaml` | Removes A2A containers/volumes |
| `edge/quadlet/openclaw-agent.kube` | Edge agent Quadlet unit |
| `edge/quadlet/openclaw-agent-pod.yaml.envsubst` | Edge Pod YAML template |
| `edge/scripts/setup-edge.sh` | Edge deployment script |
| `scripts/setup.sh` | Main K8s/OpenShift deployment script |
| `scripts/setup-agents.sh` | Agent deployment script |
| `docs/FLEET.md` | Fleet management architecture |
| `docs/A2A-ARCHITECTURE.md` | Zero-trust A2A architecture |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| EACCES on `/home/node/.openclaw/canvas` | PVC owned by wrong UID | Delete PVC, redeploy (K8s patch sets fsGroup: 1000) |
| Config changes lost after restart | Init container overwrites from ConfigMap | Export with `export-config.sh` first |
| OAuthClient 500 "unauthorized_client" | `oc apply` corrupted secret state | Delete and recreate OAuthClient |
| Agent shows wrong name | Init overwrote workspace or browser cache | Re-run `setup-agents.sh`; clear localStorage |
| Kustomize overwrites agent ConfigMap | Base includes default shadowman-agent | `setup-agents.sh` applies ConfigMaps after kustomize |
| Missing trace inputs/outputs in MLflow | `captureContent` not set | Add `diagnostics.otel.captureContent: true` to config |
| Edge agent won't start (Secret error) | podman doesn't support Secret in `--configmap` | Use ConfigMap kind (setup-edge.sh handles this) |
