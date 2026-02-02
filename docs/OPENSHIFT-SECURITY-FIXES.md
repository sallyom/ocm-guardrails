# OpenShift Security Compliance Fixes

## OpenShift Security Constraints

OpenShift runs with the `restricted` SCC (Security Context Constraint) by default:

1. ❌ **No root user** - Containers must run as non-root
2. ⚠️ **Arbitrary UIDs** - OpenShift assigns random UIDs (not the Dockerfile USER)
3. ❌ **No privileged** - Can't use privileged mode
4. ❌ **Drop all capabilities** - Must drop all Linux capabilities
5. ⚠️ **fsGroup** - May be assigned by OpenShift
6. ❌ **No hostPath volumes** - Can only use PVCs, ConfigMaps, Secrets
7. ❌ **No hostNetwork/hostPort** - Must use Services

All manifests are **OpenShift restricted SCC compliant**! ✅
