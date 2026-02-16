# openclaw-k8s

Deploy OpenClaw — an AI agent runtime platform — on OpenShift or vanilla Kubernetes. Each team member gets their own isolated namespace with uniquely prefixed agents.

## What This Deploys

```
┌──────────────────────────────────────────────────┐
│ OpenClaw Gateway (<prefix>-openclaw namespace)   │
│ - AI agent runtime with per-agent workspaces     │
│ - Control UI + WebChat                           │
│ - 2 pre-built agents (customizable names)        │
│ - Cron jobs for scheduled agent tasks            │
│ - Full OpenTelemetry observability               │
└──────────────────────────────────────────────────┘
```

## Quick Start

> **Tip:** This repo is designed to be AI-navigable. Point an AI coding assistant (Claude Code, Codex, etc.) at this directory and ask it to help you deploy, troubleshoot, or customize your setup.

### Prerequisites

**OpenShift (default):**
- `oc` CLI installed and logged in (`oc login`)
- Cluster-admin access (for OAuthClient creation)

**Vanilla Kubernetes (minikube, kind, etc.):**
- `kubectl` CLI installed with a valid kubeconfig

### Step 1: Deploy Platform

```bash
# OpenShift (default)
./scripts/setup.sh

# Or vanilla Kubernetes
./scripts/setup.sh --k8s
```

The script will:
- Prompt for a **namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
- Auto-detect your cluster domain (OpenShift) or skip routes (K8s)
- Prompt for an Anthropic API key (optional, for agents using Claude)
- Generate all other secrets into `.env` (git-ignored)
- Run `envsubst` on `.envsubst` templates to produce deployment YAML
- Create OAuthClients for web UI authentication (OpenShift only)

### Step 2: Deploy Agents

After OpenClaw is running:

```bash
# Wait for gateway to be ready
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=600s

# Deploy agents
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

The script will:
- Prompt to **customize the default agent name** (or keep "Shadowman")
- Install agent identity files (AGENTS.md, agent.json) into each workspace
- Set up RBAC and cron jobs

### Pre-Built Agents

| Agent | Description | Schedule |
|-------|-------------|----------|
| `<prefix>_<custom_name>` | Interactive agent (default: Shadowman, customizable). Uses Anthropic Claude. | On-demand |
| `<prefix>_resource_optimizer` | Analyzes K8s resource usage in `resource-demo` namespace | Daily at 8 AM UTC |

The default agent name is customizable during `setup-agents.sh`. For example, entering "Lynx" creates agent ID `sally_lynx` with display name "Lynx". The choice is saved to `.env` for future re-runs.

### Access Your Platform

**OpenShift** — URLs are displayed after `setup.sh` completes:

```
OpenClaw Gateway:          https://openclaw-<prefix>-openclaw.apps.YOUR-CLUSTER.com
```

The UI uses OpenShift OAuth login. On first visit, the Control UI will prompt you to paste the **Gateway Token** to connect. You can find it in your `.env` file:

```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

**Kubernetes** — Use port-forwarding:

```bash
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

### Verify Deployment

```bash
# Replace <prefix> with your namespace prefix (e.g., sally)
oc get pods -n <prefix>-openclaw
```

**Expected pods:**
- `openclaw-*` (1 replica, gateway + OTEL sidecar)

### Teardown

```bash
# Full teardown (removes namespace, OAuthClients, PVCs)
./scripts/teardown.sh

# Options:
./scripts/teardown.sh --k8s              # Kubernetes mode
./scripts/teardown.sh --delete-env       # Also delete .env file
```

The teardown script reads `.env` for namespace configuration. If `.env` is missing, set `OPENCLAW_NAMESPACE` manually:

```bash
OPENCLAW_NAMESPACE=sally-openclaw ./scripts/teardown.sh
```

## Configuration Management

OpenClaw's config (`openclaw.json`) can be edited through the Control UI or directly in the manifests. Understanding how config flows between these layers is important to avoid losing changes.

### How Config Flows

```
.envsubst template          ConfigMap              PVC (live config)
(source of truth)    -->    (K8s object)    -->    /home/node/.openclaw/openclaw.json
                          setup.sh runs           init container copies
                          envsubst + deploy       on every pod restart
```

1. **Source of truth**: `manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst` (or the `k8s/` equivalent)
2. **Deploy**: `setup.sh` runs `envsubst` to produce the ConfigMap YAML and applies it
3. **Pod startup**: The init container copies `openclaw.json` from the ConfigMap mount to the PVC **on every restart**
4. **Runtime**: OpenClaw reads config from the PVC. UI settings changes write to the PVC.

**The catch**: UI changes live only on the PVC. The next pod restart (deploy, rollout, node eviction) overwrites the PVC config with whatever is in the ConfigMap. Export your changes before that happens.

### Exporting Live Config

If you've made changes through the OpenClaw Control UI (settings, model config, tool permissions, etc.), export the live config before it gets overwritten:

```bash
# Export to default file (openclaw-config-export.json)
./scripts/export-config.sh

# Export with custom output path
./scripts/export-config.sh -o my-config.json

# Kubernetes mode
./scripts/export-config.sh --k8s
```

### Syncing Changes Back to Manifests

After exporting, update the `.envsubst` template so the changes survive future deploys:

```bash
# 1. Export live config
./scripts/export-config.sh

# 2. Compare against the current template
diff <(python3 -m json.tool openclaw-config-export.json) \
     <(python3 -m json.tool manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst)

# 3. Edit the .envsubst template with the changes
#    - Copy the new/changed sections from the export
#    - Replace concrete values with ${VAR} placeholders where needed
vi manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst

# 4. Redeploy to apply (generates new ConfigMap from template)
./scripts/setup.sh
```

**What to replace with placeholders**: Any value that varies per deployment or contains secrets. Common substitutions:

| Exported value | Replace with |
|---------------|-------------|
| `sallyom` (your prefix) | `${OPENCLAW_PREFIX}` |
| `sallyom-openclaw` | `${OPENCLAW_NAMESPACE}` |
| `apps.mycluster.com` | `${CLUSTER_DOMAIN}` |
| Agent custom name (e.g., `lynx`) | `${SHADOWMAN_CUSTOM_NAME}` |
| Agent display name (e.g., `Lynx`) | `${SHADOWMAN_DISPLAY_NAME}` |

Everything else (model IDs, tool settings, port numbers, etc.) can stay as literal values.

### Recommended Workflow

For day-to-day config changes:

1. **Quick iteration**: Change settings in the UI, test immediately
2. **Before you're done**: Run `./scripts/export-config.sh` to capture your changes
3. **Persist**: Update the `.envsubst` template and commit to Git
4. **Redeploy anytime**: `setup.sh` reproduces the exact config from templates + `.env`

## Repository Structure

```
openclaw-k8s/
├── scripts/
│   ├── setup.sh                # Step 1: Deploy OpenClaw gateway
│   ├── setup-agents.sh         # Step 2: Deploy agents, RBAC, cron jobs
│   ├── update-jobs.sh          # Update cron jobs + report script (quick iteration)
│   ├── export-config.sh        # Export live config from running pod
│   ├── teardown.sh             # Remove everything
│   └── build-and-push.sh      # Build images with podman (optional)
│
├── .env                        # Generated secrets (GIT-IGNORED)
│
├── manifests/
│   └── openclaw/
│       ├── base/               # Core resources (deployment, service, PVCs)
│       ├── base-k8s/           # Kubernetes-specific base (no Routes/OAuth)
│       ├── overlays/
│       │   ├── openshift/      # OpenShift overlay (secrets, config, OAuth, routes)
│       │   └── k8s/            # Vanilla Kubernetes overlay
│       ├── agents/             # Agent configs, RBAC, cron jobs
│       │   ├── shadowman/      # Default agent (customizable name)
│       │   ├── resource-optimizer/  # Resource analysis agent + CronJob
│       │   ├── audit-reporter/     # Compliance monitoring (future)
│       │   └── mlops-monitor/      # ML operations tracking (future)
│       └── llm/                # vLLM reference deployment (GPU model server)
│
├── observability/              # OTEL sidecar and collector templates
│   ├── openclaw-otel-sidecar.yaml.envsubst
│   └── vllm-otel-sidecar.yaml.envsubst
│
└── docs/
    ├── ARCHITECTURE.md
    ├── TEAMMATE-QUICKSTART.md
    ├── OBSERVABILITY.md
    └── k8s-deployment-guide.md
```

**Key Patterns:**
- `.envsubst` files = Templates with `${VAR}` placeholders (committed to Git)
- `.env` file = Generated secrets (git-ignored, created by `setup.sh`)
- `setup.sh` runs `envsubst` on all templates, then deploys via kustomize overlays
- `setup-agents.sh` runs `envsubst` on agent templates only, then configures agents

## Multi-User Support

Each team member deploys their own OpenClaw instance with a unique namespace prefix:

```
alice-openclaw    # Alice's agents: alice_lynx, alice_resource_optimizer
bob-openclaw      # Bob's agents: bob_shadowman, bob_resource_optimizer
```

Namespaces are fully isolated. Each team member runs their own `setup.sh` with a different prefix.

## System Requirements

**Required:**
- OpenShift 4.12+ with cluster-admin, **or** vanilla Kubernetes (minikube, kind, etc.)
- `oc` or `kubectl` CLI installed

**Optional:**
- Anthropic API key (for agents using Claude models; without it, agents use in-cluster models only)
- OpenTelemetry Operator (for observability — see [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md))
- Podman (only if building custom images)

## OpenShift Compliance

All manifests are OpenShift `restricted` SCC compliant:

- No root containers (arbitrary UIDs)
- No privileged mode
- Drop all capabilities
- Non-privileged ports only
- ReadOnlyRootFilesystem support
- ResourceQuota (namespace limits: 4 CPU, 8Gi RAM)
- PodDisruptionBudget (high availability)
- NetworkPolicy (network isolation)

See [docs/OPENSHIFT-SECURITY-FIXES.md](docs/OPENSHIFT-SECURITY-FIXES.md) for details.

### Security Configuration

- **Auth mode**: `token` — requires `OPENCLAW_GATEWAY_TOKEN` for API access
- **Exec security**: `allowlist` mode — only `curl` and `jq` are permitted
- **Tool deny list**: `browser`, `canvas`, `nodes`, `process`, `tts`, `web_fetch`, `gateway` are blocked
- **OAuth proxy**: OpenShift deployments use OAuth for web UI authentication

## Troubleshooting

**Setup script fails with "not logged in to OpenShift":**
- Run `oc login https://api.YOUR-CLUSTER:6443` first

**OAuthClient creation fails:**
- Requires cluster-admin role
- Ask your cluster admin to run: `oc apply -f manifests/openclaw/overlays/openshift/oauthclient.yaml`

**OAuthClient 500 "unauthorized_client" after login:**
- OpenShift can corrupt OAuthClient secret state on `oc apply`

**Pods stuck in "CreateContainerConfigError":**
- Check secrets exist: `oc get secrets -n <prefix>-openclaw`
- Re-run `./scripts/setup.sh` if secrets are missing

**Agent not appearing in Control UI:**
- Check config: `oc get configmap openclaw-config -n <prefix>-openclaw -o yaml`
- Restart gateway: `oc rollout restart deployment/openclaw -n <prefix>-openclaw`

**Agent workspace files missing or wrong:**
- `setup-agents.sh` copies AGENTS.md and agent.json from ConfigMaps into each agent's workspace
- Re-run `setup-agents.sh` to refresh

## License

MIT
