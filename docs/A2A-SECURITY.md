# A2A Security: Identity, Content, and Audit

## The Two Layers of Agent Communication Security

Securing agent-to-agent communication requires two distinct layers:

1. **Identity** — Who is talking? Is the caller who they claim to be?
2. **Content** — What are they saying? Is sensitive data being leaked?

These are independent concerns. A cryptographically verified identity doesn't prevent the agent from sharing a secret, and a content filter doesn't help if you can't verify who sent the message.

```
                    Identity Layer                    Content Layer
                    (implemented)                     (monitoring + roadmap)

                ┌─────────────────────┐          ┌─────────────────────┐
                │  SPIFFE / Keycloak  │          │  OTEL Traces        │
                │                     │          │  (audit trail)      │
 Who is this? ──│  X.509 certificates │          │                     │── What did they say?
                │  JWT tokens         │          │  DLP Filters        │
                │  OAuth exchange     │          │  (active prevention)│
                └─────────────────────┘          └─────────────────────┘

                Answers:                         Answers:
                - Is this agent authentic?       - Did the agent leak credentials?
                - Which namespace sent this?     - Did it share PII or secrets?
                - Can I revoke access?           - Is the conversation auditable?
```

## Identity Layer (Implemented)

The AuthBridge provides zero-trust identity for every cross-namespace call. No agent handles tokens — authentication is transparent.

### Three Levels of Identity

Agent communication involves three distinct identity levels. Two are implemented today; one is tied together via namespace annotations.

```
┌──────────────────────────────────────────────────────────────────┐
│  Human Identity                                                  │
│  "Sally" — the person who owns this instance                     │
│                                                                  │
│  Source: OpenShift OAuth (oc whoami)                             │
│  Recorded: K8s namespace annotation openclaw.dev/owner           │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Workload Identity                                         │  │
│  │  spiffe://demo.example.com/ns/sallyom-openclaw/sa/...      │  │
│  │                                                            │  │
│  │  Source: SPIRE (X.509 + JWT)                               │  │
│  │  Registered in: Keycloak spiffe-demo realm (auto)          │  │
│  │                                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  Agent Identity                                      │  │  │
│  │  │  "Lynx" (sallyom_lynx)                               │  │  │
│  │  │                                                      │  │  │
│  │  │  Source: openclaw.json config + A2A agent card       │  │  │
│  │  │  Recorded: K8s namespace annotation                  │  │  │
│  │  │            openclaw.dev/agent-name                   │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**Human identity** — OpenShift authenticates the person via OAuth when they access the UI. Keycloak does NOT track human users. The link between "Sally" and her namespace is recorded as a K8s annotation set during `setup.sh`:

```yaml
metadata:
  annotations:
    openclaw.dev/owner: sallyom
    openclaw.dev/agent-name: Lynx
    openclaw.dev/agent-id: sallyom_lynx
```

**Workload identity** — SPIFFE/Keycloak authenticates the pod for machine-to-machine calls. When the pod starts, the `client-registration` sidecar auto-registers a Keycloak client using the SPIFFE ID as the client ID. The `spiffe-demo` realm in Keycloak tracks workload clients, not human users.

**Agent identity** — the named agent (Lynx, Shadowman) is an application-level concept. The A2A agent card at `/.well-known/agent.json` advertises the agent name and capabilities. This is what remote agents see during discovery.

### Keycloak Audit Trail

The `spiffe-demo` realm in Keycloak records workload-level events:

| Event | What It Shows |
|-------|---------------|
| Client registration | A new OpenClaw instance came online (SPIFFE ID as client ID) |
| Token exchange | A pod requested an OAuth token to call another instance |
| Token validation | An inbound call's token was verified |
| Client removal | An instance was decommissioned |

To correlate these with human owners, query the namespace annotation:

```bash
# Who owns the namespace that made this call?
oc get namespace sallyom-openclaw -o jsonpath='{.metadata.annotations.openclaw\.dev/owner}'
# → sallyom
```

Future improvement: an admission controller could auto-set `openclaw.dev/owner` from the authenticated user creating the namespace, removing the need for manual annotation.

### How Authentication Works

1. Each OpenClaw instance gets a SPIFFE identity via SPIRE:
   ```
   spiffe://demo.example.com/ns/sallyom-openclaw/sa/openclaw-oauth-proxy
   ```

2. On **outbound** calls, Envoy intercepts the request, exchanges the SPIFFE JWT for a Keycloak OAuth token, and injects it as an `Authorization` header

3. On **inbound** calls, the remote instance's Envoy validates the OAuth token against Keycloak before forwarding to the A2A bridge

### What This Guarantees

| Property | How |
|----------|-----|
| **Authentication** | Every call carries a cryptographically signed token — no spoofing |
| **Workload attribution** | The SPIFFE ID encodes namespace and service account — you know which instance made the call |
| **Human attribution** | Namespace annotations link workload identity to the human owner |
| **Revocation** | Disable an instance by removing its SPIRE registration entry or Keycloak client |
| **Auditability** | Keycloak logs every token exchange; Envoy access logs record every request |
| **Non-repudiation** | Token chain (SPIFFE → Keycloak → OAuth) + namespace annotation creates a verifiable record |

### What This Does NOT Guarantee

Identity controls verify the caller but do not inspect message content. A verified agent can still:
- Include credentials from its workspace in a message
- Forward sensitive data it received from a tool or file read
- Share internal configuration details

This is analogous to two employees with valid badges — the badge proves who they are, but doesn't prevent them from sharing confidential information in conversation.

## Content Layer: Audit Trail (Implemented)

Every A2A call is traced end-to-end via OpenTelemetry with full GenAI semantic conventions. Traces land in MLflow where they can be searched, filtered, and reviewed.

### What the Traces Capture

Each cross-namespace A2A call produces a trace with:

| Field | Source | Example |
|-------|--------|---------|
| **Input message** | A2A bridge | `"Hi Shadowman, this is Lynx from sallyom-openclaw"` |
| **Output message** | Gateway response | `"Hey Lynx! I'm Shadow-man, here to help you..."` |
| **Model** | Gateway | `chat openai/gpt-oss-20b` |
| **Token count** | Gateway | `58600` |
| **Latency** | OTEL | `5.49s` |
| **Session ID** | Gateway | `agent:mai...` |
| **Trace ID** | OTEL | `tr-d0434eeefc2840ce0bf4b24f992b24dd` |
| **Namespace** | SPIFFE identity | `sallyom-openclaw` |

### Trace Structure

```
openclaw.message
└── invoke_agent
    ├── chat openai/gpt-oss-20b        ← model call with full input/output
    │   └── llm_request
    ├── chat openai/gpt-oss-20b        ← follow-up reasoning
    │   └── llm_request
    ├── execute_tool read               ← agent reading files
    └── execute_tool read
```

The full message content is visible in MLflow under Inputs/Outputs for each span. This means every word exchanged between agents across namespaces is recorded and searchable.

### Using Traces for Security Auditing

**Reactive auditing** — review after the fact:
```bash
# Search MLflow for traces containing sensitive patterns
# (via MLflow UI search or API)
mlflow.search_traces(
    filter_string="attributes.input LIKE '%API_KEY%'"
)
```

**Alerting** — set up MLflow or a downstream consumer to flag traces where agent messages contain patterns matching secrets, credentials, or PII.

**Compliance** — the trace record provides:
- Who communicated (SPIFFE identity in trace attributes)
- What was said (full message content in spans)
- When it happened (timestamps)
- Which model processed it (model ID in span attributes)
- How long it took (latency)

## Content Layer: Active Prevention (Roadmap)

Audit trails catch leaks after the fact. For active prevention — blocking sensitive data before it leaves the pod — there are two natural integration points.

### Option 1: Envoy ext_proc Content Filter

The AuthBridge already uses an `ext_proc` (External Processing) filter in Envoy for token exchange. This same mechanism can inspect message bodies.

```
Agent → curl → iptables → Envoy → ext_proc → [TOKEN EXCHANGE + DLP CHECK] → remote
```

**How it would work:**

The ext_proc processor (port 9090) currently only processes request headers for token injection. Extending it to inspect request bodies:

1. Change the Envoy config processing mode from `request_body_mode: NONE` to `request_body_mode: BUFFERED`
2. The processor receives the full request body (the A2A JSON-RPC message)
3. Scan the message text for sensitive patterns (API keys, tokens, credentials, PII)
4. Reject the request with a 403 if a match is found, or redact and forward

**Advantages:**
- Catches ALL outbound traffic, not just A2A (any curl the agent makes)
- Runs before the request leaves the pod — true prevention, not just detection
- No changes to the A2A bridge or gateway code
- Pattern updates don't require pod restarts (processor can reload rules)

**Configuration change** in `authbridge-envoy-config` ConfigMap:
```yaml
processing_mode:
  request_header_mode: SEND
  response_header_mode: SKIP
  request_body_mode: BUFFERED     # ← change from NONE
  response_body_mode: NONE
```

### Option 2: A2A Bridge DLP Filter

Add content scanning directly in the A2A bridge's `handleA2AMessage()` function, inspecting both inbound messages and outbound responses.

```javascript
// In handleA2AMessage(), before returning the response:
const sensitivePatterns = [
  /sk-[a-zA-Z0-9]{20,}/,           // Anthropic API keys
  /ghp_[a-zA-Z0-9]{36}/,           // GitHub tokens
  /eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/, // JWT tokens
  /OPENCLAW_GATEWAY_TOKEN/,         // Gateway token reference
  /-----BEGIN.*PRIVATE KEY-----/,   // Private keys
];

for (const pattern of sensitivePatterns) {
  if (pattern.test(content)) {
    return {
      jsonrpc: '2.0',
      id: a2aRequest.id,
      error: { code: -32603, message: 'Response blocked: contains sensitive content' }
    };
  }
}
```

**Advantages:**
- Simple to implement — a few lines in existing code
- Can differentiate between inbound and outbound filtering
- Bridge-specific logic (only affects A2A, not other agent traffic)

**Disadvantages:**
- Only covers A2A traffic through the bridge — doesn't catch direct curl to external URLs
- Requires pod restart to update patterns

### Option 3: Gateway-Level Guardrails

OpenClaw's gateway has a permission and policy system that could be extended with output filtering rules. This would apply to all agent responses regardless of channel (A2A, WebChat, API).

This is the most comprehensive option but requires upstream OpenClaw changes.

### Recommendation

Start with **OTEL trace auditing** (already working) for visibility into what agents are saying. Add **Envoy ext_proc content filtering** as the next step — it provides active prevention at the network layer without changing application code, and it covers all outbound traffic from the pod, not just A2A.

## Existing Controls Summary

Controls already in place that limit what agents can access and share:

| Control | Layer | What It Prevents |
|---------|-------|-----------------|
| `safeBins: ["curl", "jq"]` | Gateway exec policy | Agents can't run `cat`, `env`, or arbitrary commands |
| Tool deny list | Gateway tool policy | `browser`, `web_fetch`, `gateway` tools blocked |
| Per-agent workspaces | Filesystem isolation | Each agent can only access its own workspace directory |
| Read-only root FS | Container security | Can't write or exfiltrate outside designated paths |
| NetworkPolicy | K8s networking | Restricts which namespaces and ports the pod can reach |
| SPIFFE identity | AuthBridge | Every call is authenticated and attributable |
| OTEL traces | Observability | Full audit trail of all agent communication |
| Agent instructions | AGENTS.md prompt | Soft control: "never share credentials" (LLM-dependent) |

## Defense in Depth

The full security model layers identity, access control, content monitoring, and (future) content filtering:

```
┌─────────────────────────────────────────────────────────────┐
│  1. Network Layer                                           │
│     NetworkPolicy restricts pod-to-pod communication        │
├─────────────────────────────────────────────────────────────┤
│  2. Identity Layer                                          │
│     SPIFFE + Keycloak authenticates every cross-ns call     │
├─────────────────────────────────────────────────────────────┤
│  3. Access Control Layer                                    │
│     safeBins, tool deny list, per-agent workspaces          │
├─────────────────────────────────────────────────────────────┤
│  4. Content Monitoring Layer                                │
│     OTEL traces capture full message content → MLflow       │
├─────────────────────────────────────────────────────────────┤
│  5. Content Prevention Layer (roadmap)                      │
│     Envoy ext_proc DLP filter blocks sensitive patterns     │
└─────────────────────────────────────────────────────────────┘
```

Layers 1-4 are implemented. Layer 5 is the natural next step, using infrastructure (Envoy ext_proc) that is already deployed in every pod.
