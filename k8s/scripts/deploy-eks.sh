#!/usr/bin/env bash
# deploy-eks.sh — Deploy the Techbleat Global Bank stack to AWS EKS.
#
# Prerequisites:
#   - aws cli v2           (https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
#   - kubectl              (https://kubernetes.io/docs/tasks/tools/)
#   - helm 3.x             (https://helm.sh/docs/intro/install/)
#   - eksctl (optional)    (https://eksctl.io/)
#   - An EKS cluster with the AWS Load Balancer Controller installed
#   - ECR repositories created for each service image
#
# Required environment variables:
#   AWS_ACCOUNT_ID   — your 12-digit AWS account ID
#   AWS_REGION       — e.g. us-east-1
#   EKS_CLUSTER_NAME — your EKS cluster name
#
# Usage:
#   AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 EKS_CLUSTER_NAME=techbleat-prod \
#     bash k8s/scripts/deploy-eks.sh
set -euo pipefail

: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${EKS_CLUSTER_NAME:?Set EKS_CLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/techbleat-bank"
ISTIO_DIR="${SCRIPT_DIR}/../istio"
NAMESPACE="banking"
RELEASE="techbleat-bank"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_ROOT="${SCRIPT_DIR}/../.."

info()    { printf '\033[0;36m[k8s-eks]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[k8s-eks]\033[0m  %s\n' "$*"; }
die()     { printf '\033[0;31m[k8s-eks]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. ECR login ──────────────────────────────────────────────────────────────
info "Logging in to ECR (${ECR_REGISTRY})…"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ── 2. Build, tag, and push each image ────────────────────────────────────────
declare -A IMAGES=(
  [user-service]="${REPO_ROOT}/techbleat-global-bank-backend/user-service"
  [transaction-service]="${REPO_ROOT}/techbleat-global-bank-backend/transaction-service"
  [activity-service]="${REPO_ROOT}/techbleat-global-bank-backend/activity-service"
  [finance-agent]="${REPO_ROOT}/finance-agent"
)

for svc in "${!IMAGES[@]}"; do
  build_ctx="${IMAGES[$svc]}"
  ecr_repo="${ECR_REGISTRY}/${svc}"
  info "Building and pushing ${svc}…"
  # Ensure the ECR repository exists.
  aws ecr describe-repositories --repository-names "$svc" --region "$AWS_REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$svc" --region "$AWS_REGION" >/dev/null
  docker build -t "${svc}:latest" "$build_ctx"
  docker tag "${svc}:latest" "${ecr_repo}:latest"
  docker push "${ecr_repo}:latest"
  success "Pushed ${ecr_repo}:latest"
done

# Frontend build with Vite args
FRONTEND_ECR="${ECR_REGISTRY}/frontend"
aws ecr describe-repositories --repository-names frontend --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name frontend --region "$AWS_REGION" >/dev/null
docker build \
  --build-arg VITE_KEYCLOAK_URL="https://keycloak.${EKS_CLUSTER_NAME}.example.com" \
  --build-arg VITE_KEYCLOAK_REALM="banking" \
  --build-arg VITE_KEYCLOAK_CLIENT_ID="banking-frontend" \
  -t "frontend:latest" \
  -f "${REPO_ROOT}/techbleat-global-bank-frontend/dockerfile" \
  "${REPO_ROOT}/techbleat-global-bank-frontend"
docker tag "frontend:latest" "${FRONTEND_ECR}:latest"
docker push "${FRONTEND_ECR}:latest"
success "Pushed ${FRONTEND_ECR}:latest"

# ── 3. Configure kubectl for the EKS cluster ──────────────────────────────────
info "Updating kubeconfig for cluster ${EKS_CLUSTER_NAME}…"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

# ── 4. Create namespace ───────────────────────────────────────────────────────
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# ── 5. Helm upgrade --install with EKS overrides ─────────────────────────────
info "Deploying with Helm (release: ${RELEASE}, namespace: ${NAMESPACE})…"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "${CHART_DIR}/values.yaml" \
  -f "${CHART_DIR}/values-eks.yaml" \
  --set global.imageRegistry="${ECR_REGISTRY}/" \
  --wait \
  --timeout 15m

# ── 6. Apply Istio policies (if Istio is installed on the cluster) ─────────────
if kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
  info "Applying Istio policies…"
  kubectl apply -f "${ISTIO_DIR}/peer-authentication.yaml"
  kubectl apply -f "${ISTIO_DIR}/authorization-policy/"
  kubectl apply -f "${ISTIO_DIR}/destination-rules/"
else
  info "Istio CRDs not found — skipping Istio policy application."
fi

success "EKS deployment complete."
printf '\n'
printf '  Get the ALB hostname:\n'
printf '    kubectl get ingress -n %s\n' "$NAMESPACE"
printf '\n'
printf '  Jaeger:     kubectl port-forward svc/jaeger 16686:16686 -n %s\n' "$NAMESPACE"
printf '  Prometheus: kubectl port-forward svc/prometheus 9090:9090 -n %s\n' "$NAMESPACE"
printf '\n'
