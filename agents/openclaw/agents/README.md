# OpenClaw Agents

## Why Separate?

The core OpenClaw deployment includes a single generic agent (shadowman), but additional specialized agents are optional. This:
- Allows OpenClaw to run with just shadowman out-of-the-box
- Makes specialized agent setup optional and repeatable
- Simplifies the core deployment

## Available Agents

| Agent | Role | Schedule | Purpose |
|-------|------|----------|---------|
| shadowman | interactive | On-demand | Generic friendly assistant (included in base, customizable name) |
| resource-optimizer | scheduled | 8AM UTC daily | Cost optimization and resource efficiency analysis |
| **audit-reporter** | scheduled | Every 6 hours | Governance and compliance monitoring (future) |
| mlops-monitor | scheduled | Every 4 hours | ML operations tracking (future) |

---

## Prerequisites

### 1. Create Demo Namespace (Optional)

For resource-optimizer to have something to analyze, deploy the demo workloads.
These simulate a realistic (but poorly managed) microservices deployment:

```bash
# Create namespace
oc new-project resource-demo

# Deploy all demo workloads
oc apply -f demo-workloads/demo-wasteful-app.yaml
oc apply -f demo-workloads/demo-idle-app.yaml
oc apply -f demo-workloads/demo-unused-pvc.yaml

# Verify
oc get all,pvc -n resource-demo
```

#### Demo Workloads Overview

**Over-provisioned services** (`demo-wasteful-app.yaml`) — all running `sleep infinity`:

| Deployment | Replicas | CPU Req | Memory Req | Waste Pattern |
|------------|----------|---------|------------|---------------|
| `api-gateway` | 3 | 100m | 128Mi | 3 replicas of a proxy doing nothing |
| `ml-inference` | 5 | 50m | 64Mi | 5 replicas when traffic is zero |
| `redis-cache` | 2 | 50m | 64Mi | Cache layer with no data |
| `batch-worker` | 1 | 50m | 64Mi | Background worker with nothing to process |

**Idle / abandoned workloads** (`demo-idle-app.yaml`):

| Deployment | Replicas | Story |
|------------|----------|-------|
| `staging-frontend` | 0 | Staging environment someone forgot to tear down |
| `loadtest-runner` | 0 | Load test runner left over from last quarter |
| `debug-shell` | 1 | Debug pod someone left running |

**Unattached storage** (`demo-unused-pvc.yaml`):

| PVC | Size | Story |
|-----|------|-------|
| `db-migration-backup` | 5Gi | Database backup from a migration that finished months ago |
| `legacy-logs-volume` | 2Gi | Logs volume for a service that now ships to Splunk |
| `ml-training-data` | 10Gi | Used for a one-time ML model training job |

Resource requests are kept small to avoid wasting real cluster capacity.
The demo value is in the variety of workloads and waste patterns, not the sizes.

---

## Deployment

The recommended way to deploy agents is via `./scripts/setup-agents.sh`, which handles ConfigMap deployment, RBAC setup, workspace initialization, and cron job configuration.

### Manual Deployment

If deploying manually:

```bash
# 1. Deploy agent ConfigMaps
oc apply -f shadowman/shadowman-agent.yaml
oc apply -f resource-optimizer/resource-optimizer-agent.yaml

# 2. Deploy RBAC for resource-optimizer
oc apply -f resource-optimizer/resource-optimizer-rbac.yaml

# 3. Apply agent config patch
oc apply -f agents-config-patch.yaml

# 4. Restart OpenClaw to pick up changes
oc rollout restart deployment/openclaw -n <prefix>-openclaw
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=120s
```

---

## Agent Details

### Shadowman (Interactive, Customizable Name)

The default agent. Its name is customizable during `setup-agents.sh` (e.g., "Lynx", "Sparky"). Uses Anthropic Claude for interactive conversations.

- On-demand via WebChat or Control UI
- Has access to `exec` tool (curl, jq via allowlist)
- Workspace: `~/.openclaw/workspace-<prefix>_<custom_name>/`

### Resource Optimizer (Scheduled)

Analyzes K8s resource usage and identifies waste.

**What it monitors:**
- `resource-demo` namespace — pods, deployments, and PVCs
- Over-provisioned pods (high requests, low usage)
- Idle deployments (0 replicas or abandoned)
- Unattached PVCs (not mounted to any pod)

**How it works:**

The heavy lifting runs as a K8s CronJob — no LLM needed for the actual analysis:

| Component | File | Purpose |
|-----------|------|---------|
| CronJob | `resource-optimizer/resource-report-cronjob.yaml.envsubst` | Scheduled runs (8AM UTC daily) |
| RBAC | `resource-optimizer/resource-optimizer-rbac.yaml.envsubst` | Read-only SA for K8s API queries |
| Report script | Deployed to pod by `update-jobs.sh` | In-pod execution via cron |

**Triggering reports:**

```bash
# Automatic — CronJob runs daily at 8AM UTC
oc get cronjob resource-report -n $OPENCLAW_NAMESPACE

# Manual — check logs from last run
oc logs -l job=resource-report -n $OPENCLAW_NAMESPACE --tail=100
```

**Updating cron jobs and scripts:** Run `./scripts/update-jobs.sh` to iterate without a full re-deploy.

### Audit Reporter (Future)

Compliance and governance monitoring agent. ConfigMap exists at `audit-reporter/audit-reporter-agent.yaml` but is not yet deployed by `setup-agents.sh`.

### MLOps Monitor (Future)

ML operations tracking agent for MLFlow experiments. ConfigMap exists at `mlops-monitor/mlops-monitor-agent.yaml` but is not yet deployed by `setup-agents.sh`.

---

## Creating Custom Agent-Triggered Jobs

The resource-report CronJob provides a pattern for creating your own K8s Jobs that run independently of the LLM.

### How It Works

```
┌─────────────┐     K8s CronJob     ┌──────────────┐
│  Schedule    │ ──────────────────► │  Job pod      │
│  (8AM UTC)   │                     │  (your script)│
└─────────────┘                     └───────┬───────┘
                                            │
                                     queries K8s API
                                     writes report
```

1. The CronJob template lives in the repo as a `.envsubst` file
2. `setup-agents.sh` runs `envsubst` to fill in the namespace, then deploys the CronJob
3. The Job pod does the actual work (queries, analysis) independently of the LLM
4. Reports are printed to stdout (visible in job logs)

### Creating Your Own Job

1. **Copy the template:**

```bash
cp resource-optimizer/resource-report-cronjob.yaml.envsubst myagent/my-custom-cronjob.yaml.envsubst
```

2. **Edit the template** — change the container command, env vars, schedule, and labels

3. **Add to `setup-agents.sh`** for automated deployment, or deploy manually:

```bash
envsubst '${OPENCLAW_NAMESPACE}' < my-custom-cronjob.yaml.envsubst > my-custom-cronjob.yaml
oc apply -f my-custom-cronjob.yaml
```

### Key Design Decisions

- **Jobs run in `${OPENCLAW_NAMESPACE}`** — where the ServiceAccount and secrets already exist. The Job queries target namespaces via the K8s API; it doesn't need to run in them.
- **Read-only RBAC in target namespaces** — the SA gets a Role with `get`/`list` only. No write access to the namespaces being analyzed.
- **`node` for JSON parsing** — `jq` is not installed on the pod image. Use `node -e` for parsing K8s API responses.

---

## Removing Agents

To remove custom agents (resource-optimizer) while keeping the gateway:

```bash
./remove-custom-agents.sh           # OpenShift
./remove-custom-agents.sh --k8s     # Kubernetes
```

---

## Enterprise Value Demonstration

This setup showcases:

- **Cost Optimization** — Automated detection of wasteful resource usage
- **Platform Engineering** — Autonomous agents reducing manual toil
- **AI Governance** — Audit-reporter monitors the AI platform itself (future)
- **ML Operations** — Tracking experiments and model training (future)

**Perfect for demos to:** DevOps teams, Platform Engineers, FinOps, MLOps, Compliance/Security teams
