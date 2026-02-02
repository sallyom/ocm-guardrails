#!/bin/bash
# Setup agents in OpenClaw workspace
# Runs commands inside the existing pod via oc exec

set -e

echo "🔧 Setting up agents in OpenClaw..."
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

# Setup agent directories and copy files
echo "2. Setting up agent workspaces (OpenClaw default paths)..."
oc exec -n openclaw $POD -c gateway -- sh -c '
  set -e
  echo "  Creating agent workspace directories..."
  mkdir -p ~/.openclaw/workspace-philbot
  mkdir -p ~/.openclaw/workspace-techbot
  mkdir -p ~/.openclaw/workspace-poetbot
  mkdir -p ~/.openclaw/workspace-adminbot
  mkdir -p ~/.openclaw/skills/moltbook

  echo "  Setting permissions..."
  chmod -R 775 ~/.openclaw/workspace-*
  chmod -R 775 ~/.openclaw/skills

  echo "  ✅ Agent workspace directories created"
'
echo ""

# Create .env files with API keys from secrets
echo "3. Creating .env files with API keys..."

# Get API keys from secrets
PHILBOT_KEY=$(oc get secret philbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
TECHBOT_KEY=$(oc get secret techbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
POETBOT_KEY=$(oc get secret poetbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
ADMINBOT_KEY=$(oc get secret adminbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")

# Create philbot .env
if [ -n "$PHILBOT_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-philbot/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$PHILBOT_KEY
AGENT_NAME=PhilBot
EOF
  echo "   ✅ PhilBot .env created"
else
  echo "   ⚠️  PhilBot API key not found - skipping"
fi

# Create techbot .env
if [ -n "$TECHBOT_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-techbot/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$TECHBOT_KEY
AGENT_NAME=TechBot
EOF
  echo "   ✅ TechBot .env created"
else
  echo "   ⚠️  TechBot API key not found - skipping"
fi

# Create poetbot .env
if [ -n "$POETBOT_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-poetbot/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$POETBOT_KEY
AGENT_NAME=PoetBot
EOF
  echo "   ✅ PoetBot .env created"
else
  echo "   ⚠️  PoetBot API key not found - skipping"
fi

# Create adminbot .env
if [ -n "$ADMINBOT_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-adminbot/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$ADMINBOT_KEY
AGENT_NAME=AdminBot
EOF
  echo "   ✅ AdminBot .env created"
else
  echo "   ⚠️  AdminBot API key not found - skipping"
fi

echo ""

# Copy agent ConfigMaps into workspace
echo "4. Copying agent AGENTS.md and agent.json files..."

# PhilBot
oc get configmap philbot-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-philbot/AGENTS.md' && \
  echo "   ✅ PhilBot AGENTS.md copied" || echo "   ⚠️  PhilBot ConfigMap not found"

oc get configmap philbot-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-philbot/agent.json' && \
  echo "   ✅ PhilBot agent.json copied" || echo "   ⚠️  PhilBot agent.json not found"

# TechBot
oc get configmap techbot-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-techbot/AGENTS.md' && \
  echo "   ✅ TechBot AGENTS.md copied" || echo "   ⚠️  TechBot ConfigMap not found"

oc get configmap techbot-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-techbot/agent.json' && \
  echo "   ✅ TechBot agent.json copied" || echo "   ⚠️  TechBot agent.json not found"

# PoetBot
oc get configmap poetbot-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-poetbot/AGENTS.md' && \
  echo "   ✅ PoetBot AGENTS.md copied" || echo "   ⚠️  PoetBot ConfigMap not found"

oc get configmap poetbot-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-poetbot/agent.json' && \
  echo "   ✅ PoetBot agent.json copied" || echo "   ⚠️  PoetBot agent.json not found"

# AdminBot
oc get configmap adminbot-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-adminbot/AGENTS.md' && \
  echo "   ✅ AdminBot AGENTS.md copied" || echo "   ⚠️  AdminBot ConfigMap not found"

oc get configmap adminbot-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > /home/node/.openclaw/workspace-adminbot/agent.json' && \
  echo "   ✅ AdminBot agent.json copied" || echo "   ⚠️  AdminBot agent.json not found"

echo ""

# Verify
echo "5. Verifying agent workspaces..."
oc exec -n openclaw $POD -c gateway -- ls -la /home/node/.openclaw/ | grep workspace
echo ""

echo "✅ Agent setup complete!"
echo ""
echo "Next steps:"
echo "  1. Apply agents-config-patch.yaml to add agents to OpenClaw config"
echo "  2. Restart OpenClaw: oc rollout restart deployment/openclaw -n openclaw"
echo "  3. Setup cron jobs after OpenClaw restarts"
