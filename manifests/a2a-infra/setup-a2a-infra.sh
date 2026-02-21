#!/usr/bin/env bash
# ============================================================================
# A2A INFRASTRUCTURE SETUP
# ============================================================================
# Installs SPIRE and configures Keycloak for OpenClaw A2A mutual
# authentication. Run this ONCE per cluster before deploying OpenClaw
# with --with-a2a.
#
# Prerequisites:
#   - helm CLI installed
#   - oc or kubectl with cluster-admin access
#   - Keycloak running and accessible (operator or standalone)
#
# Usage:
#   ./setup-a2a-infra.sh \
#     --keycloak-url https://keycloak.example.com \
#     --keycloak-admin-user admin \
#     --keycloak-admin-password <password>
#
#   ./setup-a2a-infra.sh --k8s ...   # Vanilla Kubernetes (default: OpenShift)
#   ./setup-a2a-infra.sh --dry-run   # Show what would be done
#
# Configurable:
#   --trust-domain        SPIFFE trust domain (default: demo.example.com)
#   --cluster-name        SPIRE cluster name  (default: spiffe-demo)
#   --spire-namespace     Namespace for SPIRE (default: spire-system)
#   --keycloak-realm      Keycloak realm name (default: spiffe-demo)
#   --ca-org              CA subject org      (default: SPIFFE Demo)
#   --ca-country          CA subject country  (default: US)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source .env.a2a if it exists (re-runs pick up saved values)
if [ -f "$REPO_ROOT/.env.a2a" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env.a2a"
  set +a
fi

# Defaults — override with .env.a2a, environment variables, or flags
K8S_MODE=false
DRY_RUN=false
AUTO_YES=false
KEYCLOAK_URL="${KEYCLOAK_URL:-}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USERNAME:-${KEYCLOAK_ADMIN_USER:-admin}}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-spiffe-openclaw}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
TRUST_DOMAIN="${TRUST_DOMAIN:-demo.example.com}"
CLUSTER_NAME="${CLUSTER_NAME:-spiffe-demo}"
SPIRE_NAMESPACE="${SPIRE_NAMESPACE:-spire-system}"
CA_ORG="${CA_ORG:-SPIFFE Demo}"
CA_COUNTRY="${CA_COUNTRY:-US}"
CA_CN="${CA_CN:-${CA_ORG} CA}"

# Chart versions
SPIRE_CRDS_VERSION="0.5.0"
SPIRE_VERSION="0.27.1"

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s)                     K8S_MODE=true; shift ;;
    --dry-run)                 DRY_RUN=true; shift ;;
    -y|--yes)                  AUTO_YES=true; shift ;;
    --keycloak-url)            KEYCLOAK_URL="$2"; shift 2 ;;
    --keycloak-admin-user)     KEYCLOAK_ADMIN_USER="$2"; shift 2 ;;
    --keycloak-admin-password) KEYCLOAK_ADMIN_PASSWORD="$2"; shift 2 ;;
    --keycloak-realm)          KEYCLOAK_REALM="$2"; shift 2 ;;
    --keycloak-namespace)      KEYCLOAK_NAMESPACE="$2"; shift 2 ;;
    --trust-domain)            TRUST_DOMAIN="$2"; shift 2 ;;
    --cluster-name)            CLUSTER_NAME="$2"; shift 2 ;;
    --spire-namespace)         SPIRE_NAMESPACE="$2"; shift 2 ;;
    --ca-org)                  CA_ORG="$2"; CA_CN="${CA_ORG} CA"; shift 2 ;;
    --ca-country)              CA_COUNTRY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
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
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

run_cmd() {
  if $DRY_RUN; then
    echo -e "${YELLOW}  [dry-run] $*${NC}"
  else
    "$@"
  fi
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  A2A Infrastructure Setup (SPIRE + Keycloak)               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# Prerequisites check
# ============================================================================
log_info "Checking prerequisites..."

if ! command -v helm &>/dev/null; then
  log_error "helm CLI not found. Install it: https://helm.sh/docs/intro/install/"
  exit 1
fi
log_success "helm found"

if ! command -v $KUBECTL &>/dev/null; then
  log_error "$KUBECTL CLI not found."
  exit 1
fi
log_success "$KUBECTL found"

if ! $KUBECTL auth can-i create crd &>/dev/null; then
  log_warn "Current user may not have cluster-admin — SPIRE CRD install may fail"
fi

echo ""
log_info "Configuration:"
log_info "  Trust domain:       $TRUST_DOMAIN"
log_info "  Cluster name:       $CLUSTER_NAME"
log_info "  SPIRE namespace:    $SPIRE_NAMESPACE"
log_info "  Keycloak namespace: $KEYCLOAK_NAMESPACE"
log_info "  Keycloak realm:     $KEYCLOAK_REALM"
log_info "  CA org:             $CA_ORG"
log_info "  CA country:         $CA_COUNTRY"
if [ -n "$KEYCLOAK_URL" ]; then
  log_info "  Keycloak URL:       $KEYCLOAK_URL"
fi
echo ""

# ============================================================================
# Step 1: Install SPIRE
# ============================================================================
log_info "Step 1: Installing SPIRE..."

# Create namespace
run_cmd $KUBECTL create namespace "$SPIRE_NAMESPACE" --dry-run=client -o yaml | run_cmd $KUBECTL apply -f -

# Install SPIRE CRDs
if helm status spire-crds -n "$SPIRE_NAMESPACE" &>/dev/null; then
  log_info "spire-crds already installed — skipping"
else
  log_info "Installing SPIRE CRDs (v${SPIRE_CRDS_VERSION})..."
  run_cmd helm install spire-crds spire-crds \
    --repo https://spiffe.github.io/helm-charts-hardened/ \
    --version "$SPIRE_CRDS_VERSION" \
    -n "$SPIRE_NAMESPACE"
  log_success "SPIRE CRDs installed"
fi

# Install or upgrade SPIRE with configurable values
HELM_ACTION="install"
if helm status spire -n "$SPIRE_NAMESPACE" &>/dev/null; then
  HELM_ACTION="upgrade"
  log_info "spire already installed — upgrading..."
else
  log_info "Installing SPIRE (v${SPIRE_VERSION})..."
fi

run_cmd helm $HELM_ACTION spire spire \
  --repo https://spiffe.github.io/helm-charts-hardened/ \
  --version "$SPIRE_VERSION" \
  -n "$SPIRE_NAMESPACE" \
  -f "$SCRIPT_DIR/spire/values.yaml" \
  --set "global.spire.trustDomain=$TRUST_DOMAIN" \
  --set "global.spire.clusterName=$CLUSTER_NAME" \
  --set "global.spire.caSubject.commonName=$CA_CN" \
  --set "global.spire.caSubject.organization=$CA_ORG" \
  --set "global.spire.caSubject.country=$CA_COUNTRY" \
  --set "global.openshift=$(! $K8S_MODE && echo true || echo false)"

log_success "SPIRE $HELM_ACTION complete"
echo ""

# Wait for SPIRE to be ready
if ! $DRY_RUN; then
  log_info "Waiting for SPIRE server..."
  $KUBECTL rollout status statefulset/spire-server -n "$SPIRE_NAMESPACE" --timeout=120s
  log_info "Waiting for SPIRE agent..."
  $KUBECTL rollout status daemonset/spire-agent -n "$SPIRE_NAMESPACE" --timeout=120s
  log_success "SPIRE is ready"
else
  log_info "[dry-run] Would wait for SPIRE rollout"
fi
echo ""

# ============================================================================
# Step 2: Apply ClusterSPIFFEID
# ============================================================================
log_info "Step 2: Applying ClusterSPIFFEID for OpenClaw workloads..."
run_cmd $KUBECTL apply -f "$SCRIPT_DIR/spire/clusterspiffeid.yaml"
log_success "ClusterSPIFFEID applied"
echo ""

# ============================================================================
# Step 3: Deploy Keycloak (if needed) and configure realm
# ============================================================================
log_info "Step 3: Keycloak setup..."

# 3a: If no URL provided, check if we should deploy a new instance
if [ -z "$KEYCLOAK_URL" ]; then
  # Check if the RHBK operator is installed
  RHBK_INSTALLED=false
  if $KUBECTL get crd keycloaks.k8s.keycloak.org &>/dev/null; then
    RHBK_INSTALLED=true
  fi

  # Check if a Keycloak instance already exists in the target namespace
  KC_EXISTS=false
  if $RHBK_INSTALLED && $KUBECTL get keycloak -n "$KEYCLOAK_NAMESPACE" &>/dev/null 2>&1; then
    KC_COUNT=$($KUBECTL get keycloak -n "$KEYCLOAK_NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')
    if [ "$KC_COUNT" -gt 0 ]; then
      KC_EXISTS=true
    fi
  fi

  if $KC_EXISTS; then
    log_info "Keycloak instance found in namespace '$KEYCLOAK_NAMESPACE'"
    # Detect URL from route (OpenShift) or ingress (K8s)
    if ! $K8S_MODE; then
      KEYCLOAK_URL="https://$($KUBECTL get route keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)" || true
    fi
    if [ -n "$KEYCLOAK_URL" ] && [ "$KEYCLOAK_URL" != "https://" ]; then
      log_success "Detected Keycloak URL: $KEYCLOAK_URL"
    else
      read -p "  Enter Keycloak URL: " KEYCLOAK_URL
    fi
  elif $RHBK_INSTALLED; then
    log_info "RHBK operator found but no Keycloak instance in '$KEYCLOAK_NAMESPACE'"
    if ! $AUTO_YES; then
      read -p "  Deploy a new Keycloak instance? (Y/n): " -n 1 -r
      echo
    else
      REPLY="y"
    fi
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      # Generate a DB password
      KC_DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)

      # Prompt for admin password
      if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        read -sp "  Keycloak admin password (or Enter for random): " KEYCLOAK_ADMIN_PASSWORD
        echo
        if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
          KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
          log_info "Generated admin password: $KEYCLOAK_ADMIN_PASSWORD"
        fi
      fi

      log_info "Deploying Keycloak to namespace '$KEYCLOAK_NAMESPACE'..."

      # Create namespace
      run_cmd $KUBECTL create namespace "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | run_cmd $KUBECTL apply -f -

      if ! $DRY_RUN; then
        # Deploy PostgreSQL (substitute password)
        sed "s/REPLACE_DB_PASSWORD/$KC_DB_PASSWORD/g" \
          "$SCRIPT_DIR/keycloak/postgres.yaml" | $KUBECTL apply -n "$KEYCLOAK_NAMESPACE" -f -
        log_success "PostgreSQL deployed"

        # Wait for PostgreSQL
        log_info "Waiting for PostgreSQL..."
        $KUBECTL rollout status statefulset/keycloak-db -n "$KEYCLOAK_NAMESPACE" --timeout=120s

        # Detect hostname for route
        if ! $K8S_MODE; then
          KC_CLUSTER_DOMAIN=$($KUBECTL get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null) || true
          KC_HOSTNAME="keycloak-${KEYCLOAK_NAMESPACE}.${KC_CLUSTER_DOMAIN}"
        else
          KC_HOSTNAME="keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local"
        fi

        # Deploy Keycloak CR
        sed "s|REPLACE_KEYCLOAK_HOSTNAME|$KC_HOSTNAME|g" \
          "$SCRIPT_DIR/keycloak/keycloak-cr.yaml" | $KUBECTL apply -n "$KEYCLOAK_NAMESPACE" -f -
        log_success "Keycloak CR applied"

        # Wait for Keycloak to be ready
        log_info "Waiting for Keycloak to start (this may take a few minutes)..."
        for i in $(seq 1 60); do
          KC_READY=$($KUBECTL get keycloak keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
          if [ "$KC_READY" = "True" ]; then
            break
          fi
          sleep 5
        done

        if [ "$KC_READY" = "True" ]; then
          log_success "Keycloak is ready"
        else
          log_warn "Keycloak may still be starting — check: $KUBECTL get keycloak -n $KEYCLOAK_NAMESPACE"
        fi

        # Read operator-generated admin credentials
        KC_ADMIN_SECRET=$($KUBECTL get secret -n "$KEYCLOAK_NAMESPACE" -o name 2>/dev/null | grep 'keycloak-initial-admin' | head -1) || true
        if [ -n "$KC_ADMIN_SECRET" ]; then
          KEYCLOAK_ADMIN_USER=$($KUBECTL get "$KC_ADMIN_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
          KEYCLOAK_ADMIN_PASSWORD=$($KUBECTL get "$KC_ADMIN_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
          log_success "Read admin credentials from $KC_ADMIN_SECRET"
        fi

        # Create route if OpenShift and no route exists
        if ! $K8S_MODE; then
          if ! $KUBECTL get route keycloak -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
            $KUBECTL create route edge keycloak \
              --service=keycloak-service --port=8080 \
              -n "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
            log_success "Route created"
          fi
          KEYCLOAK_URL="https://$KC_HOSTNAME"
        else
          KEYCLOAK_URL="http://$KC_HOSTNAME"
        fi
        log_success "Keycloak URL: $KEYCLOAK_URL"
      else
        log_info "[dry-run] Would deploy PostgreSQL + Keycloak CR to '$KEYCLOAK_NAMESPACE'"
        KEYCLOAK_URL="https://keycloak-${KEYCLOAK_NAMESPACE}.example.com"
      fi
    else
      log_info "Skipping Keycloak deployment"
      read -p "  Enter existing Keycloak URL (or press Enter to skip): " KEYCLOAK_URL
    fi
  else
    log_warn "RHBK operator not found and no Keycloak URL provided"
    log_info "Install the RHBK operator first, or provide --keycloak-url for an existing instance"
    read -p "  Enter existing Keycloak URL (or press Enter to skip): " KEYCLOAK_URL
  fi
fi

# 3b: Configure the realm
if [ -z "$KEYCLOAK_URL" ]; then
  log_warn "Skipping Keycloak realm configuration — configure manually (see README.md)"
else
  if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    read -sp "  Enter Keycloak admin password for '$KEYCLOAK_ADMIN_USER': " KEYCLOAK_ADMIN_PASSWORD
    echo ""
  fi

  log_info "Configuring realm '$KEYCLOAK_REALM' at $KEYCLOAK_URL..."

  if $DRY_RUN; then
    log_info "[dry-run] Would authenticate and configure realm '$KEYCLOAK_REALM'"
  else
    # Get admin token
    KC_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=${KEYCLOAK_ADMIN_USER}" \
      -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
      --connect-timeout 10 \
      2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

    if [ -z "$KC_TOKEN" ]; then
      log_error "Could not authenticate to Keycloak"
      log_warn "Configure the realm manually — see README.md"
    else
      log_success "Authenticated to Keycloak"

      # Check if realm exists
      REALM_EXISTS=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $KC_TOKEN" \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}" 2>/dev/null)

      if [ "$REALM_EXISTS" = "200" ]; then
        log_info "Realm '$KEYCLOAK_REALM' already exists — skipping creation"
      else
        log_info "Creating realm '$KEYCLOAK_REALM'..."

        # Patch realm name into config
        REALM_JSON=$(python3 -c "
import json, sys
with open('$SCRIPT_DIR/keycloak/realm-config.json') as f:
    cfg = json.load(f)
cfg['realm'] = '$KEYCLOAK_REALM'
json.dump(cfg, sys.stdout)
")

        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
          -X POST -H "Authorization: Bearer $KC_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$REALM_JSON" \
          "${KEYCLOAK_URL}/admin/realms" 2>/dev/null)

        if [ "$HTTP_CODE" = "201" ]; then
          log_success "Realm '$KEYCLOAK_REALM' created"
        else
          log_error "Failed to create realm (HTTP $HTTP_CODE)"
          log_warn "Create it manually — see README.md"
        fi
      fi

      # Verify realm is accessible
      log_info "Verifying realm endpoint..."
      WELL_KNOWN=$(curl -sk "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" 2>/dev/null)
      if echo "$WELL_KNOWN" | python3 -c "import sys,json; json.load(sys.stdin)['token_endpoint']; sys.exit(0)" 2>/dev/null; then
        log_success "Realm '$KEYCLOAK_REALM' is accessible"
      else
        log_warn "Could not verify realm — check Keycloak logs"
      fi
    fi
  fi
fi
echo ""

# ============================================================================
# Step 4: Write .env.a2a (cluster-level config, survives .env wipes)
# ============================================================================
ENV_A2A="$REPO_ROOT/.env.a2a"

if $DRY_RUN; then
  log_info "[dry-run] Would write $ENV_A2A"
else
  cat > "$ENV_A2A" <<EOF
# A2A cluster infrastructure — written by setup-a2a-infra.sh
# This file is per-cluster. Safe to keep when wiping .env (which is per-namespace).

# SPIRE
TRUST_DOMAIN=$TRUST_DOMAIN
CLUSTER_NAME=$CLUSTER_NAME
SPIRE_NAMESPACE=$SPIRE_NAMESPACE
CA_ORG="$CA_ORG"
CA_COUNTRY=$CA_COUNTRY

# Keycloak
KEYCLOAK_NAMESPACE=$KEYCLOAK_NAMESPACE
KEYCLOAK_URL=$KEYCLOAK_URL
KEYCLOAK_REALM=$KEYCLOAK_REALM
KEYCLOAK_ADMIN_USERNAME=$KEYCLOAK_ADMIN_USER
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD
EOF
  log_success "Wrote $ENV_A2A"
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  A2A Infrastructure Setup Complete                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "SPIRE:"
echo "  Namespace:    $SPIRE_NAMESPACE"
echo "  Trust domain: $TRUST_DOMAIN"
echo "  Cluster name: $CLUSTER_NAME"
echo "  Helm charts:  spire-crds v${SPIRE_CRDS_VERSION}, spire v${SPIRE_VERSION}"
echo ""
echo "Keycloak:"
echo "  Namespace: $KEYCLOAK_NAMESPACE"
if [ -n "$KEYCLOAK_URL" ]; then
echo "  URL:       $KEYCLOAK_URL"
echo "  Realm:     $KEYCLOAK_REALM"
fi
echo ""
echo "Saved to: $ENV_A2A"
echo ""
echo "Next steps:"
echo "  1. Deploy OpenClaw with A2A:"
echo "     ./scripts/setup.sh --with-a2a"
echo ""
echo "  2. The setup.sh script will read .env.a2a automatically for"
echo "     Keycloak URL, realm, and credentials."
echo ""
