#!/usr/bin/env bash
# startup.sh — Single entry point for Techbleat Global Bank on local minikube.
#
# Each phase checks whether it is already done and SKIPS it if so.
# Only broken or missing components are created/fixed.
# Safe to run after first clone, after a reboot, or whenever things break.
#
# Modes
#   bash k8s/scripts/startup.sh              full deploy  (builds & pushes images)
#   bash k8s/scripts/startup.sh --skip-build recovery     (uses images already in minikube)
#   bash k8s/scripts/startup.sh --help

set -euo pipefail
trap 'echo -e "\n${RED}[startup] ERROR at line $LINENO — see output above${NC}" >&2' ERR

# ── colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()    { printf "${CYAN}[startup]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[startup] ✓${NC}  %s\n" "$*"; }
skip()    { printf "${CYAN}[startup] →${NC}  %s — already OK, skipping.\n" "$*"; }
warn()    { printf "${YELLOW}[startup] ⚠${NC}  %s\n" "$*" >&2; }
die()     { printf "${RED}[startup] ✗${NC}  %s\n" "$*" >&2; exit 1; }

# ── parse flags ───────────────────────────────────────────────────────────────
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build|-s) SKIP_BUILD=1 ;;
    --help|-h)
      echo "Usage: bash k8s/scripts/startup.sh [--skip-build]"
      echo "  (no flags)     full deploy — builds and pushes images"
      echo "  --skip-build   recovery mode — uses images already in minikube"
      exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/techbleat-bank"
REPO_ROOT="${SCRIPT_DIR}/../.."
CLUSTER_NAME="techbleat-bank"
NAMESPACE="banking"
RELEASE="techbleat-bank"
ENV_FILE="${REPO_ROOT}/.env"

# ── load .env ─────────────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || die ".env not found at ${ENV_FILE}. Copy .env.example and fill in your values."
set -a; source "${ENV_FILE}"; set +a
info "Loaded ${ENV_FILE}"

# Strip Windows carriage returns from every secret
_c() { printf '%s' "${1:-}" | tr -d '\r'; }
POSTGRES_PASSWORD="$(_c "${POSTGRES_PASSWORD:-bankingdev2026}")"
KEYCLOAK_ADMIN_PASSWORD="$(_c "${KEYCLOAK_ADMIN_PASSWORD:-admin}")"
KC_ADMIN_CLIENT_SECRET="$(_c "${KC_ADMIN_CLIENT_SECRET:-localdevsecret2026}")"
OPENAI_API_KEY="$(_c "${OPENAI_API_KEY:-}")"
ANTHROPIC_API_KEY="$(_c "${ANTHROPIC_API_KEY:-}")"
DD_API_KEY="$(_c "${DD_API_KEY:-}")"
CLOUDFLARE_TUNNEL_TOKEN="$(_c "${CLOUDFLARE_TUNNEL_TOKEN:-}")"
KEYCLOAK_PUBLIC_URL="$(_c "${KEYCLOAK_PUBLIC_URL:-http://keycloak.techbleat-bank.local}")"
GITHUB_USERNAME="$(_c "${GITHUB_USERNAME:-}")"
DOCKERHUB_USERNAME="$(_c "${DOCKERHUB_USERNAME:-}")"
IMAGE_TAG="$(_c "${IMAGE_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo latest)}")"

if [ -n "${GITHUB_USERNAME}" ]; then
  IMAGE_REGISTRY="ghcr.io/${GITHUB_USERNAME}/"
elif [ -n "${DOCKERHUB_USERNAME}" ]; then
  IMAGE_REGISTRY="${DOCKERHUB_USERNAME}/"
else
  die "Set GITHUB_USERNAME or DOCKERHUB_USERNAME in .env"
fi

# ── track progress ────────────────────────────────────────────────────────────
DONE=(); SKIPPED=(); WARNED=()
phase_done()    { DONE+=("$1"); }
phase_skipped() { SKIPPED+=("$1"); }
phase_warned()  { WARNED+=("$1"); }

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 — Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 0: Prerequisites ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
for cmd in docker minikube kubectl helm; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} not found in PATH."
done
docker info >/dev/null 2>&1 || die "Docker daemon not responding. Start Docker Desktop."
success "docker, minikube, kubectl, helm — all present."
phase_done "prerequisites"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — minikube cluster
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 1: minikube cluster ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if minikube status --profile "${CLUSTER_NAME}" 2>/dev/null | grep -q "Running"; then
  skip "minikube '${CLUSTER_NAME}'"
  phase_skipped "minikube"
else
  info "Starting minikube '${CLUSTER_NAME}'..."
  minikube start \
    --profile "${CLUSTER_NAME}" \
    --driver=docker \
    --cpus=4 \
    --memory=6g \
    --disk-size=30g
  success "minikube started."
  phase_done "minikube"
fi
kubectl config use-context "${CLUSTER_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — NGINX ingress controller
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 2: NGINX ingress controller ━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  skip "ingress-nginx"
  phase_skipped "ingress-nginx"
else
  info "Installing ingress-nginx via Helm..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update ingress-nginx 2>/dev/null || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.admissionWebhooks.enabled=false \
    --set controller.image.pullPolicy=IfNotPresent \
    --set controller.image.digest=""
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s
  success "ingress-nginx installed."
  phase_done "ingress-nginx"
fi
# Always remove admission webhooks — they cause context deadline exceeded on minikube
kubectl delete validatingwebhookconfigurations ingress-nginx-admission \
  --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Kubernetes namespace + secrets
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 3: Namespace + secrets ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Secrets are always synced from .env (dry-run apply is idempotent)
kubectl create secret generic banking-app-secrets \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  --from-literal=keycloak-admin-password="${KEYCLOAK_ADMIN_PASSWORD}" \
  --from-literal=keycloak-admin-client-secret="${KC_ADMIN_CLIENT_SECRET}" \
  --from-literal=openai-api-key="${OPENAI_API_KEY}" \
  --from-literal=anthropic-api-key="${ANTHROPIC_API_KEY}" \
  --from-literal=datadog-api-key="${DD_API_KEY}" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
success "banking-app-secrets synced from .env"

if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  kubectl create secret generic cloudflare-tunnel-token \
    --from-literal=token="${CLOUDFLARE_TUNNEL_TOKEN}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  success "cloudflare-tunnel-token synced."
else
  warn "CLOUDFLARE_TUNNEL_TOKEN not set in .env — public access via Cloudflare will not work."
  phase_warned "cloudflare-token missing"
fi
phase_done "secrets"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Preload third-party images
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 4: Third-party images ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
_load_image() {
  local img=$1
  if minikube image ls --profile "${CLUSTER_NAME}" 2>/dev/null | grep -qF "${img}"; then
    skip "image ${img}"
  else
    info "Pulling and loading ${img}..."
    docker pull "${img}" 2>/dev/null \
      && docker save "${img}" \
           | docker exec -i "${CLUSTER_NAME}" ctr --namespace k8s.io images import - 2>/dev/null \
      || minikube image load "${img}" --profile "${CLUSTER_NAME}" 2>/dev/null \
      || warn "Could not preload ${img} — will pull at pod start."
  fi
}
_load_image "postgres:15"
_load_image "quay.io/keycloak/keycloak:24.0.5"
_load_image "redis:7"
_load_image "confluentinc/cp-kafka:8.1.1"
_load_image "curlimages/curl:8.10.1"
_load_image "busybox:1.36"
success "Third-party images ready."
phase_done "third-party-images"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Build + push service images  (skipped with --skip-build)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 5: Service images ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if [ "${SKIP_BUILD}" = "1" ]; then
  info "--skip-build set — loading existing images into minikube without rebuilding."
  for svc in user-service transaction-service activity-service finance-agent frontend; do
    img="${IMAGE_REGISTRY}${svc}:${IMAGE_TAG}"
    if minikube image ls --profile "${CLUSTER_NAME}" 2>/dev/null | grep -qF "${img}"; then
      skip "${img}"
    else
      info "Loading ${img} into minikube..."
      docker pull "${img}" 2>/dev/null \
        && docker save "${img}" \
             | docker exec -i "${CLUSTER_NAME}" ctr --namespace k8s.io images import - 2>/dev/null \
        || warn "Could not load ${img} — pod may ImagePullBackOff. Run without --skip-build to rebuild."
    fi
  done
  phase_skipped "image-build"
else
  info "Building and pushing service images (tag: ${IMAGE_TAG})..."
  REGISTRY_LOGIN_HOST="ghcr.io"
  [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -z "${GITHUB_USERNAME:-}" ] && REGISTRY_LOGIN_HOST="docker.io"

  if [ "${REGISTRY_LOGIN_HOST}" = "ghcr.io" ]; then
    _tok="$(_c "${GITHUB_TOKEN:-${GITHUB_PAT:-}}")"
    [ -z "${_tok}" ] && die "Set GITHUB_TOKEN or GITHUB_PAT in .env to push to ghcr.io."
    echo "${_tok}" | docker login ghcr.io -u "${GITHUB_USERNAME}" --password-stdin
  else
    [ -n "${DOCKERHUB_TOKEN:-}" ] \
      && echo "$(_c "${DOCKERHUB_TOKEN}")" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin \
      || docker login -u "${DOCKERHUB_USERNAME}"
  fi

  _build_load() {
    local name=$1 ctx=$2 df="${3:-${2}/Dockerfile}"
    local img="${IMAGE_REGISTRY}${name}:${IMAGE_TAG}"
    docker build -t "${img}" -f "${df}" "${ctx}"
    docker push "${img}"
    docker save "${img}" \
      | docker exec -i "${CLUSTER_NAME}" ctr --namespace k8s.io images import - 2>/dev/null \
      || minikube image load "${img}" --profile "${CLUSTER_NAME}"
    success "${name} built, pushed, loaded."
  }

  _build_load user-service        "${REPO_ROOT}/techbleat-global-bank-backend/user-service"
  _build_load transaction-service "${REPO_ROOT}/techbleat-global-bank-backend/transaction-service"
  _build_load activity-service    "${REPO_ROOT}/techbleat-global-bank-backend/activity-service"
  _build_load finance-agent       "${REPO_ROOT}/finance-agent"

  FRONTEND_IMAGE="${IMAGE_REGISTRY}frontend:${IMAGE_TAG}"
  docker build \
    --build-arg VITE_KEYCLOAK_URL="${KEYCLOAK_PUBLIC_URL}" \
    --build-arg VITE_KEYCLOAK_REALM="banking" \
    --build-arg VITE_KEYCLOAK_CLIENT_ID="banking-frontend" \
    -t "${FRONTEND_IMAGE}" \
    -f "${REPO_ROOT}/techbleat-global-bank-frontend/dockerfile" \
    "${REPO_ROOT}/techbleat-global-bank-frontend"
  docker push "${FRONTEND_IMAGE}"
  docker save "${FRONTEND_IMAGE}" \
    | docker exec -i "${CLUSTER_NAME}" ctr --namespace k8s.io images import - 2>/dev/null \
    || minikube image load "${FRONTEND_IMAGE}" --profile "${CLUSTER_NAME}"
  success "All service images built, pushed, loaded."
  phase_done "image-build"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — Helm deploy
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 6: Helm deploy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# Clear stuck pending-install/upgrade locks (safe — just deletes helm's own secret)
HELM_STATUS=$(helm status "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null \
  || echo "not-found")
info "Helm release status: ${HELM_STATUS}"
case "${HELM_STATUS}" in
  pending-install|pending-upgrade|pending-rollback)
    info "Clearing stuck Helm lock (${HELM_STATUS})..."
    kubectl delete secret -n "${NAMESPACE}" -l "owner=helm,name=${RELEASE}" \
      --ignore-not-found 2>/dev/null || true ;;
  deployed)
    # Check if the current image tag is already deployed AND key resources exist.
    # Helm's "deployed" status only reflects its own state record — actual cluster
    # resources may be missing (drift after a crash, manual delete, etc.).
    CURRENT_TAG=$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
      | python3 -c "import sys,json; v=json.load(sys.stdin); print(v.get('userService',{}).get('image',{}).get('tag',''))" \
      2>/dev/null || echo "")
    # Verify the two most critical deployments actually exist in the cluster
    KC_EXISTS=$(kubectl get deployment "${RELEASE}-keycloak"  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null | wc -l)
    FE_EXISTS=$(kubectl get deployment "${RELEASE}-frontend"  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null | wc -l)
    RESOURCES_OK=$([ "${KC_EXISTS}" -gt 0 ] && [ "${FE_EXISTS}" -gt 0 ] && echo "yes" || echo "no")
    if [ "${CURRENT_TAG}" = "${IMAGE_TAG}" ] && [ "${SKIP_BUILD}" = "1" ] && [ "${RESOURCES_OK}" = "yes" ]; then
      skip "Helm release (tag ${IMAGE_TAG} already deployed, resources present)"
      phase_skipped "helm-deploy"
      # Rollout-restart any pods that are not ready
      UNHEALTHY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
        | awk '{split($2,r,"/"); if (r[1]!=r[2] || r[1]=="0") print $1}' || true)
      if [ -n "${UNHEALTHY}" ]; then
        warn "Some pods not ready — restarting: ${UNHEALTHY}"
        for pod in ${UNHEALTHY}; do
          DEP=$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
            -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null || true)
          [ -n "${DEP}" ] && \
            kubectl rollout restart deployment -n "${NAMESPACE}" \
              -l "app.kubernetes.io/name=${DEP}" 2>/dev/null || true
        done
      fi
    else
      [ "${RESOURCES_OK}" = "no" ] && \
        info "Helm state says deployed but cluster resources missing — forcing upgrade to restore."
    fi ;;
esac

# Delete Kafka PVC so KRaft storage is always clean
kubectl delete pvc "kafka-data-${RELEASE}-kafka-0" -n "${NAMESPACE}" \
  --ignore-not-found 2>/dev/null || true

# Adopt any kubectl-applied Istio resources into Helm ownership
for ap in $(kubectl get authorizationpolicy -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  kubectl label authorizationpolicy "${ap}" -n "${NAMESPACE}" \
    app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
  kubectl annotate authorizationpolicy "${ap}" -n "${NAMESPACE}" \
    meta.helm.sh/release-name="${RELEASE}" \
    meta.helm.sh/release-namespace="${NAMESPACE}" --overwrite 2>/dev/null || true
done

if [ "${HELM_STATUS}" != "deployed" ] || [ "${CURRENT_TAG:-}" != "${IMAGE_TAG}" ] || [ "${SKIP_BUILD}" != "1" ]; then
  info "Running helm upgrade --install..."
  SET_ARGS=(
    "--set" "global.imageRegistry=${IMAGE_REGISTRY}"
    "--set" "global.imagePullPolicy=IfNotPresent"
    "--set" "userService.image.tag=${IMAGE_TAG}"
    "--set" "transactionService.image.tag=${IMAGE_TAG}"
    "--set" "activityService.image.tag=${IMAGE_TAG}"
    "--set" "financeAgent.image.tag=${IMAGE_TAG}"
    "--set" "frontend.image.tag=${IMAGE_TAG}"
    "--set" "secrets.postgresPassword=${POSTGRES_PASSWORD}"
    "--set" "secrets.keycloakAdminPassword=${KEYCLOAK_ADMIN_PASSWORD}"
    "--set" "secrets.keycloakAdminClientSecret=${KC_ADMIN_CLIENT_SECRET}"
  )
  [ -n "${OPENAI_API_KEY}"    ] && SET_ARGS+=("--set" "secrets.openaiApiKey=${OPENAI_API_KEY}")
  [ -n "${ANTHROPIC_API_KEY}" ] && SET_ARGS+=("--set" "secrets.anthropicApiKey=${ANTHROPIC_API_KEY}")
  [ -n "${DD_API_KEY}"        ] && SET_ARGS+=("--set" "secrets.datadogApiKey=${DD_API_KEY}")

  helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" --create-namespace \
    -f "${CHART_DIR}/values.yaml" \
    -f "${CHART_DIR}/values-local.yaml" \
    "${SET_ARGS[@]}" \
    --timeout 15m
  success "Helm deploy complete."
  phase_done "helm-deploy"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Wait for Keycloak
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 7: Keycloak readiness ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if kubectl rollout status deployment/"${RELEASE}-keycloak" \
    -n "${NAMESPACE}" --timeout=8m 2>/dev/null; then
  success "Keycloak deployment ready."
  phase_done "keycloak-ready"
else
  warn "Keycloak not ready in 8 min — continuing. Check: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=keycloak"
  phase_warned "keycloak-slow"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — Cloudflared
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 8: Cloudflare Tunnel ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  kubectl apply -f "${REPO_ROOT}/k8s/cloudflare/cloudflared-deployment.yaml"
  # Restart only if the pod is not running cleanly
  CF_STATUS=$(kubectl get deployment cloudflared -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${CF_STATUS}" != "1" ]; then
    info "Restarting cloudflared (currently ${CF_STATUS}/1 ready)..."
    kubectl rollout restart deployment/cloudflared -n "${NAMESPACE}"
    kubectl rollout status deployment/cloudflared -n "${NAMESPACE}" --timeout=90s \
      && success "cloudflared running." \
      || warn "cloudflared slow — check: kubectl logs -n ${NAMESPACE} -l app=cloudflared"
  else
    skip "cloudflared (1/1 ready)"
    phase_skipped "cloudflared"
  fi
  phase_done "cloudflared"
else
  skip "cloudflared (CLOUDFLARE_TUNNEL_TOKEN not set)"
  phase_skipped "cloudflared"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 9 — Istio service mesh
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 9: Istio ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  skip "Istio (istiod)"
  phase_skipped "istio"
else
  info "Installing Istio..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update istio 2>/dev/null || true
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install istio-base   istio/base      -n istio-system --wait --timeout=120s
  helm upgrade --install istiod       istio/istiod    -n istio-system --wait --timeout=300s
  helm upgrade --install istio-ingressgateway istio/gateway \
    -n istio-system --wait --timeout=120s --set service.type=NodePort
  success "Istio installed."
  phase_done "istio"
fi
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 10 — Datadog Agent
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 10: Datadog Agent ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if [ -z "${DD_API_KEY}" ]; then
  skip "Datadog (DD_API_KEY not set)"
  phase_skipped "datadog"
elif kubectl get deployment datadog-operator -n datadog >/dev/null 2>&1; then
  skip "Datadog Operator (already installed)"
  # Always sync the API key secret in case it changed
  kubectl create secret generic datadog-secret \
    --from-literal=api-key="${DD_API_KEY}" \
    -n datadog --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  phase_skipped "datadog"
else
  info "Installing Datadog Operator..."
  helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
  helm repo update datadog 2>/dev/null || true
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install datadog-operator datadog/datadog-operator \
    --namespace datadog --set image.pullPolicy=IfNotPresent --wait --timeout=120s
  kubectl create secret generic datadog-secret \
    --from-literal=api-key="${DD_API_KEY}" \
    -n datadog --dry-run=client -o yaml | kubectl apply -f -
  DD_SITE="$(_c "${DD_SITE:-datadoghq.com}")"
  kubectl apply -f - <<DDAGENT
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
  namespace: datadog
spec:
  global:
    clusterName: "${CLUSTER_NAME}"
    site: "${DD_SITE}"
    credentials:
      apiSecret:
        secretName: "datadog-secret"
        keyName: "api-key"
    kubelet:
      tlsVerify: false
  features:
    logCollection:
      enabled: true
      containerCollectAll: true
    apm:
      enabled: true
    liveProcessCollection:
      enabled: false
    orchestratorExplorer:
      enabled: true
  override:
    nodeAgent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DD_KUBELET_TLS_VERIFY
          value: "false"
DDAGENT
  success "Datadog Agent installed."
  phase_done "datadog"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 11 — CoreDNS patch (AI API hosts)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 11: CoreDNS AI API hosts ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
ANTHROPIC_IP=$(python3 -c "import socket; print(socket.gethostbyname('api.anthropic.com'))" 2>/dev/null || echo "")
OPENAI_IP=$(python3 -c    "import socket; print(socket.gethostbyname('api.openai.com'))"    2>/dev/null || echo "")
if [ -n "${ANTHROPIC_IP}" ] && [ -n "${OPENAI_IP}" ]; then
  COREDNS_CM=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  CURRENT_ANTHROPIC=$(echo "${COREDNS_CM}" | grep -o '[0-9.]*  *api\.anthropic\.com' | awk '{print $1}' || echo "")
  CURRENT_OPENAI=$(   echo "${COREDNS_CM}" | grep -o '[0-9.]*  *api\.openai\.com'    | awk '{print $1}' || echo "")
  if [ "${CURRENT_ANTHROPIC}" = "${ANTHROPIC_IP}" ] && [ "${CURRENT_OPENAI}" = "${OPENAI_IP}" ]; then
    skip "CoreDNS (IPs unchanged: Anthropic=${ANTHROPIC_IP}, OpenAI=${OPENAI_IP})"
    phase_skipped "coredns"
  else
    info "Updating CoreDNS hosts (Anthropic: ${ANTHROPIC_IP}, OpenAI: ${OPENAI_IP})..."
    STRIPPED=$(echo "${COREDNS_CM}" | python3 -c "
import sys, re
cm = sys.stdin.read()
# Remove any existing hosts {} block containing our entries
cm = re.sub(r'[ \t]*hosts \{[^}]*api\.(?:anthropic|openai)\.com[^}]*\}\n?', '', cm)
print(cm)" 2>/dev/null || echo "${COREDNS_CM}")
    HOSTS_BLOCK="        hosts {\n            ${ANTHROPIC_IP} api.anthropic.com\n            ${OPENAI_IP} api.openai.com\n            fallthrough\n        }"
    NEW_CM=$(echo "${STRIPPED}" | sed "s/        kubernetes cluster.local/${HOSTS_BLOCK}\n        kubernetes cluster.local/")
    kubectl create configmap coredns -n kube-system \
      --from-literal=Corefile="${NEW_CM}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl rollout restart deployment/coredns -n kube-system >/dev/null
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s >/dev/null
    success "CoreDNS updated."
    phase_done "coredns"
  fi
else
  warn "Cannot resolve AI API hosts from WSL2 — skipping CoreDNS patch."
  phase_warned "coredns-unresolvable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 12 — Ingress port-forward (WSL2 → Windows localhost)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 12: Ingress port-forward ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if pgrep -f "kubectl port-forward.*ingress-nginx" >/dev/null 2>&1; then
  skip "ingress port-forward (already running)"
  phase_skipped "port-forward"
else
  pkill -f "kubectl port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward svc/ingress-nginx-controller \
    8080:80 8443:443 -n ingress-nginx --address=0.0.0.0 \
    >/tmp/pf-ingress.log 2>&1 &
  disown
  sleep 2
  pgrep -f "kubectl port-forward.*ingress-nginx" >/dev/null \
    && { success "Ingress port-forward active (0.0.0.0:8080, 0.0.0.0:8443)."; phase_done "port-forward"; } \
    || { warn "Port-forward failed — check /tmp/pf-ingress.log"; phase_warned "port-forward"; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 13 — WSL2 HTTPS proxy (AI API traffic from pods)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 13: WSL2 HTTPS proxy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
PROXY_SCRIPT="${SCRIPT_DIR}/k8s-proxy.py"
if [ ! -f "${PROXY_SCRIPT}" ]; then
  skip "WSL2 proxy (k8s-proxy.py not found)"
  phase_skipped "wsl2-proxy"
elif pgrep -f "k8s-proxy.py" >/dev/null 2>&1; then
  skip "WSL2 proxy (already running)"
  phase_skipped "wsl2-proxy"
else
  pkill -f "k8s-proxy.py" 2>/dev/null || true
  sleep 1
  nohup python3 "${PROXY_SCRIPT}" >/tmp/k8s-proxy.log 2>&1 &
  disown
  sleep 1
  pgrep -f "k8s-proxy.py" >/dev/null \
    && { success "WSL2 proxy running on :3128."; phase_done "wsl2-proxy"; } \
    || { warn "Proxy failed — check /tmp/k8s-proxy.log"; phase_warned "wsl2-proxy"; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 14 — ArgoCD
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 14: ArgoCD ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  skip "ArgoCD (already installed)"
  phase_skipped "argocd"
else
  info "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo 2>/dev/null || true
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --set server.insecure=true --wait --timeout=300s
  success "ArgoCD installed."
  phase_done "argocd"
fi
if kubectl get svc argocd-server -n argocd >/dev/null 2>&1; then
  if ! pgrep -f "kubectl port-forward.*argocd" >/dev/null 2>&1; then
    pkill -f "kubectl port-forward.*argocd" 2>/dev/null || true
    nohup kubectl port-forward svc/argocd-server 8088:80 \
      -n argocd --address=0.0.0.0 >/tmp/pf-argocd.log 2>&1 &
    disown
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Startup complete${NC}\n\n"

printf "  ${GREEN}Done${NC}    (${#DONE[@]}): "
printf '%s  ' "${DONE[@]}" 2>/dev/null || true; printf '\n'
printf "  ${CYAN}Skipped${NC} (${#SKIPPED[@]}): "
printf '%s  ' "${SKIPPED[@]}" 2>/dev/null || true; printf '\n'
[ ${#WARNED[@]} -gt 0 ] && {
  printf "  ${YELLOW}Warned${NC}  (${#WARNED[@]}): "
  printf '%s  ' "${WARNED[@]}" 2>/dev/null || true; printf '\n'
}

printf "\n  Pod status:\n"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | while read -r name ready status _rest; do
      split_r="${ready%/*}"; split_t="${ready#*/}"
      if [ "${split_r}" = "${split_t}" ] && [ "${split_r}" != "0" ]; then
        printf "    ${GREEN}✓${NC}  %-45s %s\n" "${name}" "${ready}"
      else
        printf "    ${YELLOW}⚠${NC}  %-45s %s  (${status})\n" "${name}" "${ready}"
      fi
    done

printf "\n  ── URLs ──────────────────────────────────────────────────────\n"
[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ] && \
  printf "  Public  :  https://banking-app.eaglesoncloude.com\n"
printf "  Local   :  http://techbleat-bank.local  (needs netsh below)\n"
printf "  Keycloak:  http://keycloak.techbleat-bank.local/admin\n"
printf "  ArgoCD  :  http://localhost:8088\n"
printf "  Demo    :  bankingdemo / Demo@2024\n"

printf "\n  ── Windows netsh portproxy (run once as Admin after reboot) ──\n"
printf "  ${YELLOW}Run k8s/scripts/portproxy.ps1 as Administrator${NC}\n"
printf "  or manually:\n"
printf "    netsh interface portproxy add v4tov4 listenport=80  listenaddress=127.0.0.1 connectport=8080 connectaddress=127.0.0.1\n"
printf "    netsh interface portproxy add v4tov4 listenport=443 listenaddress=127.0.0.1 connectport=8443 connectaddress=127.0.0.1\n"

printf "\n  ── Auto-start on Windows login ───────────────────────────────\n"
printf "  Register Task Scheduler (one-time, elevated PowerShell):\n"
printf "    See k8s/scripts/startup-windows.ps1 for the exact command.\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
