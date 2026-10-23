#!/usr/bin/env bash
# argocd-local.sh — Install ArgoCD, pre-register the banking app, expose the UI.
#
# Idempotent — safe to re-run:
#   - ArgoCD already running  → skip install, re-apply app, restart port-forward.
#   - ArgoCD not running      → full install (crane + Helm) then app + port-forward.
#
# App source strategy (auto-detected):
#   1. GitHub remote found  → Application points to your GitHub repo (GitOps ready).
#   2. No remote            → minikube mount + file:///repo (pure local).
#
# Usage:
#   bash k8s/scripts/argocd-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PROFILE="techbleat-bank"
ARGOCD_NS="argocd"
APP_NS="banking"
ARGOCD_PORT=8088
ARGOCD_VERSION="v3.5.6"
DEX_VERSION="v2.45.1"
REDIS_VERSION="8.2.3-alpine"
CRANE_VERSION="0.20.2"

info()    { printf '\033[0;36m[argocd]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[argocd]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[argocd]\033[0m  WARNING: %s\n' "$*" >&2; }
die()     { printf '\033[0;31m[argocd]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

kubectl config use-context "${PROFILE}" >/dev/null 2>&1 \
  || die "minikube profile '${PROFILE}' not found. Run deploy-local.sh first."

# ── 1. Install if not running ─────────────────────────────────────────────────
argocd_ready() {
  local ready
  ready=$(kubectl get pods -n "${ARGOCD_NS}" --no-headers 2>/dev/null \
    | awk '{print $2}' | grep -c "^1/1$" || true)
  [ "${ready}" -ge 4 ]
}

if argocd_ready; then
  success "ArgoCD already running — skipping install."
else
  info "ArgoCD not running. Starting full install..."

  # Install crane (single-arch image puller — avoids manifest-list issue in minikube)
  if ! command -v crane >/dev/null 2>&1; then
    info "Installing crane v${CRANE_VERSION}..."
    curl -fsSL \
      "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
      | tar -xz -C /tmp crane
    sudo mv /tmp/crane /usr/local/bin/crane
    success "crane installed."
  fi

  # Pull images as linux/amd64 only (no manifest list → containerd won't call registry)
  info "Pulling ArgoCD images as linux/amd64..."
  declare -A IMAGES=(
    ["argocd"]="quay.io/argoproj/argocd:${ARGOCD_VERSION}"
    ["dex"]="ghcr.io/dexidp/dex:${DEX_VERSION}"
    ["redis"]="public.ecr.aws/docker/library/redis:${REDIS_VERSION}"
  )
  for name in "${!IMAGES[@]}"; do
    image="${IMAGES[$name]}"
    tarfile="/tmp/argocd-${name}.tar"
    info "  Pulling ${image}..."
    crane pull --platform linux/amd64 "${image}" "${tarfile}"
    minikube image load "${tarfile}" --profile "${PROFILE}" --overwrite
    rm -f "${tarfile}"
    success "  Loaded: ${image}"
  done

  # Install via Helm
  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo 2>/dev/null || true
  info "Installing ArgoCD via Helm..."
  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" \
    --create-namespace \
    --set server.insecure=true \
    --set "configs.params.server\\.insecure=true" \
    --set image.tag="${ARGOCD_VERSION}" \
    --set dex.image.tag="${DEX_VERSION}" \
    --set redis.image.tag="${REDIS_VERSION}" \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=256Mi \
    --set controller.resources.limits.cpu=500m \
    --set controller.resources.limits.memory=512Mi \
    --set server.resources.requests.cpu=50m \
    --set server.resources.requests.memory=128Mi \
    --set repoServer.resources.requests.cpu=50m \
    --set repoServer.resources.requests.memory=128Mi \
    --set redis.resources.requests.cpu=50m \
    --set redis.resources.requests.memory=64Mi

  info "Waiting for ArgoCD server (up to 5 min)..."
  kubectl rollout status deployment/argocd-server -n "${ARGOCD_NS}" --timeout=300s
  success "ArgoCD installed and ready."
fi

# ── 2. Detect repo source ──────────────────────────────────────────────────────
GITHUB_URL=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "")
# ArgoCD pods have no SSH agent — convert git@github.com: SSH URLs to HTTPS
if [[ "${GITHUB_URL}" == git@github.com:* ]]; then
  GITHUB_URL="https://github.com/${GITHUB_URL#git@github.com:}"
fi
USE_MOUNT=false
REPO_URL=""
REVISION=""

if [ -n "${GITHUB_URL}" ]; then
  info "GitHub remote detected: ${GITHUB_URL}"
  REPO_URL="${GITHUB_URL}"
  REVISION="main"
else
  info "No GitHub remote — using minikube mount (file:///repo)."
  USE_MOUNT=true
  REPO_URL="file:///repo"
  REVISION="HEAD"
fi

# ── 3. Start minikube mount (only needed for file:// mode) ────────────────────
if ${USE_MOUNT}; then
  # Kill any stale mount
  pkill -f "minikube mount.*${PROFILE}" 2>/dev/null || true
  sleep 2
  info "Mounting ${REPO_ROOT} → /repo inside minikube..."
  nohup minikube mount "${REPO_ROOT}:/repo" \
    --profile "${PROFILE}" \
    >/tmp/minikube-mount.log 2>&1 &
  disown
  sleep 4
  if pgrep -f "minikube mount.*${PROFILE}" >/dev/null 2>&1; then
    success "minikube mount active (${REPO_ROOT} → /repo)."
  else
    warn "minikube mount failed — check /tmp/minikube-mount.log"
    warn "Falling back to display-only mode (no source sync)."
    REPO_URL=""
  fi
fi

# ── 4. Register repo + Application in ArgoCD ─────────────────────────────────
if [ -n "${REPO_URL}" ]; then
  info "Registering repo source: ${REPO_URL}"

  # Repo credential secret (tells ArgoCD where/how to clone)
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: techbleat-local-repo
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  insecure: "true"
  insecureIgnoreHostKey: "true"
EOF

  # AppProject + Application
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: techbleat-bank
  namespace: ${ARGOCD_NS}
spec:
  description: Techbleat Global Bank
  sourceRepos: ['*']
  destinations:
    - namespace: ${APP_NS}
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: techbleat-bank
  namespace: ${ARGOCD_NS}
  labels:
    app: techbleat-bank
    environment: local
spec:
  project: techbleat-bank
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: k8s/helm/techbleat-bank
    helm:
      valueFiles:
        - values.yaml
        - values-local.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NS}
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
    - group: ''
      kind: Secret
      jsonPointers:
        - /data
EOF
  success "Application 'techbleat-bank' registered in ArgoCD."
else
  warn "No repo source available — app not registered. Push to GitHub and re-run."
fi

# ── 5. Port-forward ArgoCD UI ─────────────────────────────────────────────────
pkill -f "kubectl port-forward svc/argocd-server" 2>/dev/null || true
sleep 2
info "Starting ArgoCD port-forward (0.0.0.0:${ARGOCD_PORT} → argocd-server:80)..."
nohup kubectl port-forward svc/argocd-server \
  "${ARGOCD_PORT}:80" -n "${ARGOCD_NS}" --address=0.0.0.0 \
  >/tmp/pf-argocd.log 2>&1 &
disown
sleep 3

pgrep -f "kubectl port-forward svc/argocd-server" >/dev/null 2>&1 \
  || { warn "Port-forward failed — check /tmp/pf-argocd.log"; exit 1; }

# ── 6. Print summary ──────────────────────────────────────────────────────────
ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null \
  || echo "(not yet available)")

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  ArgoCD ready\n\n'
printf '  URL      : http://localhost:%s\n' "${ARGOCD_PORT}"
printf '  Username : admin\n'
printf '  Password : %s\n\n' "${ARGOCD_PASSWORD}"
if [ -n "${REPO_URL}" ]; then
  printf '  App      : techbleat-bank  (source: %s)\n' "${REPO_URL}"
  printf '  Click Refresh in the UI to see all banking resources.\n\n'
fi
if ${USE_MOUNT}; then
  printf '  NOTE: minikube mount is running in background.\n'
  printf '  Log: /tmp/minikube-mount.log\n\n'
fi
printf '  ── To enable GitOps (Option A — prod/AWS) ──────────────\n'
printf '  1. git remote add origin https://github.com/USER/REPO.git\n'
printf '  2. git push -u origin main\n'
printf '  3. Re-run this script — it auto-detects the remote.\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
