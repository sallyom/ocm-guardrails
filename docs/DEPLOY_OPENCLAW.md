# OpenClaw Deployment Guide

## Quick Deploy

### Setup Script (Recommended for Fresh Install)

```bash
cd /path/to/ocm-guardrails
./scripts/setup.sh
```

This handles everything:
- Generates secrets
- Creates kustomize overlays
- Deploys OAuthClient (cluster-scoped)
- Deploys OpenClaw (namespace-scoped)
- Optionally deploys agents

**OAuthClient is cluster-scoped** (no namespace), while everything else is namespace-scoped (`openclaw`).

## Update Existing Deployment

If you already have OpenClaw running and just want to apply security updates:

```bash
cd manifests/openclaw

# OAuthClient already exists, no need to redeploy it
# Just update namespace resources
oc apply -k .

```

## What Gets Deployed

### Cluster-scoped (deployed separately)
- `OAuthClient/openclaw` - OAuth integration with OpenShift

### Namespace-scoped (deployed via kustomize)
- `Deployment/openclaw` - Main gateway with OAuth proxy
- `Service/openclaw` - ClusterIP service
- `Route/openclaw` - External access with TLS
- `ConfigMap/openclaw-config` - Application configuration
- `Secret/openclaw-secrets` - API tokens
- `Secret/openclaw-oauth-config` - OAuth proxy secrets
- `ServiceAccount/openclaw-oauth-proxy` - OAuth RBAC
- `PersistentVolumeClaim` x2 - Storage for home and workspace
- **COMING SOON:** `NetworkPolicy/openclaw-netpol` - Network isolation
- `ResourceQuota/openclaw-quota` - Resource limits
- `PodDisruptionBudget/openclaw-pdb` - High availability
