# OpenClaw OpenShift Deployment

Secure deployment of OpenClaw gateway on OpenShift with OAuth proxy, RBAC, and network isolation.

## Quick Start

```bash
# 1. Generate secrets (REQUIRED - do not skip!)
export GATEWAY_TOKEN=$(openssl rand -base64 32)
export OAUTH_SECRET=$(openssl rand -base64 32)
export COOKIE_SECRET=$(openssl rand -base64 32)

echo "GATEWAY_TOKEN=$GATEWAY_TOKEN"
echo "OAUTH_SECRET=$OAUTH_SECRET"
echo "COOKIE_SECRET=$COOKIE_SECRET"

# 2. Update secrets in manifests (see SECURITY.md for details)

# 3. Deploy cluster-scoped resources (requires cluster-admin)
oc apply -f openclaw-oauthclient.yaml

# 4. Deploy application
oc apply -k base/

# 5. Verify deployment
oc get all,networkpolicy,resourcequota,pdb -n openclaw
```

## Architecture

```
Internet → OpenShift Route (TLS) → OAuth Proxy (8443) → Gateway (18789) → In-cluster Model
                                         ↓
                                  OpenShift OAuth
```

## Security Features

✅ **OpenShift OAuth** - All access requires OpenShift authentication
✅ **Non-root containers** - Runs as UID 1000
✅ **Read-only filesystem** - Runtime immutability
✅ **NetworkPolicy** - Ingress/egress restrictions
✅ **ResourceQuota** - Namespace-level limits
✅ **Command allowlist** - Prevents arbitrary code execution
✅ **External content wrapping** - Prompt injection protection

## Directory Structure

```
manifests/openclaw/
├── README.md                           # This file
├── SECURITY.md                         # Comprehensive security guide
├── openclaw-oauthclient.yaml          # Cluster-scoped OAuth client
└── base/
    ├── kustomization.yaml             # Kustomize config
    ├── openclaw-deployment.yaml       # Main deployment
    ├── openclaw-service.yaml          # Service definition
    ├── openclaw-route.yaml            # OpenShift route
    ├── openclaw-config-configmap.yaml # Application config
    ├── openclaw-secrets-secret.yaml   # Secrets (CHANGE DEFAULTS!)
    ├── openclaw-oauth-*.yaml          # OAuth proxy config
    ├── openclaw-*-pvc-*.yaml          # Persistent volumes
    ├── openclaw-networkpolicy.yaml    # Network restrictions
    ├── openclaw-resourcequota.yaml    # Resource limits
    └── openclaw-poddisruptionbudget.yaml  # HA config
└── agents/
    └── *-agent.yaml                   # Agent configurations
```

## Agents

Pre-configured agents:
- **PhilBot**: Philosophical discussions
- **TechBot**: Technology Q&A
- **PoetBot**: Creative writing
- **AdminBot**: Content moderation

Each agent has:
- Dedicated workspace under `/workspace/agents/<name>/`
- API key for Moltbook integration (stored in secrets)
- Shared skills directory

## Configuration

### Key Settings (openclaw-config-configmap.yaml)

```json
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "trustedProxies": ["10.128.0.0/14"],  // OpenShift pod network
    "auth": {
      "mode": "token",
      "allowTailscale": false
    },
    "controlUi": {
      "enabled": true,
      "dangerouslyDisableDeviceAuth": false  // SECURITY: Device auth enabled
    }
  },
  "tools": {
    "exec": {
      "security": "allowlist",  // SECURITY: Default deny
      "safeBins": ["curl"],
      "timeoutSec": 30
    }
  },
  "models": {
    "providers": {
      "nerc": {
        "baseUrl": "http://...",  // In-cluster model
        "api": "openai-completions"
      }
    }
  }
}
```

### Environment Variables (openclaw-secrets-secret.yaml)

- `OPENCLAW_GATEWAY_TOKEN`: API authentication token
- `OTEL_EXPORTER_OTLP_ENDPOINT`: OpenTelemetry collector


### NetworkPolicy blocking traffic

```bash
# Temporarily disable NetworkPolicy for debugging
oc delete networkpolicy openclaw-netpol -n openclaw

# Re-enable after debugging
oc apply -f base/openclaw-networkpolicy.yaml
```

## Cleanup

```bash
# Delete all resources
oc delete -k base/

# Delete OAuthClient (cluster-scoped)
oc delete oauthclient openclaw

# Delete namespace (if desired)
oc delete namespace openclaw
```

## Security Checklist

Before going to production:

- [ ] Generated random secrets (not using `CHANGEME` values)
- [ ] Updated cluster domain in Route and OAuthClient
- [ ] Reviewed NetworkPolicy egress rules (tighten if needed)
- [ ] Enabled health probes and verified they work
- [ ] Set up monitoring/alerting for authentication failures
- [ ] Documented secret rotation procedures
- [ ] Reviewed ResourceQuota limits for your workload
- [ ] Tested OAuth authentication flow
- [ ] Verified command execution allowlist matches your needs
- [ ] Configured backup for PVCs (if using stateful agents)

## Additional Documentation

- [SECURITY.md](./SECURITY.md) - Comprehensive security guide
- [OpenClaw Docs](https://docs.openclaw.ai/) - Official documentation
- [OpenShift Docs](https://docs.openshift.com/) - Platform documentation

## Support

For issues specific to this deployment, check:
1. Pod logs: `oc logs -n openclaw deployment/openclaw --all-containers`
2. Events: `oc get events -n openclaw`
3. Security guide: [SECURITY.md](./SECURITY.md)

For OpenClaw-specific issues, see: https://github.com/openclaw/openclaw/issues
