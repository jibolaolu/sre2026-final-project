#!/usr/bin/env bash
# recovery.sh — One-command recovery after a Windows reboot or minikube restart.
#
# What it does (all steps are idempotent — safe to run repeatedly):
#   1. Starts minikube if stopped
#   2. Re-creates all Kubernetes secrets from .env
#   3. Restarts cloudflared (Cloudflare Tunnel connector)
#   4. Restarts the ingress port-forward (WSL2:8080/8443 → minikube ingress)
#   5. Restarts the WSL2 HTTPS proxy (for AI API calls from pods)
#   6. Patches CoreDNS with current AI API IPs (may change after reboot)
#   7. Prints the netsh portproxy command to run in Windows (port 80/443)
#
# Usage:
#   bash k8s/scripts/recovery.sh
#
# Does NOT rebuild or push images.  Run deploy-local.sh for a full redeploy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
CLUSTER_NAME="techbleat-bank"
NAMESPACE="banking"
ENV_FILE="${REPO_ROOT}/.env"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { printf "${CYAN}[recovery]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[recovery]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[recovery]${NC}  WARNING: %s\n" "$*" >&2; }
die()     { printf "${RED}[recovery]${NC}  ERROR: %s\n" "$*" >&2; exit 1; }

# ── Load .env ────────────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || die ".env not found at ${ENV_FILE}. Copy .env.example and fill in your values."
set -a; source "${ENV_FILE}"; set +a
info "Loaded secrets from ${ENV_FILE}"

# Strip Windows carriage returns from all secrets
_clean() { printf '%s' "${1:-}" | tr -d '\r'; }
POSTGRES_PASSWORD="$(_clean "${POSTGRES_PASSWORD:-bankingdev2026}")"
KEYCLOAK_ADMIN_PASSWORD="$(_clean "${KEYCLOAK_ADMIN_PASSWORD:-admin}")"
KC_ADMIN_CLIENT_SECRET="$(_clean "${KC_ADMIN_CLIENT_SECRET:-localdevsecret2026}")"
OPENAI_API_KEY="$(_clean "${OPENAI_API_KEY:-}")"
ANTHROPIC_API_KEY="$(_clean "${ANTHROPIC_API_KEY:-}")"
DD_API_KEY="$(_clean "${DD_API_KEY:-}")"
CLOUDFLARE_TUNNEL_TOKEN="$(_clean "${CLOUDFLARE_TUNNEL_TOKEN:-}")"

# ── 1. Ensure minikube is running ─────────────────────────────────────────────
if minikube status --profile "${CLUSTER_NAME}" 2>/dev/null | grep -q "Running"; then
  info "minikube '${CLUSTER_NAME}' already running."
else
  info "Starting minikube '${CLUSTER_NAME}'..."
  minikube start \
    --profile "${CLUSTER_NAME}" \
    --driver=docker \
    --cpus=4 \
    --memory=6g \
    --disk-size=30g
  success "minikube started."
fi

kubectl config use-context "${CLUSTER_NAME}"

# ── 2. Ensure namespace exists ────────────────────────────────────────────────
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Re-create Kubernetes secrets from .env ─────────────────────────────────
# Uses --dry-run=client -o yaml | kubectl apply so existing secrets are updated
# in-place rather than failing with "already exists".
info "Restoring Kubernetes secrets..."

kubectl create secret generic banking-app-secrets \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  --from-literal=keycloak-admin-password="${KEYCLOAK_ADMIN_PASSWORD}" \
  --from-literal=keycloak-admin-client-secret="${KC_ADMIN_CLIENT_SECRET}" \
  --from-literal=openai-api-key="${OPENAI_API_KEY}" \
  --from-literal=anthropic-api-key="${ANTHROPIC_API_KEY}" \
  --from-literal=datadog-api-key="${DD_API_KEY}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
success "banking-app-secrets restored."

if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  kubectl create secret generic cloudflare-tunnel-token \
    --from-literal=token="${CLOUDFLARE_TUNNEL_TOKEN}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "cloudflare-tunnel-token restored."
else
  warn "CLOUDFLARE_TUNNEL_TOKEN not set in .env — cloudflared will stay down."
fi

# Re-create Datadog API key secret in its own namespace (if DD configured)
if [ -n "${DD_API_KEY}" ]; then
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  kubectl create secret generic datadog-secret \
    --from-literal=api-key="${DD_API_KEY}" \
    -n datadog \
    --dry-run=client -o yaml | kubectl apply -f -
  success "datadog-secret restored."
fi

# ── 4. Restart cloudflared ────────────────────────────────────────────────────
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  info "Restarting cloudflared..."
  kubectl apply -f "${REPO_ROOT}/k8s/cloudflare/cloudflared-deployment.yaml"
  kubectl rollout restart deployment/cloudflared -n "${NAMESPACE}"
  kubectl rollout status deployment/cloudflared -n "${NAMESPACE}" --timeout=60s \
    && success "cloudflared is running." \
    || warn "cloudflared rollout timed out — check: kubectl logs -n ${NAMESPACE} -l app=cloudflared"
fi

# ── 5. Restart ingress port-forward ──────────────────────────────────────────
# Binds 0.0.0.0 so Windows can reach it via localhost (WSL2 shares loopback).
info "Restarting ingress port-forward (8080:80, 8443:443)..."
pkill -f "kubectl port-forward.*ingress-nginx" 2>/dev/null || true
sleep 2
if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  warn "ingress-nginx not found — run deploy-local.sh once to install it."
else
  nohup kubectl port-forward svc/ingress-nginx-controller \
    8080:80 8443:443 \
    -n ingress-nginx \
    --address=0.0.0.0 \
    >/tmp/pf-ingress.log 2>&1 &
  disown
  sleep 2
  pgrep -f "kubectl port-forward.*ingress-nginx" >/dev/null \
    && success "Ingress port-forward active (8080/8443). Log: /tmp/pf-ingress.log" \
    || warn "Port-forward failed — check /tmp/pf-ingress.log"
fi

# ── 6. Restart WSL2 HTTPS proxy (AI API traffic from pods) ───────────────────
PROXY_SCRIPT="${SCRIPT_DIR}/k8s-proxy.py"
if [ -f "${PROXY_SCRIPT}" ]; then
  pkill -f "k8s-proxy.py" 2>/dev/null || true
  sleep 1
  nohup python3 "${PROXY_SCRIPT}" >/tmp/k8s-proxy.log 2>&1 &
  disown
  sleep 1
  pgrep -f "k8s-proxy.py" >/dev/null \
    && success "WSL2 HTTPS proxy running on :3128." \
    || warn "Proxy failed to start — check /tmp/k8s-proxy.log"
else
  info "k8s-proxy.py not found — skipping (AI APIs may not be reachable from pods)."
fi

# ── 7. Re-patch CoreDNS with current AI API IPs ──────────────────────────────
# The IP for api.anthropic.com / api.openai.com can change after reboot.
if command -v python3 >/dev/null 2>&1; then
  info "Refreshing CoreDNS AI API hosts..."
  ANTHROPIC_IP=$(python3 -c "import socket; print(socket.gethostbyname('api.anthropic.com'))" 2>/dev/null || echo "")
  OPENAI_IP=$(python3 -c "import socket; print(socket.gethostbyname('api.openai.com'))" 2>/dev/null || echo "")
  if [ -n "${ANTHROPIC_IP}" ] && [ -n "${OPENAI_IP}" ]; then
    COREDNS_CM=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
    if [ -n "${COREDNS_CM}" ]; then
      # Remove old hosts block if present, then add fresh one
      STRIPPED=$(echo "${COREDNS_CM}" \
        | sed '/hosts {/,/}/{ /api\.anthropic\.com/d; /api\.openai\.com/d; /fallthrough/d; /^[[:space:]]*hosts {[[:space:]]*$/d; /^[[:space:]]*}[[:space:]]*$/d }')
      HOSTS_BLOCK="        hosts {\n            ${ANTHROPIC_IP} api.anthropic.com\n            ${OPENAI_IP} api.openai.com\n            fallthrough\n        }"
      NEW_CM=$(echo "${STRIPPED}" | sed "s/        kubernetes cluster.local/${HOSTS_BLOCK}\n        kubernetes cluster.local/")
      kubectl create configmap coredns -n kube-system \
        --from-literal=Corefile="${NEW_CM}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      kubectl rollout restart deployment/coredns -n kube-system >/dev/null
      success "CoreDNS updated (Anthropic: ${ANTHROPIC_IP}, OpenAI: ${OPENAI_IP})."
    fi
  else
    warn "Cannot resolve AI API hosts from WSL2 — CoreDNS patch skipped."
  fi
fi

# ── 8. Windows netsh portproxy (port 80/443 → 8080/8443) ─────────────────────
# These rules are wiped on every Windows reboot. Run the block below in an
# elevated (Run as Administrator) PowerShell window on Windows.
printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  ACTION REQUIRED — Run this in an elevated Windows PowerShell:\n\n'
printf '  netsh interface portproxy add v4tov4 listenport=80   listenaddress=127.0.0.1 connectport=8080 connectaddress=127.0.0.1\n'
printf '  netsh interface portproxy add v4tov4 listenport=443  listenaddress=127.0.0.1 connectport=8443 connectaddress=127.0.0.1\n\n'
printf '  (Or run k8s/scripts/portproxy.ps1 as Administrator — it is idempotent)\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

# ── Status summary ────────────────────────────────────────────────────────────
printf '\n'
success "Recovery complete. Cluster status:"
kubectl get pods -n "${NAMESPACE}" 2>/dev/null \
  | awk 'NR==1{print "  "$0} NR>1{
      split($2,r,"/");
      status=(r[1]==r[2] && r[1]!="0") ? "\033[0;32mREADY\033[0m" : "\033[0;33mNOT READY\033[0m";
      printf "  %-50s %s\n", $1" ("$2")", status
    }'
printf '\n'
info "Public URL: https://banking-app.eaglesoncloude.com"
info "Local URL:  http://techbleat-bank.local  (needs netsh portproxy above)"
