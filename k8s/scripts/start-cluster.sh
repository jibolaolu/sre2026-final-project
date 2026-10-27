#!/usr/bin/env bash
# start-cluster.sh — Start the Techbleat Bank minikube cluster and deploy all services.
# Run this from WSL2 after a system reboot or when starting fresh.
#
# Usage:
#   bash k8s/scripts/start-cluster.sh          # start + deploy (skip image build)
#   REBUILD=1 bash k8s/scripts/start-cluster.sh # start + build images + deploy
#
# After this script completes, run setup-portproxy.ps1 in PowerShell (as Admin)
# to restore the Windows port proxy so https://banking-app.eaglesoncloude.com works.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="techbleat-bank"

echo "=========================================="
echo "  Techbleat Bank — Cluster Startup"
echo "=========================================="
echo ""

# ── 1. Start minikube ──────────────────────────────────────────────────────────
echo "[1/4] Checking minikube cluster..."
STATUS=$(minikube status --profile "$PROFILE" --format '{{.Host}}' 2>/dev/null || echo "Stopped")

if [ "$STATUS" = "Running" ]; then
  echo "      minikube already running."
else
  echo "      Starting minikube (profile: $PROFILE)..."
  minikube start --profile "$PROFILE"
  echo "      minikube started."
fi

# ── 2. Enable required addons ──────────────────────────────────────────────────
echo ""
echo "[2/4] Ensuring required addons are enabled..."
minikube addons enable ingress --profile "$PROFILE" 2>/dev/null || true
minikube addons enable ingress-dns --profile "$PROFILE" 2>/dev/null || true

# ── 3. Apply cloudflared (restore after reboot) ────────────────────────────────
echo ""
echo "[3/4] Applying cloudflared deployment..."
CLOUDFLARE_MANIFEST="$(dirname "$SCRIPT_DIR")/../k8s/cloudflare/cloudflared-deployment.yaml"
CLOUDFLARE_MANIFEST="$(cd "$SCRIPT_DIR/../.." && pwd)/k8s/cloudflare/cloudflared-deployment.yaml"
if kubectl get secret cloudflare-tunnel-token -n banking &>/dev/null; then
  kubectl apply -f "$CLOUDFLARE_MANIFEST"
  echo "      cloudflared applied."
else
  echo "      WARNING: cloudflare-tunnel-token secret not found."
  echo "      Run 'bash k8s/scripts/deploy-local.sh' once with CLOUDFLARE_TUNNEL_TOKEN set in .env"
fi

# ── 4. Deploy via Helm ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] Deploying application..."
if [ "${REBUILD:-0}" = "1" ]; then
  echo "      REBUILD=1: building images locally before deploy..."
  bash "$SCRIPT_DIR/deploy-local.sh"
else
  echo "      Deploying with existing images (SKIP_BUILD=1)..."
  SKIP_BUILD=1 bash "$SCRIPT_DIR/deploy-local.sh"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Done! Next steps:"
echo "=========================================="
echo ""
echo "  1. Open PowerShell as Administrator and run:"
echo "     powershell -ExecutionPolicy Bypass -File k8s\\scripts\\setup-portproxy.ps1"
echo ""
echo "  2. Verify pods are running:"
echo "     kubectl get pods -n banking"
echo ""
echo "  3. Check Cloudflare tunnel:"
echo "     kubectl get pods -n banking -l app=cloudflared"
echo "     kubectl logs -n banking -l app=cloudflared --tail=5"
echo ""
echo "  4. Test public URLs:"
echo "     https://banking-app.eaglesoncloude.com"
echo "     https://auth.eaglesoncloude.com"
echo ""
