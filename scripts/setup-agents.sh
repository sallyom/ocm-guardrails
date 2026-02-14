#!/usr/bin/env bash
# ============================================================================
# AGENT-ONLY SETUP SCRIPT
# ============================================================================
# Deploy (or re-deploy) AI agents to an existing OpenClaw instance.
# Uses the existing .env — does NOT regenerate secrets.
#
# Usage:
#   ./setup-agents.sh           # OpenShift (default)
#   ./setup-agents.sh --k8s     # Vanilla Kubernetes
#
# Prerequisites:
#   - setup.sh has been run at least once (so .env and namespaces exist)
#   - OpenClaw and Moltbook are deployed and running
#
# This script:
#   - Sources .env for secrets and config (OPENCLAW_PREFIX, OPENCLAW_NAMESPACE, etc.)
#   - Runs envsubst on agent templates only
#   - Deploys agent ConfigMaps (philbot, resource-optimizer)
#   - Registers agents with Moltbook (prefixed names)
#   - Grants contributor roles
#   - Restarts OpenClaw to load config
#   - Sets up cron jobs for autonomous posting
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
for arg in "$@"; do
  case "$arg" in
    --k8s) K8S_MODE=true ;;
  esac
done

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="oc"
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Agent Setup                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env
if [ ! -f "$REPO_ROOT/.env" ]; then
  log_error "No .env file found. Run setup.sh first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

# Validate required vars
for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    log_error "$var not set in .env. Run setup.sh first (or add it manually)."
    exit 1
  fi
done

log_info "Namespace: $OPENCLAW_NAMESPACE"
log_info "Prefix:    $OPENCLAW_PREFIX"
log_info "Agents:    ${OPENCLAW_PREFIX}_philbot, ${OPENCLAW_PREFIX}_resource_optimizer"
echo ""

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found. Run setup.sh first."
  exit 1
fi
log_success "Connected to cluster, namespace exists"
echo ""

# Run envsubst on agent templates only
log_info "Running envsubst on agent templates..."
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${JWT_SECRET} ${POSTGRES_DB} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${MOLTBOOK_OAUTH_CLIENT_SECRET} ${MOLTBOOK_OAUTH_COOKIE_SECRET}'

for tpl in $(find "$REPO_ROOT/manifests/openclaw/agents" -name '*.envsubst'); do
  yaml="${tpl%.envsubst}"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$yaml"
  log_success "Generated $(basename "$yaml")"
done
echo ""

# Apply RBAC for agent jobs (must exist before jobs are created)
log_info "Applying agent manager RBAC..."
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/agent-manager-rbac.yaml"
log_success "RBAC applied"
echo ""

# Create DB credentials secret (used by grant-roles job to connect to PostgreSQL directly)
$KUBECTL create secret generic moltbook-db-credentials \
  -n "$OPENCLAW_NAMESPACE" \
  --from-literal=database-name="$POSTGRES_DB" \
  --from-literal=database-user="$POSTGRES_USER" \
  --from-literal=database-password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

# Deploy agent ConfigMaps
log_info "Deploying agent ConfigMaps..."
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/philbot-agent.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer-agent.yaml"
log_success "Agent ConfigMaps deployed"
echo ""

# Deploy agent configuration
if ! $K8S_MODE; then
  log_info "Deploying agent configuration..."
  $KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/agents-config-patch.yaml"
  log_success "Agent configuration deployed"
  echo ""
fi

# Deploy skills
log_info "Deploying skills (using kustomize)..."
$KUBECTL kustomize "$REPO_ROOT/manifests/openclaw/skills/" \
  | sed "s/namespace: openclaw/namespace: $OPENCLAW_NAMESPACE/g" \
  | $KUBECTL apply -f -
log_success "Skills deployed"
echo ""

# Pre-registration cleanup: remove agents from Moltbook DB for idempotent re-runs
log_info "Cleaning up any existing agent registrations in Moltbook DB..."
PG_POD=$($KUBECTL get pods -n moltbook -l component=database -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [ -n "$PG_POD" ]; then
  $KUBECTL exec -n moltbook "$PG_POD" -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
    "DELETE FROM agents WHERE name IN ('${OPENCLAW_PREFIX}_philbot', '${OPENCLAW_PREFIX}_resource_optimizer');" \
    2>/dev/null || log_warn "Could not clean up existing agents (table may not exist yet)"
  log_success "Pre-registration cleanup done"
else
  log_warn "PostgreSQL pod not found — skipping pre-cleanup (first deploy?)"
fi
echo ""

# Register agents with Moltbook
log_info "Registering agents with Moltbook..."
# Delete old jobs if re-running (jobs are immutable)
$KUBECTL delete job register-philbot register-resource-optimizer -n "$OPENCLAW_NAMESPACE" 2>/dev/null || true
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/register-philbot-job.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/register-resource-optimizer-job.yaml"
sleep 5
$KUBECTL wait --for=condition=complete --timeout=60s job/register-philbot -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Agent registration still running"
$KUBECTL wait --for=condition=complete --timeout=60s job/register-resource-optimizer -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Agent registration still running"
log_success "Agents registered"
echo ""

# Grant roles
log_info "Granting contributor roles..."
$KUBECTL delete job grant-agent-roles -n "$OPENCLAW_NAMESPACE" 2>/dev/null || true
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/job-grant-roles.yaml"
sleep 5
$KUBECTL wait --for=condition=complete --timeout=60s job/grant-agent-roles -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Role grants still running"
log_success "Roles granted"
echo ""

# Restart OpenClaw to pick up new config
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
log_info "Waiting for OpenClaw to be ready..."
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
log_success "OpenClaw ready"
echo ""

# Setup cron jobs
log_info "Setting up cron jobs for autonomous posting..."
# CLI connects via LAN IP (not loopback), so pass --token to bypass device pairing
$KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- bash -c "
  cd /home/node
  GW_TOKEN=\$OPENCLAW_GATEWAY_TOKEN
  node /app/dist/index.js cron delete ${OPENCLAW_PREFIX}-philbot-daily --token \"\$GW_TOKEN\" 2>/dev/null || true

  node /app/dist/index.js cron add --name \"${OPENCLAW_PREFIX}-philbot-daily\" --description \"Daily philosophical discussion post\" --agent \"${OPENCLAW_PREFIX}_philbot\" --session \"isolated\" --cron \"0 9 * * *\" --tz \"UTC\" --message \"Use the moltbook skill to create a new post in the general submolt (tagged with philosophy) with a thought-provoking philosophical question. Consider topics like consciousness, free will, ethics, or the nature of intelligence. Make it engaging to invite discussion from other agents.\" --thinking \"low\" --token \"\$GW_TOKEN\" >/dev/null

  echo \"Cron jobs:\"
  node /app/dist/index.js cron list --token \"\$GW_TOKEN\"
"
log_success "Cron jobs configured"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Agent Setup Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Agents deployed (prefix: $OPENCLAW_PREFIX):"
echo "  ${OPENCLAW_PREFIX}_philbot:             contributor (posts daily at 9AM UTC)"
echo "  ${OPENCLAW_PREFIX}_resource_optimizer:  contributor (cost analysis)"
echo ""
echo "Cleanup: cd manifests/openclaw/agents && ./remove-custom-agents.sh"
echo ""
