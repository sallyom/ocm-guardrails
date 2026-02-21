#!/usr/bin/env bash
# ============================================================================
# ADD AGENT SCAFFOLD
# ============================================================================
# Creates a new agent from the _template directory.
#
# Usage:
#   ./add-agent.sh                                    # Interactive prompts
#   ./add-agent.sh myagent "My Agent" "Description"   # Non-interactive
#
# This script:
#   - Copies _template/ to agents/<id>/
#   - Substitutes placeholders in the copied files
#   - Optionally creates a JOB.md for scheduled tasks
#   - Prints the config snippet to register the agent
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/manifests/openclaw/agents"
TEMPLATE_DIR="$AGENTS_DIR/_template"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Add OpenClaw Agent                                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ ! -d "$TEMPLATE_DIR" ]; then
  log_error "Template directory not found: $TEMPLATE_DIR"
  exit 1
fi

# Parse args or prompt
AGENT_ID="${1:-}"
DISPLAY_NAME="${2:-}"
DESCRIPTION="${3:-}"

if [ -z "$AGENT_ID" ]; then
  log_info "Agent ID (lowercase, no spaces — used in filenames and K8s names):"
  read -p "  ID: " AGENT_ID
  if [ -z "$AGENT_ID" ]; then
    log_error "Agent ID is required."
    exit 1
  fi
fi

# Normalize: lowercase, replace spaces with hyphens
AGENT_ID=$(echo "$AGENT_ID" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

if [ -d "$AGENTS_DIR/$AGENT_ID" ]; then
  log_error "Agent directory already exists: $AGENTS_DIR/$AGENT_ID"
  exit 1
fi

if [ -z "$DISPLAY_NAME" ]; then
  read -p "  Display name (e.g., 'Security Scanner'): " DISPLAY_NAME
  if [ -z "$DISPLAY_NAME" ]; then
    DISPLAY_NAME="$AGENT_ID"
  fi
fi

if [ -z "$DESCRIPTION" ]; then
  read -p "  Description (what does this agent do?): " DESCRIPTION
  if [ -z "$DESCRIPTION" ]; then
    DESCRIPTION="A custom OpenClaw agent"
  fi
fi

# Optional: emoji and color
read -p "  Emoji (default: 🤖): " EMOJI
EMOJI="${EMOJI:-🤖}"

read -p "  Color hex (default: #6C5CE7): " COLOR
COLOR="${COLOR:-#6C5CE7}"

echo ""

# Create agent directory
log_info "Creating agent: $AGENT_ID"
mkdir -p "$AGENTS_DIR/$AGENT_ID"

# Copy and customize the template
cp "$TEMPLATE_DIR/agent.yaml.template" "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"

# Substitute placeholders
sed -i.bak \
  -e "s/REPLACE_AGENT_ID/$AGENT_ID/g" \
  -e "s/REPLACE_DISPLAY_NAME/$DISPLAY_NAME/g" \
  -e "s/REPLACE_DESCRIPTION/$DESCRIPTION/g" \
  -e "s/REPLACE_EMOJI/$EMOJI/g" \
  -e "s/REPLACE_COLOR/$COLOR/g" \
  "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
rm -f "$AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst.bak"

log_success "Created $AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"

# Ask about scheduled job
echo ""
read -p "Does this agent need a scheduled job? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  cp "$TEMPLATE_DIR/JOB.md.template" "$AGENTS_DIR/$AGENT_ID/JOB.md"
  sed -i.bak "s/REPLACE_AGENT_ID/$AGENT_ID/g" "$AGENTS_DIR/$AGENT_ID/JOB.md"
  rm -f "$AGENTS_DIR/$AGENT_ID/JOB.md.bak"
  log_success "Created $AGENTS_DIR/$AGENT_ID/JOB.md"
  log_info "Edit JOB.md to set the schedule and job instructions"
fi

# Convert agent ID to underscore form for config (my-agent → my_agent)
AGENT_ID_UNDERSCORE=$(echo "$AGENT_ID" | tr '-' '_')

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Next Steps                                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "1. Edit the agent instructions:"
echo "   $AGENTS_DIR/$AGENT_ID/${AGENT_ID}-agent.yaml.envsubst"
echo ""
echo "2. Add this to agents-config-patch.yaml.envsubst (in the agents.list array):"
echo ""
echo "   {"
echo "     \"id\": \"\${OPENCLAW_PREFIX}_${AGENT_ID_UNDERSCORE}\","
echo "     \"name\": \"$DISPLAY_NAME\","
echo "     \"workspace\": \"~/.openclaw/workspace-\${OPENCLAW_PREFIX}_${AGENT_ID_UNDERSCORE}\","
echo "     \"subagents\": {\"allowAgents\": [\"*\"]}"
echo "   }"
echo ""
echo "3. Deploy:"
echo "   ./scripts/setup-agents.sh           # OpenShift"
echo "   ./scripts/setup-agents.sh --k8s     # Kubernetes"
echo ""
if [ -f "$AGENTS_DIR/$AGENT_ID/JOB.md" ]; then
  echo "4. After editing JOB.md, update jobs:"
  echo "   ./scripts/update-jobs.sh           # OpenShift"
  echo "   ./scripts/update-jobs.sh --k8s     # Kubernetes"
  echo ""
fi
