#!/usr/bin/env bash
# ============================================================================
# UPDATE OPENCLAW INTERNAL CRON JOBS
# ============================================================================
# Discovers JOB.md files in agents/openclaw/agents/*/JOB.md and writes
# OpenClaw's internal cron/jobs.json to the pod.
#
# JOB.md format:
#   ---
#   id: my-job-id
#   schedule: "0 9 * * *"
#   tz: UTC
#   ---
#   Message body (sent to the agent when the job fires)
#
# The agent ID is derived from the directory name:
#   resource-optimizer/ → ${OPENCLAW_PREFIX}_resource_optimizer
#
# Usage:
#   ./update-jobs.sh                  # OpenShift (default)
#   ./update-jobs.sh --k8s            # Vanilla Kubernetes
#   ./update-jobs.sh --skip-restart   # Write files but don't restart gateway
#   ./update-jobs.sh --dry-run        # Print jobs.json without writing
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
SKIP_RESTART=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --k8s) KUBECTL="${KUBECTL:-kubectl}" ;;
    --skip-restart) SKIP_RESTART=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

KUBECTL="${KUBECTL:-oc}"

# Colors
GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
YELLOW="${YELLOW:-\033[0;33m}"
RED="${RED:-\033[0;31m}"
NC="${NC:-\033[0m}"

# Log functions (define if not inherited from parent)
if ! declare -f log_info >/dev/null 2>&1; then
  log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
  log_success() { echo -e "${GREEN}✅ $1${NC}"; }
  log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
  log_error()   { echo -e "${RED}❌ $1${NC}"; }
fi

# Load env if not already set (standalone mode)
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Update OpenClaw Cron Jobs                                 ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  if [ ! -f "$REPO_ROOT/.env" ]; then
    log_error "No .env file found. Run setup.sh first."
    exit 1
  fi

  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a

  for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE SHADOWMAN_CUSTOM_NAME; do
    if [ -z "${!var:-}" ]; then
      log_error "$var not set in .env"
      exit 1
    fi
  done
fi

# ---- Discover JOB.md files ----

AGENTS_DIR="$REPO_ROOT/agents/openclaw/agents"
JOB_FILES=()

for job_file in "$AGENTS_DIR"/*/JOB.md; do
  [ -f "$job_file" ] || continue
  JOB_FILES+=("$job_file")
done

if [ ${#JOB_FILES[@]} -eq 0 ]; then
  log_warn "No JOB.md files found in $AGENTS_DIR/*/JOB.md"
  exit 0
fi

log_info "Found ${#JOB_FILES[@]} job(s):"

# ---- Parse JOB.md files and build jobs array ----

# Parse a frontmatter field from a JOB.md file
# Usage: parse_frontmatter "file" "field"
parse_frontmatter() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/{
    /^'"$field"':/{ s/^'"$field"': *//; s/^"//; s/"$//; p; }
  }' "$file" | head -1
}

# Extract body (everything after the second ---)
parse_body() {
  local file="$1"
  sed -n '/^---$/,/^---$/!p' "$file" | sed '/./,$!d'
}

JOBS_JSON=""
FIRST=true

for job_file in "${JOB_FILES[@]}"; do
  # Derive agent ID from directory name (resource-optimizer → resource_optimizer)
  dir_name=$(basename "$(dirname "$job_file")")
  agent_id="${OPENCLAW_PREFIX}_$(echo "$dir_name" | tr '-' '_')"

  # Parse frontmatter
  job_id=$(parse_frontmatter "$job_file" "id")
  schedule=$(parse_frontmatter "$job_file" "schedule")
  tz=$(parse_frontmatter "$job_file" "tz")

  # Validate required fields
  if [ -z "$job_id" ] || [ -z "$schedule" ]; then
    log_warn "  Skipping $job_file — missing 'id' or 'schedule' in frontmatter"
    continue
  fi

  tz="${tz:-UTC}"

  # Extract and envsubst the message body
  raw_body=$(parse_body "$job_file")
  # Collapse multi-line body into single line for JSON, preserving sentence boundaries
  message=$(echo "$raw_body" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  # Run envsubst to resolve ${OPENCLAW_PREFIX}, ${SHADOWMAN_CUSTOM_NAME}, etc.
  message=$(echo "$message" | envsubst '${OPENCLAW_PREFIX} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME}')

  # Escape for JSON
  message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')

  log_info "  $job_id ($dir_name) → schedule: $schedule"

  # Build JSON entry
  if ! $FIRST; then
    JOBS_JSON+=","
  fi
  FIRST=false

  JOBS_JSON+="
    {
      \"id\": \"$job_id\",
      \"agentId\": \"$agent_id\",
      \"schedule\": {\"kind\": \"cron\", \"expr\": \"$schedule\", \"tz\": \"$tz\"},
      \"sessionTarget\": \"isolated\",
      \"delivery\": { \"mode\": \"none\" },
      \"wakeMode\": \"now\",
      \"payload\": {
        \"kind\": \"agentTurn\",
        \"message\": \"$message\"
      }
    }"
done

FULL_JSON="{
  \"version\": 1,
  \"jobs\": [$JOBS_JSON
  ]
}"

# ---- Write or print ----

if $DRY_RUN; then
  echo ""
  echo "$FULL_JSON"
  echo ""
  exit 0
fi

log_info "Writing OpenClaw cron jobs..."

echo "$FULL_JSON" | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sh -c 'mkdir -p /home/node/.openclaw/cron && cat > /home/node/.openclaw/cron/jobs.json'

log_success "Cron jobs written"
echo ""

# ---- Restart gateway to reload (unless caller handles it) ----

if ! $SKIP_RESTART; then
  log_info "Restarting OpenClaw to load updated jobs..."
  $KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
  $KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
  log_success "Done — jobs updated and loaded"
  echo ""
fi
