# A2A Infrastructure: SPIRE + Keycloak

OpenClaw's A2A (Agent-to-Agent) bridge uses **SPIRE** for workload identity
and **Keycloak** for OAuth token exchange. This directory contains everything
needed to set up these prerequisites.

## Architecture

```
┌─────────────┐     SPIFFE SVID      ┌──────────────┐
│ SPIRE Agent │ ──────────────────▶  │ OpenClaw Pod  │
│ (DaemonSet) │     (X.509 + JWT)    │  spiffe-helper│
└──────┬──────┘                      │  envoy-proxy  │
       │                             │  client-reg   │
       │ attests                     └──────┬────────┘
       │                                    │ token exchange
┌──────┴──────┐                      ┌──────▼────────┐
│ SPIRE Server│                      │   Keycloak    │
│ (StatefulSet)                      │   (realm)     │
└─────────────┘                      └───────────────┘
```

1. **SPIRE** issues each OpenClaw pod a SPIFFE identity (SVID)
2. The **client-registration** sidecar registers the pod with Keycloak using its SPIFFE ID
3. The **envoy-proxy** sidecar transparently exchanges SPIFFE JWTs for Keycloak OAuth tokens on outbound requests
4. Remote agents verify the OAuth token, establishing mutual trust

## Prerequisites

- **Keycloak**: Installed via RHBK operator (OpenShift) or standalone deployment
- **Cluster admin**: Required for SPIRE CRDs, DaemonSets, and ClusterSPIFFEID
- **Helm 3**: For SPIRE chart installation

## Automated Setup

```bash
./setup-a2a-infra.sh \
  --keycloak-url https://keycloak.example.com \
  --keycloak-admin-user admin \
  --keycloak-admin-password <password>
```

### All flags

| Flag | Default | Description |
|------|---------|-------------|
| `--keycloak-url` | *(prompted)* | Keycloak base URL |
| `--keycloak-admin-user` | `admin` | Keycloak admin username |
| `--keycloak-admin-password` | *(prompted)* | Keycloak admin password |
| `--keycloak-realm` | `spiffe-demo` | Realm name to create/use |
| `--trust-domain` | `demo.example.com` | SPIFFE trust domain |
| `--cluster-name` | `spiffe-demo` | SPIRE cluster identifier |
| `--spire-namespace` | `spire-system` | Namespace for SPIRE components |
| `--ca-org` | `SPIFFE Demo` | CA certificate organization |
| `--ca-country` | `US` | CA certificate country |
| `--k8s` | *(off)* | Use `kubectl` instead of `oc` |
| `--dry-run` | *(off)* | Print commands without executing |

### Environment variables

All flags can also be set via environment variables:

```bash
export TRUST_DOMAIN=mycompany.example.com
export KEYCLOAK_REALM=my-realm
export KEYCLOAK_URL=https://keycloak.example.com
./setup-a2a-infra.sh
```

## Manual Setup

### 1. Install SPIRE

```bash
# Create namespace
oc create namespace spire-system

# Install CRDs
helm install spire-crds spire-crds \
  --repo https://spiffe.github.io/helm-charts-hardened/ \
  --version 0.5.0 \
  -n spire-system

# Install SPIRE (edit values.yaml first if customizing)
helm install spire spire \
  --repo https://spiffe.github.io/helm-charts-hardened/ \
  --version 0.27.1 \
  -n spire-system \
  -f spire/values.yaml

# Wait for ready
oc rollout status statefulset/spire-server -n spire-system --timeout=120s
oc rollout status daemonset/spire-agent -n spire-system --timeout=120s
```

### 2. Apply ClusterSPIFFEID

This tells SPIRE to issue identities to OpenClaw pods:

```bash
oc apply -f spire/clusterspiffeid.yaml
```

The ClusterSPIFFEID matches pods labeled `kagenti.io/type: agent` in namespaces
labeled `agentcard: true`. SPIFFE IDs follow the pattern:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

### 3. Configure Keycloak

#### Create the realm

1. Open the Keycloak admin console
2. Create a new realm named `spiffe-demo` (or your chosen name)
3. Set **SSL required** to `none` (for development) or `external` (for production)

#### Enable token exchange

Token exchange (RFC 8693) allows the envoy sidecar to swap a SPIFFE JWT
for a Keycloak OAuth access token.

1. Go to **Realm Settings** > **General**
2. Verify the realm is enabled

> **Note:** In Keycloak 26+, token exchange is enabled per-client via the
> `standard.token.exchange.enabled` attribute. The client-registration
> sidecar sets this automatically when it registers.

#### Enable dynamic client registration

The client-registration sidecar registers each OpenClaw pod as a Keycloak
client using its SPIFFE ID as the `clientId`. This requires anonymous or
authenticated client registration to be enabled.

1. Go to **Realm Settings** > **Client Registration** > **Client Registration Policies**
2. Under **Anonymous Access Policies**, configure:
   - **Max Clients**: 200 (or higher for large deployments)
   - **Allowed Protocol Mappers**: leave permissive or add needed types

#### Create the groups scope (optional)

If you want group membership in tokens:

1. Go to **Client Scopes** > **Create**
2. Name: `groups`, Protocol: `openid-connect`
3. Add a mapper: type **Group Membership**, claim name `groups`, full path `false`
4. Set as a default scope in **Realm Settings** > **Client Scopes** > **Default Client Scopes**

## Verification

### SPIRE

```bash
# Check SPIRE server is running
oc get pods -n spire-system

# Check agents are running on all nodes
oc get daemonset spire-agent -n spire-system

# Check ClusterSPIFFEID is active
oc get clusterspiffeid agentcard-agents -o yaml

# Check registration entries (after deploying OpenClaw with --with-a2a)
oc exec -n spire-system statefulset/spire-server -- \
  /opt/spire/bin/spire-server entry show
```

### Keycloak

```bash
# Verify realm is accessible
curl -sk https://<keycloak-url>/realms/<realm>/.well-known/openid-configuration | python3 -m json.tool

# Check token endpoint works
curl -sk -X POST https://<keycloak-url>/realms/<realm>/protocol/openid-connect/token \
  -d "grant_type=client_credentials" \
  -d "client_id=<spiffe-client-id>" \
  -d "client_secret=<secret>"
```

### End-to-end

After deploying OpenClaw with `--with-a2a`:

```bash
# Check that spiffe-helper has a valid SVID
oc exec deployment/openclaw -c spiffe-helper -- ls -la /opt/svid.pem

# Check that client-registration completed
oc logs deployment/openclaw -c client-registration

# Check that envoy-proxy is running
oc logs deployment/openclaw -c envoy-proxy --tail=5
```

## Customization

### Trust domain

The trust domain is the root of all SPIFFE IDs. Choose something meaningful
for your organization:

```bash
./setup-a2a-infra.sh --trust-domain mycompany.example.com
```

This affects the SPIFFE ID pattern: `spiffe://mycompany.example.com/ns/<ns>/sa/<sa>`

Update your OpenClaw deployment's `authbridge-secret.yaml.envsubst` if you
change this from the default.

### CA subject

Customize the SPIRE CA certificate:

```bash
./setup-a2a-infra.sh --ca-org "My Company" --ca-country "DE"
```

### Using a different Keycloak realm

```bash
./setup-a2a-infra.sh --keycloak-realm my-agents
```

Then set `KEYCLOAK_REALM=my-agents` in your OpenClaw `.env`.

## Teardown

```bash
# Remove ClusterSPIFFEID
oc delete clusterspiffeid agentcard-agents

# Uninstall SPIRE
helm uninstall spire -n spire-system
helm uninstall spire-crds -n spire-system

# Remove namespace
oc delete namespace spire-system

# Keycloak realm (via admin API)
KC_TOKEN=$(curl -sk -X POST https://<keycloak>/realms/master/protocol/openid-connect/token \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=<pass>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sk -X DELETE -H "Authorization: Bearer $KC_TOKEN" \
  https://<keycloak>/admin/realms/<realm>
```

## File Reference

| File | Purpose |
|------|---------|
| `spire/values.yaml` | Helm values for SPIRE chart (v0.27.1) |
| `spire/clusterspiffeid.yaml` | Workload registration for OpenClaw pods |
| `keycloak/realm-config.json` | Realm template for automated import |
| `setup-a2a-infra.sh` | Automated setup script |
