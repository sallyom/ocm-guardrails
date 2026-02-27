#!/usr/bin/env bash
# ============================================================================
# EDGE AGENT SETUP SCRIPT
# ============================================================================
# Run this ON the Linux machine that will be managed by the central gateway.
# Installs OpenClaw as a podman Quadlet (systemd-managed container).
#
# Usage:
#   ./setup-edge.sh                # Interactive setup
#   ./setup-edge.sh --uninstall    # Remove everything
#
# Prerequisites:
#   - Fedora 39+ / RHEL 9+ / CentOS Stream 9+
#   - podman (installed by default on Fedora/RHEL)
#   - SELinux enforcing (recommended, script verifies)
#
# What this script does:
#   1. Verifies prerequisites (podman, systemd, SELinux)
#   2. Prompts for configuration (model endpoint, agent name, OTEL)
#   3. Generates openclaw.json from template
#   4. Installs Quadlet files into ~/.config/containers/systemd/
#   5. Copies config into the podman volume
#   6. Pulls the container image
#   7. Enables lingering + reloads systemd (does NOT start the agent)
#
# After setup:
#   systemctl --user start openclaw-agent    # Start manually (or let supervisor do it)
#   journalctl --user -u openclaw-agent -f   # Watch logs
#   curl -H "Authorization: Bearer <token>" http://127.0.0.1:18789/v1/chat/completions
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Flags ──────────────────────────────────────────────────────────────────
UNINSTALL=false
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
  esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

# ── Uninstall ──────────────────────────────────────────────────────────────
if $UNINSTALL; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  OpenClaw Edge Agent — Uninstall                           ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  log_info "Stopping services..."
  systemctl --user stop openclaw-agent 2>/dev/null || true
  systemctl --user stop otel-collector 2>/dev/null || true

  log_info "Removing Quadlet files..."
  rm -f ~/.config/containers/systemd/openclaw-agent.container
  rm -f ~/.config/containers/systemd/openclaw-config.volume
  rm -f ~/.config/containers/systemd/otel-collector.container
  rm -f ~/.config/containers/systemd/otel-collector-config.volume

  log_info "Reloading systemd..."
  systemctl --user daemon-reload

  log_warn "Volume data preserved. To remove all data:"
  log_warn "  podman volume rm systemd-openclaw-config systemd-otel-collector-config"

  log_success "Uninstalled."
  exit 0
fi

# ── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Edge Agent Setup                                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────
log_info "Checking prerequisites..."

# podman
if ! command -v podman &> /dev/null; then
  log_error "podman not found. Install with: sudo dnf install -y podman"
  exit 1
fi
PODMAN_VERSION=$(podman --version | awk '{print $NF}')
log_success "podman $PODMAN_VERSION"

# systemd
if ! command -v systemctl &> /dev/null; then
  log_error "systemd not found. Quadlet requires systemd."
  exit 1
fi
log_success "systemd $(systemctl --version | head -1 | awk '{print $2}')"

# Quadlet support (podman 4.4+, rootless)
QUADLET_DIR="${HOME}/.config/containers/systemd"
if [ ! -d "$QUADLET_DIR" ]; then
  log_info "Creating $QUADLET_DIR..."
  mkdir -p "$QUADLET_DIR"
fi
log_success "Quadlet directory: $QUADLET_DIR"

# SELinux
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
if [ "$SELINUX_STATUS" = "Enforcing" ]; then
  log_success "SELinux: Enforcing"
elif [ "$SELINUX_STATUS" = "Permissive" ]; then
  log_warn "SELinux: Permissive (recommend Enforcing for production)"
else
  log_warn "SELinux: $SELINUX_STATUS"
fi

# Hostname
HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
log_success "Hostname: $HOSTNAME"

echo ""

# ── Load existing .env if re-running ───────────────────────────────────────
ENV_FILE="$EDGE_ROOT/.env.edge"
_ENV_REUSE=false
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  _ENV_REUSE=true
  log_success "Re-run detected — loading config from .env.edge"
  echo ""
fi

# ── Agent identity ─────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${AGENT_ID:-}" ]; then
  log_success "Agent ID: $AGENT_ID"
  log_success "Agent name: $AGENT_NAME"
else
  log_info "Agent identity for this machine:"
  echo ""

  DEFAULT_ID="edge_$(echo "$HOSTNAME" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')"
  read -p "  Agent ID [$DEFAULT_ID]: " AGENT_ID
  AGENT_ID="${AGENT_ID:-$DEFAULT_ID}"

  DEFAULT_NAME="$HOSTNAME Agent"
  read -p "  Agent display name [$DEFAULT_NAME]: " AGENT_NAME
  AGENT_NAME="${AGENT_NAME:-$DEFAULT_NAME}"
fi
echo ""

# ── Gateway token ──────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  log_success "Gateway token: (set)"
else
  OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
  log_success "Generated gateway token"
fi

# ── Model provider ─────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${MODEL_ENDPOINT:-}" ]; then
  log_success "Model endpoint: $MODEL_ENDPOINT"
  log_success "Model: $MODEL_NAME ($MODEL_ID)"
else
  log_info "Model provider configuration:"
  echo ""
  echo "  The edge agent needs access to an LLM. Options:"
  echo "    1. Local LLM (e.g., RHEL Lightspeed on this machine — localhost:8888)"
  echo "    2. Central model server (e.g., vLLM on OpenShift)"
  echo "    3. Cloud API (e.g., Anthropic, OpenAI)"
  echo ""

  read -p "  Model endpoint URL [http://127.0.0.1:8888/v1]: " MODEL_ENDPOINT
  MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://127.0.0.1:8888/v1}"

  read -p "  Model API type [openai-completions]: " MODEL_API
  MODEL_API="${MODEL_API:-openai-completions}"

  read -sp "  API key [fakekey]: " MODEL_API_KEY
  echo ""
  MODEL_API_KEY="${MODEL_API_KEY:-fakekey}"

  read -p "  Model ID [models/Phi-4-mini-instruct-Q4_K_M.gguf]: " MODEL_ID
  MODEL_ID="${MODEL_ID:-models/Phi-4-mini-instruct-Q4_K_M.gguf}"

  read -p "  Model display name [Phi-4 Mini]: " MODEL_NAME
  MODEL_NAME="${MODEL_NAME:-Phi-4 Mini}"
fi
echo ""

# ── Anthropic API key (optional) ──────────────────────────────────────────
if $_ENV_REUSE && [ -n "${ANTHROPIC_API_KEY+x}" ]; then
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    log_success "Anthropic API key: (set)"
  else
    log_success "Anthropic API key: (none)"
  fi
else
  log_info "Optional: provide an Anthropic API key for Claude."
  log_info "The local model remains available as fallback."
  echo ""
  read -sp "  Anthropic API key (leave empty to skip): " ANTHROPIC_API_KEY
  echo ""
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    log_success "Anthropic provider configured (Claude Sonnet 4.6)"
  fi
fi
echo ""

# ── OTEL (optional) ───────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OTEL_ENABLED:-}" ]; then
  log_success "OTEL: $OTEL_ENABLED"
  if [ "$OTEL_ENABLED" = "true" ]; then
    log_success "  MLflow endpoint: $MLFLOW_OTLP_ENDPOINT"
    log_success "  Collector image: $OTEL_COLLECTOR_IMAGE"
  fi
else
  log_info "OTEL observability (local collector forwards traces to central MLflow):"
  echo ""
  read -p "  Enable OTEL? [y/N]: " OTEL_ANSWER
  if [[ "${OTEL_ANSWER,,}" =~ ^y ]]; then
    OTEL_ENABLED="true"
    # OpenClaw agent always sends to localhost collector
    OTEL_ENDPOINT="http://127.0.0.1:4318"

    echo ""
    log_info "The local OTEL collector will forward traces to your MLflow instance."
    read -p "  MLflow OTLP endpoint (e.g., https://mlflow-route.apps.cluster.com): " MLFLOW_OTLP_ENDPOINT
    if [ -z "$MLFLOW_OTLP_ENDPOINT" ]; then
      log_error "MLflow endpoint is required when OTEL is enabled."
      exit 1
    fi

    read -p "  MLflow experiment ID [4]: " MLFLOW_EXPERIMENT_ID
    MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-4}"

    # TLS: if endpoint is HTTPS, use secure; if HTTP, insecure
    if [[ "$MLFLOW_OTLP_ENDPOINT" =~ ^https:// ]]; then
      MLFLOW_TLS_INSECURE="false"
    else
      MLFLOW_TLS_INSECURE="true"
    fi

    read -p "  OTEL collector image [ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest]: " OTEL_COLLECTOR_IMAGE
    OTEL_COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest}"
  else
    OTEL_ENABLED="false"
    OTEL_ENDPOINT="http://127.0.0.1:4318"
    MLFLOW_OTLP_ENDPOINT=""
    MLFLOW_EXPERIMENT_ID=""
    MLFLOW_TLS_INSECURE="true"
    OTEL_COLLECTOR_IMAGE=""
  fi
fi
echo ""

# ── Container images ──────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OPENCLAW_IMAGE:-}" ]; then
  log_success "Image: $OPENCLAW_IMAGE"
else
  read -p "  OpenClaw container image [quay.io/sallyom/openclaw:latest]: " OPENCLAW_IMAGE
  OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-quay.io/sallyom/openclaw:latest}"
fi
echo ""

# ── Save .env.edge ─────────────────────────────────────────────────────────
log_info "Saving configuration to .env.edge..."
cat > "$ENV_FILE" <<EOF
# OpenClaw Edge Agent Configuration
# Generated by setup-edge.sh — DO NOT COMMIT
AGENT_ID="$AGENT_ID"
AGENT_NAME="$AGENT_NAME"
OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"
MODEL_ENDPOINT="$MODEL_ENDPOINT"
MODEL_API="$MODEL_API"
MODEL_API_KEY="$MODEL_API_KEY"
MODEL_ID="$MODEL_ID"
MODEL_NAME="$MODEL_NAME"
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
OTEL_ENABLED="$OTEL_ENABLED"
OTEL_ENDPOINT="$OTEL_ENDPOINT"
MLFLOW_OTLP_ENDPOINT="$MLFLOW_OTLP_ENDPOINT"
MLFLOW_EXPERIMENT_ID="$MLFLOW_EXPERIMENT_ID"
MLFLOW_TLS_INSECURE="$MLFLOW_TLS_INSECURE"
OTEL_COLLECTOR_IMAGE="$OTEL_COLLECTOR_IMAGE"
OPENCLAW_IMAGE="$OPENCLAW_IMAGE"
EOF
log_success "Saved .env.edge"

# ── Generate openclaw.json ─────────────────────────────────────────────────
log_info "Generating openclaw.json..."

ENVSUBST_VARS='${AGENT_ID} ${AGENT_NAME} ${OPENCLAW_GATEWAY_TOKEN}'
ENVSUBST_VARS+=' ${MODEL_ENDPOINT} ${MODEL_API} ${MODEL_API_KEY} ${MODEL_ID} ${MODEL_NAME}'
ENVSUBST_VARS+=' ${OTEL_ENABLED} ${OTEL_ENDPOINT}'

export AGENT_ID AGENT_NAME OPENCLAW_GATEWAY_TOKEN
export MODEL_ENDPOINT MODEL_API MODEL_API_KEY MODEL_ID MODEL_NAME
export OTEL_ENABLED OTEL_ENDPOINT

GENERATED_CONFIG="$EDGE_ROOT/config/openclaw.json"
envsubst "$ENVSUBST_VARS" < "$EDGE_ROOT/config/openclaw.json.envsubst" > "$GENERATED_CONFIG"

# Inject extra provider if API key was provided
# The API key is passed via environment variable (not stored in config JSON)
# so the agent's exec sandbox can't access it — OpenClaw strips ANTHROPIC_API_KEY
# from child process environments (see sanitize-env-vars.ts)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  python3 -c "
import json
with open('$GENERATED_CONFIG') as f:
    config = json.load(f)
# Add anthropic provider with empty models list (uses built-in catalog)
config['models']['providers']['anthropic'] = {
    'baseUrl': 'https://api.anthropic.com',
    'api': 'anthropic-messages',
    'models': []
}
# Set default agent model to Anthropic, local model as fallback
config['agents']['defaults']['model'] = {
    'primary': 'anthropic/claude-sonnet-4-6',
    'fallbacks': ['default/$MODEL_ID']
}
for agent in config['agents']['list']:
    agent['model'] = {
        'primary': 'anthropic/claude-sonnet-4-6',
        'fallbacks': ['default/$MODEL_ID']
    }
with open('$GENERATED_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
"
  log_success "Anthropic provider added (key via env var, local model as fallback)"
fi
log_success "Generated config/openclaw.json"

# Generate OTEL collector config if enabled
if [ "$OTEL_ENABLED" = "true" ]; then
  OTEL_ENVSUBST_VARS='${HOSTNAME} ${MLFLOW_OTLP_ENDPOINT} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE}'
  export HOSTNAME MLFLOW_OTLP_ENDPOINT MLFLOW_EXPERIMENT_ID MLFLOW_TLS_INSECURE

  GENERATED_OTEL_CONFIG="$EDGE_ROOT/config/otel-collector-config.yaml"
  envsubst "$OTEL_ENVSUBST_VARS" < "$EDGE_ROOT/config/otel-collector-config.yaml.envsubst" > "$GENERATED_OTEL_CONFIG"
  log_success "Generated config/otel-collector-config.yaml"
fi

# ── Install Quadlet files ─────────────────────────────────────────────────
log_info "Installing Quadlet files..."

# Substitute the image and token into the container file
CONTAINER_FILE="$EDGE_ROOT/quadlet/openclaw-agent.container"
GENERATED_CONTAINER="/tmp/openclaw-agent.container"
sed \
  -e "s|Image=.*|Image=$OPENCLAW_IMAGE|" \
  -e "s|\${OPENCLAW_GATEWAY_TOKEN}|$OPENCLAW_GATEWAY_TOKEN|" \
  "$CONTAINER_FILE" > "$GENERATED_CONTAINER"

# Add API key as env var (not in config JSON — sanitized from exec sandbox)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  sed -i "/^Environment=NODE_ENV/a Environment=ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" "$GENERATED_CONTAINER"
fi

cp "$GENERATED_CONTAINER" "$QUADLET_DIR/openclaw-agent.container"
cp "$EDGE_ROOT/quadlet/openclaw-config.volume" "$QUADLET_DIR/openclaw-config.volume"
rm -f "$GENERATED_CONTAINER"

# Install OTEL collector Quadlet if enabled
if [ "$OTEL_ENABLED" = "true" ]; then
  OTEL_CONTAINER_FILE="$EDGE_ROOT/quadlet/otel-collector.container"
  GENERATED_OTEL_CONTAINER="/tmp/otel-collector.container"
  sed \
    -e "s|\${OTEL_COLLECTOR_IMAGE}|$OTEL_COLLECTOR_IMAGE|" \
    "$OTEL_CONTAINER_FILE" > "$GENERATED_OTEL_CONTAINER"

  cp "$GENERATED_OTEL_CONTAINER" "$QUADLET_DIR/otel-collector.container"
  cp "$EDGE_ROOT/quadlet/otel-collector-config.volume" "$QUADLET_DIR/otel-collector-config.volume"
  rm -f "$GENERATED_OTEL_CONTAINER"
fi

log_success "Installed Quadlet files to $QUADLET_DIR/"

# ── Copy config into volume ───────────────────────────────────────────────
log_info "Setting up config volume..."

# Create the volume if it doesn't exist
podman volume inspect systemd-openclaw-config &>/dev/null || \
  podman volume create systemd-openclaw-config

# Get the volume mount path
VOLUME_PATH=$(podman volume inspect systemd-openclaw-config --format '{{.Mountpoint}}')

# Copy config into the volume and fix ownership for rootless container (uid 1000)
podman unshare bash -c "mkdir -p '$VOLUME_PATH' && cp '$GENERATED_CONFIG' '$VOLUME_PATH/openclaw.json' && chown -R 1000:1000 '$VOLUME_PATH'"

# SELinux: relabel for container access
if [ "$SELINUX_STATUS" = "Enforcing" ] || [ "$SELINUX_STATUS" = "Permissive" ]; then
  # Rootless podman handles most labeling, but explicit relabel ensures access
  chcon -R -t container_file_t "$VOLUME_PATH" 2>/dev/null || true
  log_success "SELinux labels applied to volume"
fi

log_success "Config installed to $VOLUME_PATH/openclaw.json"

# Set up OTEL collector config volume if enabled
if [ "$OTEL_ENABLED" = "true" ]; then
  log_info "Setting up OTEL collector config volume..."

  podman volume inspect systemd-otel-collector-config &>/dev/null || \
    podman volume create systemd-otel-collector-config

  OTEL_VOLUME_PATH=$(podman volume inspect systemd-otel-collector-config --format '{{.Mountpoint}}')
  podman unshare bash -c "mkdir -p '$OTEL_VOLUME_PATH' && cp '$GENERATED_OTEL_CONFIG' '$OTEL_VOLUME_PATH/config.yaml'"

  if [ "$SELINUX_STATUS" = "Enforcing" ] || [ "$SELINUX_STATUS" = "Permissive" ]; then
    chcon -R -t container_file_t "$OTEL_VOLUME_PATH" 2>/dev/null || true
  fi

  log_success "OTEL collector config installed to $OTEL_VOLUME_PATH/config.yaml"
fi

# ── Pull images ────────────────────────────────────────────────────────────
log_info "Pulling container images (this may take a moment)..."
podman pull "$OPENCLAW_IMAGE"
log_success "Image pulled: $OPENCLAW_IMAGE"

if [ "$OTEL_ENABLED" = "true" ]; then
  podman pull "$OTEL_COLLECTOR_IMAGE"
  log_success "Image pulled: $OTEL_COLLECTOR_IMAGE"
fi

# ── Enable lingering ──────────────────────────────────────────────────────
# Required so user services survive logout (critical for SSH-activated agents)
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "yes"; then
  log_info "Enabling lingering for $USER (services persist after logout)..."
  sudo loginctl enable-linger "$USER"
  log_success "Lingering enabled"
else
  log_success "Lingering already enabled for $USER"
fi

# ── Reload systemd ────────────────────────────────────────────────────────
log_info "Reloading systemd..."
systemctl --user daemon-reload
log_success "systemd reloaded — Quadlet unit registered"

# ── Verify ─────────────────────────────────────────────────────────────────
echo ""
log_info "Verifying installation..."
if systemctl --user list-unit-files | grep -q openclaw-agent; then
  log_success "openclaw-agent.service is registered"
else
  log_warn "openclaw-agent.service not found — check Quadlet files in $QUADLET_DIR"
fi

AGENT_STATUS=$(systemctl --user is-active openclaw-agent 2>/dev/null || echo "inactive")
log_success "Agent status: $AGENT_STATUS (expected: inactive)"

if [ "$OTEL_ENABLED" = "true" ]; then
  if systemctl --user list-unit-files | grep -q otel-collector; then
    log_success "otel-collector.service is registered"
  else
    log_warn "otel-collector.service not found — check Quadlet files in $QUADLET_DIR"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Setup Complete                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Agent ID:     $AGENT_ID"
echo "  Agent name:   $AGENT_NAME"
echo "  Image:        $OPENCLAW_IMAGE"
echo "  SELinux:      $SELINUX_STATUS"
echo "  OTEL:         $OTEL_ENABLED"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "  MLflow:       $MLFLOW_OTLP_ENDPOINT"
echo "  Collector:    $OTEL_COLLECTOR_IMAGE"
fi
echo "  Gateway port: 18789 (loopback only)"
echo ""
echo "  Quadlet files:  $QUADLET_DIR/openclaw-agent.{container,volume}"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "                  $QUADLET_DIR/otel-collector.{container,volume}"
fi
echo "  Config:         $VOLUME_PATH/openclaw.json"
echo "  Saved settings: $ENV_FILE"
echo ""
echo "  Commands:"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    systemctl --user start otel-collector      # Start collector (before agent)"
fi
echo "    systemctl --user start openclaw-agent      # Start the agent"
echo "    systemctl --user stop openclaw-agent       # Stop the agent"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    systemctl --user stop otel-collector       # Stop collector"
fi
echo "    journalctl --user -u openclaw-agent -f     # Watch agent logs"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    journalctl --user -u otel-collector -f     # Watch collector logs"
fi
echo "    systemctl --user status openclaw-agent     # Check status"
echo ""
echo "  From the central supervisor (via SSH):"
echo "    ssh $(whoami)@$HOSTNAME 'systemctl --user start openclaw-agent'"
echo ""
