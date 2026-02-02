#!/bin/bash
# Setup cron jobs for agents
# For RWO (ReadWriteOnce) PVCs - runs commands inside the existing pod

set -e

echo "🕐 Setting up cron jobs for agents..."
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

# Setup cron jobs
echo "2. Configuring cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node

echo "  Removing old cron jobs (if they exist)..."
node /app/dist/index.js cron delete philbot-daily-post 2>/dev/null || true
node /app/dist/index.js cron delete techbot-daily-post 2>/dev/null || true
node /app/dist/index.js cron delete poetbot-daily-post 2>/dev/null || true

echo ""
echo "  Creating cron jobs..."

# PhilBot - Daily at 9AM UTC
echo "    - PhilBot: Daily at 9AM UTC"
node /app/dist/index.js cron add \
  --name "philbot-daily-post" \
  --description "Daily philosophical post" \
  --agent "philbot" \
  --session "isolated" \
  --cron "0 9 * * *" \
  --tz "UTC" \
  --message "Read ~/.openclaw/workspace-philbot/.env for MOLTBOOK_API_KEY (dont paste it!). Read ~/.openclaw/skills/moltbook/SKILL.md. Create a thought-provoking philosophical question and post it to the philosophy submolt using curl with your API key." \
  --thinking "low" \
  >/dev/null || echo "      (already exists or failed)"

# TechBot - Daily at 10AM UTC
echo "    - TechBot: Daily at 10AM UTC"
node /app/dist/index.js cron add \
  --name "techbot-daily-post" \
  --description "Daily technology post" \
  --agent "techbot" \
  --session "isolated" \
  --cron "0 10 * * *" \
  --tz "UTC" \
  --message "Read ~/.openclaw/workspace-techbot/.env for MOLTBOOK_API_KEY (dont paste it!). Read ~/.openclaw/skills/moltbook/SKILL.md. Share an interesting tech insight or news and post it to the technology submolt using curl with your API key." \
  --thinking "low" \
  >/dev/null || echo "      (already exists or failed)"

# PoetBot - Daily at 2PM UTC
echo "    - PoetBot: Daily at 2PM UTC"
node /app/dist/index.js cron add \
  --name "poetbot-daily-post" \
  --description "Daily creative writing post" \
  --agent "poetbot" \
  --session "isolated" \
  --cron "0 14 * * *" \
  --tz "UTC" \
  --message "Read ~/.openclaw/workspace-poetbot/.env for MOLTBOOK_API_KEY (dont paste it!). Read ~/.openclaw/skills/moltbook/SKILL.md. Create a poem or creative writing piece and post it to the general submolt with title starting with Poetry: or Creative: using curl with your API key." \
  --thinking "low" \
  >/dev/null || echo "      (already exists or failed)"

echo ""
echo "✅ Cron jobs configured!"
'
echo ""

# List cron jobs to verify
echo "3. Verifying cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron list'
echo ""

echo "✅ Cron setup complete!"
echo ""
echo "Agents will autonomously post to Moltbook on their schedules:"
echo "  - PhilBot:  9AM UTC daily (philosophy)"
echo "  - TechBot: 10AM UTC daily (technology)"
echo "  - PoetBot:  2PM UTC daily (general)"
