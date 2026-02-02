#!/bin/bash
# Remove custom agents from OpenClaw
# Keeps: Shadowman, secrets, Moltbook registrations
# Removes: Agent configs, workspace files, cron jobs

set -e

echo "🧹 Removing custom agents from OpenClaw..."
echo ""

# Get running pod
echo "1. Finding OpenClaw pod..."
POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw pod found"
  exit 1
fi
echo "   Found: $POD"
echo ""

# Remove cron jobs
echo "2. Removing cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node
echo "   - Deleting philbot-daily-post..."
node /app/dist/index.js cron delete philbot-daily-post 2>/dev/null || echo "     (not found)"
echo "   - Deleting techbot-daily-post..."
node /app/dist/index.js cron delete techbot-daily-post 2>/dev/null || echo "     (not found)"
echo "   - Deleting poetbot-daily-post..."
node /app/dist/index.js cron delete poetbot-daily-post 2>/dev/null || echo "     (not found)"
'
echo "   ✅ Cron jobs removed"
echo ""

# Remove agent workspace directories
echo "3. Removing agent workspace directories..."
oc exec -n openclaw $POD -c gateway -- sh -c '
  echo "   - Removing workspace-philbot..."
  rm -rf ~/.openclaw/workspace-philbot 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-techbot..."
  rm -rf ~/.openclaw/workspace-techbot 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-poetbot..."
  rm -rf ~/.openclaw/workspace-poetbot 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-adminbot..."
  rm -rf ~/.openclaw/workspace-adminbot 2>/dev/null || echo "     (not found)"
'
echo "   ✅ Agent workspaces removed"
echo ""

# Apply base config (shadowman only)
echo "4. Applying base config (shadowman only)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
oc apply -f "$SCRIPT_DIR/../base/openclaw-config-configmap.yaml"
echo "   ✅ Config updated to shadowman only"
echo ""

# Restart deployment
echo "5. Restarting OpenClaw deployment..."
oc rollout restart deployment/openclaw -n openclaw
echo "   ✅ Deployment restarting"
echo ""

echo "✅ Custom agents removed successfully!"
echo ""
echo "Remaining:"
echo "  - ✅ Shadowman agent (active)"
echo "  - ✅ Agent secrets (kept for future use)"
echo "  - ✅ Moltbook registrations (agents still registered)"
echo ""
echo "Removed:"
echo "  - ❌ PhilBot, TechBot, PoetBot, AdminBot (from OpenClaw UI)"
echo "  - ❌ Agent workspace directories"
echo "  - ❌ Cron jobs"
echo ""
echo "To re-add agents, run: ./setup-agent-workspaces.sh && oc apply -f agents-config-patch.yaml"
