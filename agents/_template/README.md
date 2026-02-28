# Agent Template

Use this skeleton to add a new agent implementation to the trusted A2A network platform.

## What you need to provide

1. **Container image** -- Your agent must be packaged as a container image
2. **Port** -- The port your agent listens on for health checks and API traffic
3. **Health check endpoint** -- An HTTP endpoint that returns 200 when your agent is ready

## Quick start

```bash
# 1. Copy this template
cp -r agents/_template agents/my-agent

# 2. Edit deployment.yaml
#    - Replace AGENT_IMAGE with your container image
#    - Replace AGENT_PORT with your agent's port
#    - Replace /healthz with your health check path

# 3. Update kustomization.yaml
#    - Add any additional ConfigMaps, Secrets, or Services your agent needs

# 4. Create an overlay for your target platform
mkdir -p agents/my-agent/overlays/openshift
mkdir -p agents/my-agent/overlays/k8s
```

## How composition works

Your agent's `kustomization.yaml` references the shared platform base:

```yaml
resources:
  - ../../../platform/base          # namespace, PVCs, quotas, PDB, RBAC
  - ../../../platform/auth-identity-bridge  # A2A auth (optional)
  - deployment.yaml                 # your agent deployment
```

The platform base provides:
- Namespace with labels
- PersistentVolumeClaims for agent data
- ResourceQuota (namespace-level limits)
- PodDisruptionBudget
- OAuth ServiceAccount and RBAC (OpenShift)

Your overlay composes with the platform overlay for your target:

```yaml
# agents/my-agent/overlays/openshift/kustomization.yaml
resources:
  - ../../base
  - ../../../../platform/overlays/openshift
```

## A2A integration (optional)

To enable zero-trust A2A communication via Kagenti:

1. Include `platform/auth-identity-bridge` in your base kustomization
2. Add the A2A sidecar containers to your deployment (see OpenClaw reference)
3. Use `platform/auth-identity-bridge/strip-a2a.yaml` to remove them when A2A is disabled

## Observability (optional)

Add the OTEL sidecar for distributed tracing:

1. Reference `platform/observability/openclaw-otel-sidecar.yaml` in your deployment
2. Set `sidecar.opentelemetry.io/inject` annotation on your pod
