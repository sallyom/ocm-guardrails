# Teammate Quickstart

## What You Need From Your Admin

- Access to the cluster (`oc login` or `kubectl` configured)
- (Optional) An Anthropic API key for Claude-powered agents

## Model Options

OpenClaw agents need an LLM endpoint. You have three options:

| Option | When to Use | Details |
|--------|------------|---------|
| **Anthropic API key** | You have an Anthropic API key and want to use Claude | Agents use `anthropic/claude-sonnet-4-5` |
| **Google Vertex AI** | Your org has a GCP project with Vertex AI enabled | Agents use `google-vertex/gemini-2.5-pro`, billed through GCP |
| **Deploy included vLLM** | Your cluster has GPU nodes and you want a free in-cluster model | Default `MODEL_ENDPOINT`: `http://vllm.openclaw-llms.svc.cluster.local/v1` |
| **Your own endpoint** | You already have an OpenAI-compatible model server | Supply your server's `/v1` URL as `MODEL_ENDPOINT` |

For Google Vertex, you'll need a GCP service account JSON key with Vertex AI permissions. The setup script will prompt for your project ID, region, and key file path.

To deploy the included vLLM reference server (requires GPU node):

```bash
oc apply -k manifests/openclaw/llm/    # or kubectl
oc rollout status deployment/vllm -n openclaw-llms --timeout=600s
```

See `manifests/openclaw/llm/README.md` for details.

## Step 1: Deploy Your OpenClaw

```bash
git clone <this-repo>
cd openclaw-k8s

./scripts/setup.sh           # OpenShift
./scripts/setup.sh --k8s     # Kubernetes
```

You'll be prompted for a **namespace prefix** (use your name, e.g., `bob`). This creates `bob-openclaw` with your own OpenClaw gateway and a default agent.

Wait for it to come up:

```bash
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=600s
```

## Step 2: Deploy Agents

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

This deploys two agents:

| Agent | What It Does |
|-------|-------------|
| `<prefix>_<your_name>` | Your interactive agent (Claude-powered) |
| `<prefix>_resource_optimizer` | Analyzes K8s resource usage (daily report) |

## Updating Cron Jobs

To iterate on cron job prompts or the resource-report script without a full re-deploy:

```bash
./scripts/update-jobs.sh           # OpenShift
./scripts/update-jobs.sh --k8s     # Kubernetes
```

This updates the resource-report script and cron jobs on the pod, then restarts the gateway. Much faster than re-running `setup-agents.sh`.

## Step 3: Verify

```bash
# OpenShift — URL shown at end of setup.sh output
# Kubernetes — port-forward:
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
```

---

## Creating Your Own Custom Agent

Use the existing agents as templates. You need two things: a ConfigMap and a config entry.

### 1. Create the Agent ConfigMap

Copy an existing agent and customize it. Save in its own directory as `manifests/openclaw/agents/myagent/myagent-agent.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myagent-agent
  namespace: <prefix>-openclaw
  labels:
    app: openclaw
    agent: myagent
data:
  AGENTS.md: |
    ---
    name: <prefix>_myagent
    description: What your agent does
    ---
    # My Agent
    Instructions for your agent go here.

  agent.json: |
    {
      "name": "<prefix>_myagent",
      "display_name": "My Agent",
      "description": "What your agent does",
      "capabilities": ["chat"],
      "tags": ["custom"],
      "version": "1.0.0"
    }
```

### 2. Add the Agent to OpenClaw Config

Edit `manifests/openclaw/agents/agents-config-patch.yaml.envsubst`. Add your agent to the `agents.list` array:

```json
{
  "id": "${OPENCLAW_PREFIX}_myagent",
  "name": "My Agent",
  "workspace": "~/.openclaw/workspace-${OPENCLAW_PREFIX}_myagent"
}
```

### 3. Deploy

```bash
# Apply ConfigMap
oc apply -f manifests/openclaw/agents/myagent/myagent-agent.yaml

# Apply updated config
oc apply -f manifests/openclaw/agents/agents-config-patch.yaml

# Restart OpenClaw to pick up the new agent
oc rollout restart deployment/openclaw -n <prefix>-openclaw
```

Or add your agent to `setup-agents.sh` for automated deployment on future runs.
