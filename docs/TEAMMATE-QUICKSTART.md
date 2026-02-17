# Teammate Quickstart

Get your own OpenClaw instance running and communicate with your teammates' agents via A2A.

## What You Need From Your Admin

- Access to the cluster (`oc login` or `kubectl` configured)
- The AuthBridge SCC grant (admin runs this after your first deploy — see Step 2)
- (Optional) An Anthropic API key for Claude-powered agents

## Model Options

OpenClaw agents need an LLM endpoint. You have three options:

| Option | When to Use | Details |
|--------|------------|---------|
| **Anthropic API key** | You have an Anthropic API key and want to use Claude | Agents use `anthropic/claude-sonnet-4-5` |
| **Google Vertex AI** | Your org has a GCP project with Vertex AI enabled | Agents use `google-vertex/gemini-2.5-pro`, billed through GCP |
| **In-cluster vLLM** | Your cluster has a GPU node with vLLM deployed | Default `MODEL_ENDPOINT`: `http://vllm.openclaw-llms.svc.cluster.local/v1` |
| **Your own endpoint** | You already have an OpenAI-compatible model server | Supply your server's `/v1` URL as `MODEL_ENDPOINT` |

## Step 1: Deploy Your OpenClaw

```bash
git clone <this-repo>
cd openclaw-k8s

./scripts/setup.sh           # OpenShift
./scripts/setup.sh --k8s     # Kubernetes
```

The script prompts you for three things:

1. **Namespace prefix** — use your name (e.g., `bob`). Creates `bob-openclaw`.
2. **Agent name** — pick a name for your agent (e.g., `Shadowman`, `Lynx`, `Atlas`). This is who your teammates see when they communicate with you via A2A.
3. **API keys** — Anthropic key (optional), model endpoint, Vertex AI (optional).

After setup completes, your instance has:
- A gateway with your named agent
- An **A2A bridge** sidecar (port 8080) so other instances can discover and message your agent
- **AuthBridge** sidecars (SPIFFE + Envoy) that give your instance a unique cryptographic identity
- An **A2A skill** so your agent knows how to talk to other instances

## Step 2: Grant the SCC (OpenShift Only)

The AuthBridge sidecars need a custom SCC for iptables and SPIRE CSI access. Ask your admin to run:

```bash
oc adm policy add-scc-to-user openclaw-authbridge \
  -z openclaw-oauth-proxy -n <prefix>-openclaw
```

Then wait for the pod to come up:

```bash
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=600s
```

## Step 3: Verify Your Identity

Once the pod is running, check that your A2A identity is working:

```bash
# Check your agent card (what other instances see when they discover you)
oc exec deployment/openclaw -n <prefix>-openclaw -c gateway -- \
  curl -s http://localhost:8080/.well-known/agent.json | jq .
```

You should see your agent name and skills listed. This is the card remote agents fetch before messaging you.

```bash
# Check your SPIFFE identity
oc exec deployment/openclaw -n <prefix>-openclaw -c spiffe-helper -- \
  cat /opt/jwt_svid.token | cut -d. -f2 | base64 -d 2>/dev/null | jq .sub
```

This shows your cryptographic identity, e.g., `spiffe://demo.example.com/ns/bob-openclaw/sa/openclaw-oauth-proxy`. Every cross-namespace call is authenticated with this identity via Keycloak token exchange.

## Step 4: Talk to a Teammate's Agent

Once a teammate has their instance running, your agent can communicate with theirs. From the OpenClaw WebChat UI, ask your agent:

> Discover what agents are on sally-openclaw

Your agent will use the A2A skill to call `http://openclaw.sally-openclaw.svc.cluster.local:8080/.well-known/agent.json` and show you the available agents.

Then:

> Send a message to Sally's agent introducing yourself

The AuthBridge handles authentication transparently — your agent just makes a plain HTTP call, and Envoy injects the OAuth token.

## Step 5: Deploy Additional Agents (Optional)

To add the resource-optimizer agent (K8s resource analysis with CronJobs):

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

See [ADDITIONAL-AGENTS.md](ADDITIONAL-AGENTS.md) for details.

## Access Your Platform

**OpenShift** — URL shown at the end of `setup.sh` output:
```
OpenClaw Gateway:  https://openclaw-<prefix>-openclaw.apps.YOUR-CLUSTER.com
```

The UI uses OpenShift OAuth. The Control UI prompts for your **Gateway Token**:
```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

**Kubernetes** — port-forward:
```bash
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

## Quick Iteration

To update cron jobs or the resource-report script without a full re-deploy:

```bash
./scripts/update-jobs.sh           # OpenShift
./scripts/update-jobs.sh --k8s     # Kubernetes
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
