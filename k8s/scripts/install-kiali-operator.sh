#!/usr/bin/env bash
# install-kiali-operator.sh
#
# One-time setup: installs the Kiali Operator into an EKS cluster.
# Run this BEFORE helm upgrade when deploying to EKS with istio.kiali.enabled=true
# and istio.kiali.minikubeAddon=false.
#
# Prerequisites:
#   - kubectl configured for the target cluster (aws eks update-kubeconfig ...)
#   - helm 3 installed
#   - istio-system namespace exists (Istio already installed)
#
# Usage:
#   chmod +x k8s/scripts/install-kiali-operator.sh
#   ./k8s/scripts/install-kiali-operator.sh
#
# For minikube, use the addon instead:
#   minikube addons enable kiali -p <profile>
#   minikube addons enable metrics-server -p <profile>   # Kiali needs metrics-server

set -euo pipefail

KIALI_OPERATOR_VERSION="1.89.0"   # pin to a known-good version
NAMESPACE="kiali-operator"

echo "[kiali] Adding Kiali Helm repo..."
helm repo add kiali https://kiali.org/helm-charts
helm repo update

echo "[kiali] Installing Kiali Operator v${KIALI_OPERATOR_VERSION} into namespace '${NAMESPACE}'..."
helm upgrade --install kiali-operator kiali/kiali-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KIALI_OPERATOR_VERSION}" \
  --set cr.create=false \
  --set cr.namespace=istio-system \
  --wait --timeout=5m

echo "[kiali] Operator ready. The Helm chart will now deploy the KialiCR on the next 'helm upgrade'."
echo ""
echo "[kiali] To create the Keycloak 'kiali' OIDC client secret (if authStrategy=openid):"
echo "  kubectl -n istio-system create secret generic kiali \\"
echo "    --from-literal=oidc-secret=<your-keycloak-kiali-client-secret>"
echo ""
echo "[kiali] Access after helm upgrade:"
echo "  Production : https://kiali.eaglesoncloude.com  (via Cloudflare → nginx → Kiali)"
echo "  Port-forward: kubectl -n istio-system port-forward svc/kiali 20001:20001"
echo "                then open http://localhost:20001/kiali"
