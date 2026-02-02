#!/bin/bash
# Install Moltbook skill into OpenClaw workspace
# For RWO (ReadWriteOnce) PVCs - runs from inside the pod

set -e

echo "🔧 Installing Moltbook skill..."
echo ""

# Deploy ConfigMap
echo "1. Deploying ConfigMap from SKILL.md..."
oc apply -k .
echo ""

# Get running pod
echo "2. Finding OpenClaw pod..."
POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw pod found"
  exit 1
fi
echo "   Found: $POD"
echo ""

# Copy skill to workspace
echo "3. Copying skill to OpenClaw skills directory..."
oc get configmap moltbook-skill -n openclaw -o jsonpath='{.data.SKILL\.md}' | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'mkdir -p /home/node/.openclaw/skills/moltbook && cat > /home/node/.openclaw/skills/moltbook/SKILL.md && chmod -R 775 /home/node/.openclaw/skills'
echo ""

# Verify
echo "4. Verifying installation..."
oc exec -n openclaw $POD -c gateway -- ls -la /home/node/.openclaw/skills/moltbook/
echo ""

# Check file content
FILE_SIZE=$(oc exec -n openclaw $POD -c gateway -- sh -c 'wc -c < /home/node/.openclaw/skills/moltbook/SKILL.md')
echo "   Skill file size: ${FILE_SIZE} bytes"
echo ""

echo "✅ Moltbook skill installed successfully!"
echo ""
echo "The skill is now available to all agents in OpenClaw."
