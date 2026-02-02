# OpenClaw Security Hardening Guide

This document describes the security measures implemented for OpenClaw deployment in OpenShift.

## Security Controls Summary

### 1. Authentication & Authorization

- **OpenShift OAuth Proxy**: All traffic passes through OAuth proxy before reaching the application
- **RBAC Integration**: OAuth proxy uses `system:auth-delegator` for token reviews
- **Device Authentication**: DISABLED for control UI (not needed when behind OAuth proxy)
  - `dangerouslyDisableDeviceAuth: true` is **SAFE** in this deployment
  - OAuth proxy provides stronger authentication than device verification
  - Users must have valid OpenShift credentials to access the gateway
  - This setting only affects the control UI, not API security
- **Gateway Token**: Separate token-based authentication for API access

### 2. Network Security

- **TLS Termination**: Edge TLS at OpenShift Route level
- **NetworkPolicy**: Restricts ingress/egress traffic (see `openclaw-networkpolicy.yaml`)
  - Currently disabled, debugging
  - Ingress: Only from OAuth proxy and OpenShift health checks
  - Egress: Limited to DNS, Kubernetes API, in-cluster services (model, MLflow, OTEL)
- **No Public Internet Exposure**: Gateway runs on internal port 18789

### 3. Container Security

- **Non-root Execution**: Containers run as UID 1000 (`node` user)
- **No Privilege Escalation**: `allowPrivilegeEscalation: false`
- **Capability Dropping**: All capabilities dropped (`drop: [ALL]`)
- **Read-only Root Filesystem**: Prevents runtime modifications
- **OpenShift SCC**: Runs under `restricted` Security Context Constraint

### 4. Resource Controls

- **ResourceQuota**: Namespace-level limits prevent DoS
  - CPU: 4 cores (requests), 8 cores (limits)
  - Memory: 8Gi (requests), 16Gi (limits)
  - Pods: Max 20
  - Storage: Max 100Gi
- **PodDisruptionBudget**: Ensures availability during maintenance
- **Pod Resource Limits**: Individual pod limits enforced

### 5. Application-level Security

- **Command Execution Allowlist**: Default deny with explicit allowlist
- **Safe Bins**: Limited to: `jq`, `grep`, `cut`, `sort`, `uniq`, `head`, `tail`, `tr`, `wc`, `curl`
- **External Content Wrapping**: Prevents prompt injection from webhooks/emails
- **System Prompt Guardrails**: AI safety constraints in agent system prompts
