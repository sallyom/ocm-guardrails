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

# Delete jobs files and clear all jobs
echo "2. Clearing existing cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node

# Delete jobs.json files first
echo "  Removing jobs files..."
rm -fv /home/node/.openclaw/cron/jobs* 2>&1 || echo "  No jobs files found"
'
echo ""

# Setup cron jobs
echo "3. Creating fresh cron jobs..."
cat <<'SETUP_SCRIPT' | oc exec -i -n openclaw $POD -c gateway -- bash
cd /home/node

echo "  Creating fresh cron jobs..."

# PhilBot - Daily at 9AM UTC
echo "    - PhilBot: Daily at 9AM UTC (philosophy)"
node /app/dist/index.js cron add \
  --name "philbot-daily-post" \
  --description "Daily philosophical post" \
  --agent "philbot" \
  --cron "0 9 * * *" \
  --tz "UTC" \
  --session "isolated" \
  --no-deliver \
  --message "CRITICAL: Run ALL steps in ONE command. NEVER expose credentials. Execute: . ~/.openclaw/workspace-philbot/.env && cat > /tmp/post.json <<'EOF' && curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H 'Authorization: Bearer \$MOLTBOOK_API_KEY' -H 'Content-Type: application/json' -d @/tmp/post.json && rm /tmp/post.json
{\"submolt\":\"philosophy\",\"title\":\"Daily Thought\",\"content\":\"[Your question]\\n\\n#philosophy\"}
EOF
" \
  --thinking "low"

# Audit Reporter - Every 6 hours
echo "    - Audit Reporter: Every 6 hours (compliance)"
node /app/dist/index.js cron add \
  --name "audit-reporter-scan" \
  --description "Compliance and governance audit scan" \
  --agent "audit_reporter" \
  --cron "0 */6 * * *" \
  --tz "UTC" \
  --session "isolated" \
  --no-deliver \
  --message "STEP 1: Run this command to get audit stats: . ~/.openclaw/workspace-audit-reporter/.env && curl -s \\\$MOLTBOOK_API_URL/api/v1/admin/audit/stats -H \"Authorization: Bearer \\\$MOLTBOOK_API_KEY\" > /tmp/stats.json. STEP 2: Run this to get recent logs: . ~/.openclaw/workspace-audit-reporter/.env && curl -s \\\$MOLTBOOK_API_URL/api/v1/admin/audit/logs?limit=50 -H \"Authorization: Bearer \\\$MOLTBOOK_API_KEY\" > /tmp/logs.json. STEP 3: Read /tmp/stats.json and /tmp/logs.json and analyze the REAL data. STEP 4: Create a detailed markdown report at ~/.openclaw/workspace-audit-reporter/reports/\\\$(date -u +\"%Y-%m-%d-%H%M\")-compliance-report.md with the ACTUAL findings from the JSON data. STEP 5: Use the moltbook skill to post a SHORT summary announcement to Moltbook. The skill has all the instructions - follow Step 3 in SKILL.md. Use real data, not placeholders!" \
  --thinking "low"

# Resource Optimizer - Daily at 8AM UTC
echo "    - Resource Optimizer: Daily at 8AM UTC (cost analysis)"
node /app/dist/index.js cron add \
  --name "resource-optimizer-scan" \
  --description "Daily cost optimization analysis" \
  --agent "resource_optimizer" \
  --cron "0 8 * * *" \
  --tz "UTC" \
  --session "isolated" \
  --no-deliver \
  --message "STEP 1: Set up K8s API access: . ~/.openclaw/workspace-resource-optimizer/.env && export K8S_API=https://kubernetes.default.svc && export CA_CERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt. STEP 2: Get pod metrics: curl -s -H \"Authorization: Bearer \\\$OC_TOKEN\" --cacert \\\$CA_CERT \\\$K8S_API/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods > /tmp/metrics.json. STEP 3: Get pod specs: curl -s -H \"Authorization: Bearer \\\$OC_TOKEN\" --cacert \\\$CA_CERT \\\$K8S_API/api/v1/namespaces/resource-demo/pods > /tmp/pods.json. STEP 4: Read /tmp/metrics.json and /tmp/pods.json and analyze REAL usage vs requests. STEP 5: Create detailed markdown report at ~/.openclaw/workspace-resource-optimizer/reports/\\\$(date -u +\"%Y-%m-%d-%H%M\")-cost-report.md with ACTUAL data and savings calculations. STEP 6: Use the moltbook skill to post a SHORT summary announcement. The skill has all the instructions - follow Step 3 in SKILL.md. Use real data!" \
  --thinking "low"

# MLOps Monitor - Every 4 hours
echo "    - MLOps Monitor: Every 4 hours (ML operations)"
node /app/dist/index.js cron add \
  --name "mlops-monitor-check" \
  --description "ML operations monitoring" \
  --agent "mlops_monitor" \
  --cron "0 */4 * * *" \
  --tz "UTC" \
  --session "isolated" \
  --no-deliver \
  --message "STEP 1: Check if MLFlow is accessible (if not, document that in report). STEP 2: If MLFlow exists, query experiment data. STEP 3: Check pod status with: kubectl get pods -n demo-mlflow-agent-tracing 2>/dev/null || echo \"No MLFlow namespace found\". STEP 4: Create a detailed markdown report at ~/.openclaw/workspace-mlops-monitor/reports/\\\$(date -u +\"%Y-%m-%d-%H%M\")-mlops-report.md documenting what you found (even if MLFlow is not deployed, that's a valid finding). STEP 5: Use the moltbook skill to post a SHORT summary announcement. The skill has all the instructions - follow Step 3 in SKILL.md. Document actual state!" \
  --thinking "low"

echo ""
echo "✅ Cron jobs configured!"
SETUP_SCRIPT
echo ""

# List cron jobs to verify
echo "4. Verifying cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron list'
echo ""

echo "✅ Cron setup complete!"
echo ""
echo "Enterprise DevOps agents will autonomously monitor and post to Moltbook:"
echo "  - PhilBot:            9AM UTC daily (philosophy submolt)"
echo "  - Audit Reporter:     Every 6 hours (compliance submolt)"
echo "  - Resource Optimizer: 8AM UTC daily (cost_resource_analysis submolt)"
echo "  - MLOps Monitor:      Every 4 hours (mlops submolt)"
