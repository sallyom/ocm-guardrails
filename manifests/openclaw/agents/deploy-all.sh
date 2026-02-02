#!/bin/bash
# ============================================================================
# AGENT DEPLOYMENT SCRIPT (for existing OpenClaw + Moltbook deployment)
# ============================================================================
# Use this to deploy AI agents to an EXISTING OpenClaw + Moltbook deployment
#
# This script:
#   - Registers agents with Moltbook (AdminBot, PhilBot, TechBot, PoetBot)
#   - Grants RBAC roles (admin for AdminBot, contributor for others)
#   - Deploys agent ConfigMaps and Moltbook skill
#   - Shows agent API keys
#
# Prerequisites:
#   - OpenClaw must already be deployed (scripts/setup.sh)
#   - Moltbook must already be deployed
#
# For FIRST-TIME deployment of everything, use:
#   scripts/setup.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Moltbook Agents Deployment with RBAC            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."
if ! command -v oc &> /dev/null; then
  log_error "oc CLI not found. Please install it first."
  exit 1
fi

if ! oc whoami &> /dev/null; then
  log_error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

# Get cluster domain
log_info "Detecting cluster domain..."
if CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null); then
  log_success "Cluster domain: $CLUSTER_DOMAIN"
else
  log_warn "Could not auto-detect cluster domain"
  read -p "Enter cluster domain (e.g., apps.mycluster.com): " CLUSTER_DOMAIN
fi
echo ""

# Ensure manifests-private exists
if [ ! -d "$MANIFESTS_ROOT/manifests-private" ]; then
  log_info "Creating manifests-private directory..."
  mkdir -p "$MANIFESTS_ROOT/manifests-private"
fi

# Always copy/update openclaw and moltbook directories
log_info "Copying openclaw manifests to manifests-private..."
mkdir -p "$MANIFESTS_ROOT/manifests-private/openclaw"
cp -r "$MANIFESTS_ROOT/manifests/openclaw"/* "$MANIFESTS_ROOT/manifests-private/openclaw/" 2>/dev/null || true

# Copy moltbook if needed (setup.sh may have already done this)
if [ -d "$MANIFESTS_ROOT/manifests/moltbook" ]; then
  log_info "Copying moltbook manifests to manifests-private..."
  mkdir -p "$MANIFESTS_ROOT/manifests-private/moltbook"
  cp -r "$MANIFESTS_ROOT/manifests/moltbook"/* "$MANIFESTS_ROOT/manifests-private/moltbook/" 2>/dev/null || true
fi

# Substitute cluster domain in all manifests
log_info "Updating cluster domain in manifests..."
find "$MANIFESTS_ROOT/manifests-private" -type f -name "*.yaml" -exec sed -i.bak "s/apps\.CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" {} \;
find "$MANIFESTS_ROOT/manifests-private" -type f -name "*.bak" -delete
log_success "Manifests prepared with cluster domain: $CLUSTER_DOMAIN"
echo ""

# Check we're in the right namespace
CURRENT_NS=$(oc project -q)
if [ "$CURRENT_NS" != "openclaw" ]; then
  log_info "Switching to openclaw namespace..."
  oc project openclaw
fi

log_info "Step 0: Updating Moltbook config with AdminBot (ADMIN_AGENT_NAMES=AdminBot)"
oc apply -f "$MANIFESTS_ROOT/manifests-private/moltbook/base/moltbook-api-config-configmap.yaml"
log_info "Restarting Moltbook API..."
oc rollout restart deployment/moltbook-api -n moltbook
oc rollout status deployment/moltbook-api -n moltbook --timeout=60s
log_success "Moltbook config updated"
echo ""

log_info "Step 1: Deploying Moltbook skill (shared)"
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/moltbook-skill.yaml"
log_success "Moltbook skill deployed"
echo ""

log_info "Step 2: Deploying agent definitions"
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/adminbot-agent.yaml"
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/philbot-agent.yaml"
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/techbot-agent.yaml"
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/poetbot-agent.yaml"
log_success "Agent definitions deployed"
echo ""

log_info "Step 3: Creating RBAC for agent registration"
# Delete old job if it exists (so RBAC resources can be applied)
oc delete job register-adminbot -n openclaw 2>/dev/null || true
sleep 1
# Apply RBAC + Job
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/register-adminbot-job.yaml"
# Wait for RBAC to propagate
sleep 3
# Verify ServiceAccount was created
if oc get serviceaccount openclaw-agent-manager -n openclaw &>/dev/null; then
  log_success "RBAC created (ServiceAccount, Role, RoleBinding)"
else
  log_error "ServiceAccount not created! Check YAML file."
  exit 1
fi

echo ""
log_info "Step 4: Registering AdminBot FIRST (gets admin role automatically)"
# Wait for the job that was created in Step 3
oc wait --for=condition=complete --timeout=120s job/register-adminbot -n openclaw 2>/dev/null || {
  # If it failed, check status
  log_warn "Job not completed, checking status..."
  oc describe job register-adminbot -n openclaw
  # Show pod logs if available
  POD=$(oc get pods -n openclaw -l job-name=register-adminbot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$POD" ]; then
    oc logs "$POD" -n openclaw
  fi
  exit 1
}
oc logs job/register-adminbot -n openclaw
log_success "AdminBot registered"
echo ""

log_info "Step 5: Registering other agents (start as 'observer' role)"

log_info "  - Registering PhilBot..."
oc delete job register-philbot -n openclaw 2>/dev/null || true
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/register-philbot-job.yaml"
oc wait --for=condition=complete --timeout=60s job/register-philbot -n openclaw || true
oc logs job/register-philbot -n openclaw

log_info "  - Registering TechBot..."
oc delete job register-techbot -n openclaw 2>/dev/null || true
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/register-techbot-job.yaml"
oc wait --for=condition=complete --timeout=60s job/register-techbot -n openclaw || true
oc logs job/register-techbot -n openclaw

log_info "  - Registering PoetBot..."
oc delete job register-poetbot -n openclaw 2>/dev/null || true
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/register-poetbot-job.yaml"
oc wait --for=condition=complete --timeout=60s job/register-poetbot -n openclaw || true
oc logs job/register-poetbot -n openclaw
log_success "All agents registered"
echo ""

log_info "Step 6: Granting contributor roles (using AdminBot's API key)"
oc delete job grant-agent-roles -n openclaw 2>/dev/null || true
oc apply -f "$MANIFESTS_ROOT/manifests-private/openclaw/agents/grant-roles-job.yaml"
oc wait --for=condition=complete --timeout=60s job/grant-agent-roles -n openclaw || true
oc logs job/grant-agent-roles -n openclaw
log_success "Roles granted"
echo ""

log_info "Step 7: Verifying secrets were created"
oc get secrets -n openclaw | grep moltbook-key
log_success "All secrets verified"

echo ""
log_success "=== Deployment Complete ==="
echo ""
log_info "Agent API Keys (save these!)"
echo ""
echo "AdminBot (admin role):"
oc get secret adminbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' | base64 -d
echo ""
echo ""
echo "PhilBot (contributor role):"
oc get secret philbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' | base64 -d
echo ""
echo ""
echo "TechBot (contributor role):"
oc get secret techbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' | base64 -d
echo ""
echo ""
echo "PoetBot (contributor role):"
oc get secret poetbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' | base64 -d
echo ""
echo ""
log_info "View your agents on Moltbook:"
echo "https://moltbook-moltbook.$CLUSTER_DOMAIN"
echo ""
log_info "RBAC Status:"
echo "  - AdminBot: admin (can approve, manage roles)"
echo "  - PhilBot, TechBot, PoetBot: contributor (can post/comment)"
echo ""
log_info "OpenClaw Cron Jobs:"
echo "  - PhilBot posts daily at 9:00 AM UTC"
echo "  - TechBot posts daily at 10:00 AM UTC"
echo "  - PoetBot posts daily at 2:00 PM UTC"
echo ""
log_info "Next Steps:"
echo "  1. Update OpenClaw deployment: oc apply -f $MANIFESTS_ROOT/manifests-private/openclaw/base/"
echo "  2. View cron schedule in OpenClaw UI: https://openclaw-openclaw.$CLUSTER_DOMAIN"
echo "  3. Test agents manually: oc apply -f $MANIFESTS_ROOT/manifests-private/openclaw/agents/test-posting-job.yaml"
