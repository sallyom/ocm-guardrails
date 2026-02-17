# Additional Agents

Beyond the default interactive agent deployed by `setup.sh`, you can add specialized agents with K8s RBAC, CronJobs, and scheduled tasks.

## Deploy

```bash
# Wait for OpenClaw to be ready
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=600s

# Deploy additional agents
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

The script:
- Runs `envsubst` on agent templates
- Deploys agent ConfigMaps (identity files, instructions)
- Sets up RBAC (ServiceAccount, Roles, RoleBindings)
- Installs agent identity files (AGENTS.md, agent.json) into workspaces
- Deploys demo workloads for the resource-optimizer to analyze
- Configures cron jobs for scheduled agent tasks
- Restarts OpenClaw to load the new agents

## Agents

### Resource Optimizer

| Field | Value |
|-------|-------|
| Agent ID | `<prefix>_resource_optimizer` |
| Model | In-cluster (20B) |
| Schedule | CronJob every 8 hours + internal cron at 9 AM / 5 PM UTC |
| Namespace access | `resource-demo` (read-only) |

The resource-optimizer demonstrates K8s-native features compensating for small model limitations:

1. **K8s CronJob** (no LLM): Runs every 8 hours, queries the K8s API for resource metrics across the `resource-demo` namespace, builds a plain-text report, writes it to the `resource-report-latest` ConfigMap
2. **OpenClaw internal cron** (LLM): Wakes the agent at 9 AM and 5 PM UTC. Agent reads the pre-collected report from `/data/reports/resource-optimizer/report.txt` (mounted ConfigMap), analyzes it, and messages the default agent via `sessions_send` if anything notable is found

This split works well with small models — the CronJob handles the complex K8s API queries and JSON parsing, while the agent handles reading structured text and producing short summaries.

**RBAC setup:**
- ServiceAccount `resource-optimizer-sa` in `<prefix>-openclaw`
- Read-only access to pods, deployments, services, PVCs in `resource-demo`
- Write access to `resource-report-latest` ConfigMap in `<prefix>-openclaw`
- SA token injected into agent workspace `.env` as `OC_TOKEN`

**Demo workloads:**
- `setup-agents.sh` creates the `resource-demo` namespace and deploys sample workloads for the agent to analyze
- Manifests at `manifests/openclaw/agents/demo-workloads/`

### Future Agents

| Agent | Directory | Status |
|-------|-----------|--------|
| Audit Reporter | `manifests/openclaw/agents/audit-reporter/` | Planned |
| MLOps Monitor | `manifests/openclaw/agents/mlops-monitor/` | Planned |

## Cron Jobs

The `update-jobs.sh` script writes OpenClaw's internal cron job definitions to `~/.openclaw/cron/jobs.json`. Use it for quick iteration without re-running the full `setup-agents.sh`:

```bash
./scripts/update-jobs.sh              # Update jobs + restart
./scripts/update-jobs.sh --skip-restart  # Update jobs only (called by setup-agents.sh)
```

## Per-Agent Model Configuration

Each agent can use a different model provider. The model is set in the config overlay:

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "nerc/openai/gpt-oss-20b" }
    },
    "list": [
      {
        "id": "prefix_lynx",
        "model": { "primary": "anthropic/claude-sonnet-4-5" }
      },
      {
        "id": "prefix_resource_optimizer"
      }
    ]
  }
}
```

Resolution order: agent-specific `model` > `agents.defaults.model.primary` > built-in default.

Model priority during setup (auto-detected):
1. Anthropic API key provided → `anthropic/claude-sonnet-4-5`
2. Google Vertex enabled → `google-vertex/gemini-2.5-pro`
3. Neither → `nerc/openai/gpt-oss-20b` (in-cluster vLLM)

## Files

| File | Description |
|------|-------------|
| `scripts/setup-agents.sh` | Agent deployment script |
| `scripts/update-jobs.sh` | Cron job quick-update script |
| `manifests/openclaw/agents/shadowman/` | Default agent config (customizable name) |
| `manifests/openclaw/agents/resource-optimizer/` | Resource optimizer agent, RBAC, CronJob |
| `manifests/openclaw/agents/resource-optimizer/resource-report-cronjob.yaml.envsubst` | K8s CronJob that collects resource data |
| `manifests/openclaw/agents/resource-optimizer/resource-optimizer-rbac.yaml.envsubst` | ServiceAccount, Roles, RoleBindings |
| `manifests/openclaw/agents/demo-workloads/` | Sample workloads for resource-demo namespace |
| `manifests/openclaw/agents/agents-config-patch.yaml.envsubst` | Config overlay adding agent definitions |
