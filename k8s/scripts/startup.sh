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
TS()      { date '+%H:%M:%S'; }
info()    { printf "${CYAN}[$(TS) startup]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[$(TS) startup] ✓${NC}  %s\n" "$*"; }
skip()    { printf "${CYAN}[$(TS) startup] →${NC}  %s — already OK, skipping.\n" "$*"; }
warn()    { printf "${YELLOW}[$(TS) startup] ⚠${NC}  %s\n" "$*" >&2; }
die()     { printf "${RED}[$(TS) startup] ✗${NC}  %s\n" "$*" >&2; exit 1; }

# ── parse flags ───────────────────────────────────────────────────────────────
SKIP_BUILD=0
FORCE_DEPLOY=0
for arg in "$@"; do
  case "$arg" in
    --skip-build|-s) SKIP_BUILD=1 ;;
    --force-deploy|-f) FORCE_DEPLOY=1 ;;
    --help|-h)
      echo "Usage: bash k8s/scripts/startup.sh [--skip-build] [--force-deploy]"
      echo "  (no flags)     full deploy — builds and pushes images"
      echo "  --skip-build   recovery mode — uses images already in minikube"
      echo "  --force-deploy force helm upgrade even when pods are running"
      echo "                 (needed to re-run provisioner after a failed hook)"
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

# Strip Windows carriage returns from every secret, then apply defaults.
# Order matters: strip first so a bare \r (Windows "empty" line) doesn't
# prevent the :- default from firing.
_c() { printf '%s' "${1:-}" | tr -d '\r'; }
_cs() { local v; v="$(_c "${1:-}")"; printf '%s' "${v:-${2:-}}"; }
POSTGRES_PASSWORD="$(_cs "${POSTGRES_PASSWORD}" "bankingdev2026")"
KEYCLOAK_ADMIN_PASSWORD="$(_cs "${KEYCLOAK_ADMIN_PASSWORD}" "admin")"
KC_ADMIN_CLIENT_SECRET="$(_cs "${KC_ADMIN_CLIENT_SECRET}" "localdevsecret2026")"
OPENAI_API_KEY="$(_c "${OPENAI_API_KEY:-}")"
ANTHROPIC_API_KEY="$(_c "${ANTHROPIC_API_KEY:-}")"
DD_API_KEY="$(_c "${DD_API_KEY:-}")"
CLOUDFLARE_TUNNEL_TOKEN="$(_c "${CLOUDFLARE_TUNNEL_TOKEN:-}")"
KEYCLOAK_PUBLIC_URL="$(_c "${KEYCLOAK_PUBLIC_URL:-http://keycloak.techbleat-bank.local}")"
GITHUB_USERNAME="$(_c "${GITHUB_USERNAME:-}")"
DOCKERHUB_USERNAME="$(_c "${DOCKERHUB_USERNAME:-}")"
# When --skip-build, use the previously deployed image tag from Helm rather than
# the current git SHA. The git SHA changes on every commit but images are only
# built by GitHub Actions — using a tag that was never pushed causes ImagePullBackOff
# and the keycloak-provisioner hook hangs waiting for Keycloak that can never start.
if [ "${SKIP_BUILD}" = "1" ]; then
  # 1st choice: tag from the running Helm release (most reliable)
  _DEPLOYED_TAG=$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
    | python3 -c "import sys,json; v=json.load(sys.stdin); print(v.get('userService',{}).get('image',{}).get('tag',''))" \
    2>/dev/null || echo "")
  # 2nd choice: tag already loaded in minikube's image cache
  _MINIKUBE_TAG=$(minikube image ls --profile "${CLUSTER_NAME}" 2>/dev/null \
    | grep -E "${GITHUB_USERNAME:-${DOCKERHUB_USERNAME:-}}/user-service:" \
    | head -1 | sed 's/.*://' | tr -d ' ' || echo "")
  if [ -n "${_DEPLOYED_TAG}" ]; then
    IMAGE_TAG="${_DEPLOYED_TAG}"
    info "Using previously deployed image tag: ${IMAGE_TAG}"
  elif [ -n "${_MINIKUBE_TAG}" ]; then
    IMAGE_TAG="${_MINIKUBE_TAG}"
    info "Using image tag found in minikube cache: ${IMAGE_TAG}"
  elif [ -n "${IMAGE_TAG:-}" ]; then
    IMAGE_TAG="$(_c "${IMAGE_TAG}")"
    info "Using IMAGE_TAG from environment: ${IMAGE_TAG}"
  else
    die "Cannot determine image tag for --skip-build. Either:
  1. Set IMAGE_TAG=<tag> in .env (use the tag from your last successful build)
  2. Run without --skip-build to rebuild images"
  fi
else
  IMAGE_TAG="$(_c "${IMAGE_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo latest)}")"
fi

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
printf "\n${BOLD}━━ Phase 0: Prerequisites ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
for cmd in docker minikube kubectl helm; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} not found in PATH."
done
docker info >/dev/null 2>&1 || die "Docker daemon not responding. Start Docker Desktop."
success "docker, minikube, kubectl, helm — all present."
phase_done "prerequisites"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — minikube cluster
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 1: minikube cluster ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
if minikube status --profile "${CLUSTER_NAME}" 2>/dev/null | grep -q "Running"; then
  skip "minikube '${CLUSTER_NAME}'"
  phase_skipped "minikube"
else
  info "Starting minikube '${CLUSTER_NAME}'..."
  minikube start \
    --profile "${CLUSTER_NAME}" \
    --driver=docker \
    --cpus=4 \
    --memory=10g \
    --disk-size=30g
  success "minikube started."
  phase_done "minikube"
fi
kubectl config use-context "${CLUSTER_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — NGINX ingress controller
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 2: NGINX ingress controller ━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
  kubectl rollout status deployment/ingress-nginx-controller \
    --namespace ingress-nginx --timeout=300s
  success "ingress-nginx installed."
  phase_done "ingress-nginx"
fi
# Always remove admission webhooks — they cause context deadline exceeded on minikube
kubectl delete validatingwebhookconfigurations ingress-nginx-admission \
  --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2.5 — Local PersistentVolumes
# The minikube storage-provisioner can go missing after node restarts.  We
# pre-create hostPath PVs for kafka-data, postgres-backup, and redis-backup so
# PVCs bind immediately even when the provisioner is absent.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 2.5: Local PersistentVolumes ━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
_LOCAL_PVS="${SCRIPT_DIR}/../manifests/local-pvs.yaml"
if [ -f "${_LOCAL_PVS}" ]; then
  # Clear stale claimRef on any Released PV so it becomes Available for new PVCs.
  for _pv in kafka-data-pv postgres-backup-pv redis-backup-pv; do
    _pv_phase=$(kubectl get pv "${_pv}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${_pv_phase}" = "Released" ]; then
      info "Clearing Released claimRef on ${_pv} → Available"
      kubectl patch pv "${_pv}" --type=json \
        -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    fi
  done
  kubectl apply -f "${_LOCAL_PVS}" >/dev/null
  success "Local PVs applied (kafka-data-pv, postgres-backup-pv, redis-backup-pv)."
  phase_done "local-pvs"
else
  warn "k8s/manifests/local-pvs.yaml not found — PVCs may stay Pending if provisioner is missing."
  phase_warned "local-pvs"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2.9 — Istio control plane (must run BEFORE Helm deploy so that the
# security.istio.io/v1beta1 CRDs exist when istio.enabled=true is rendered)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 2.9: Istio control plane ━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  skip "Istio (istiod already running)"
  phase_skipped "istio-install"
else
  info "Installing Istio control plane via Helm (minimal profile)..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update istio 2>/dev/null || true
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install istio-base istio/base \
    -n istio-system --wait --timeout=120s
  helm upgrade --install istiod istio/istiod \
    -n istio-system --wait --timeout=300s
  success "Istio control plane (istiod) installed."
  phase_done "istio-install"
fi
# Label the banking namespace so new pods get Envoy sidecars injected at startup.
# Existing pods are restarted later in Phase 9 after the app is deployed.
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Kubernetes namespace + secrets
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 3: Namespace + secrets ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply --validate=false -f -

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
# PHASE 3.5 — Sync postgres bankuser password
# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 always syncs the secret from .env. If .env changed since postgres
# was first initialized, the postgres bankuser password will differ from the
# secret — causing Keycloak and transaction-service to fail with
# "FATAL: password authentication failed" on any new pod.
#
# Fix: connect via unix socket (trust auth — no Kube secret read needed) and
# ALTER USER to sync postgres to whatever is now in POSTGRES_PASSWORD.
# Idempotent and safe on every startup.
printf "\n${BOLD}━━ Phase 3.5: Postgres password sync ━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
_PG_SYNC=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '/techbleat-bank-postgres/{print $1; exit}' || echo "")
if [ -n "${_PG_SYNC}" ]; then
  kubectl wait pod "${_PG_SYNC}" -n "${NAMESPACE}" \
    --for=condition=ready --timeout=30s >/dev/null 2>&1 || true
  if kubectl exec "${_PG_SYNC}" -n "${NAMESPACE}" -c postgres -- \
    psql -U bankuser -d postgres -c \
    "ALTER USER bankuser WITH PASSWORD '${POSTGRES_PASSWORD}'" >/dev/null 2>&1; then
    success "postgres bankuser password synced to match secret."
    phase_done "postgres-password-sync"
  else
    warn "postgres bankuser password sync failed — Keycloak may fail to connect."
    phase_warned "postgres-password-sync"
  fi
else
  skip "postgres not yet running — bankuser password sync will run on next startup after postgres starts."
  phase_skipped "postgres-password-sync"
fi

# Restart finance-agent if it's already running so it picks up the freshly
# synced API keys from banking-app-secrets (needed after ArgoCD secret wipes).
_FA_RUNNING=$(timeout 5 kubectl get deployment "${RELEASE}-finance-agent" \
  -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
if [ -n "${_FA_RUNNING}" ] && ([ -n "${OPENAI_API_KEY}" ] || [ -n "${ANTHROPIC_API_KEY}" ]); then
  kubectl rollout restart deployment/"${RELEASE}-finance-agent" -n "${NAMESPACE}" >/dev/null 2>&1 || true
  info "finance-agent restarted to pick up refreshed API keys."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Preload third-party images
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 4: Third-party images ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
printf "\n${BOLD}━━ Phase 5: Service images ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
printf "\n${BOLD}━━ Phase 6: Helm deploy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"

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
    # Verify key pods exist (use pod check — apps/v1 deployment queries can stall)
    _DP=$(timeout 8 kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true)
    KC_EXISTS=$(printf '%s\n' "${_DP}" | grep -c "techbleat-bank-keycloak" || true)
    FE_EXISTS=$(printf '%s\n' "${_DP}" | grep -c "techbleat-bank-frontend"  || true)
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

# Delete Kafka PVC on fresh installs only — skip when Kafka is already running
# (PVC finalizer blocks deletion indefinitely while Kafka has the volume mounted)
if [ "${SKIP_BUILD}" != "1" ]; then
  kubectl delete pvc "kafka-data-${RELEASE}-kafka-0" -n "${NAMESPACE}" \
    --ignore-not-found --wait=false 2>/dev/null || true
  # PVC deletion moves our Retain PV to Released. Clear the claimRef now so the
  # new PVC that Helm creates can bind immediately (no provisioner needed).
  sleep 2
  for _pv in kafka-data-pv postgres-backup-pv redis-backup-pv; do
    _pv_phase=$(kubectl get pv "${_pv}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${_pv_phase}" = "Released" ]; then
      kubectl patch pv "${_pv}" --type=json \
        -p='[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
      info "Cleared Released claimRef on ${_pv}"
    fi
  done
fi


# --skip-build shortcut: if key pods are already running (even when Helm state was
# manually deleted), skip the upgrade to avoid re-firing hooks on a live stack.
# Uses pod checks (core API v1) instead of deployment checks (apps/v1 can stall).
SKIP_HELM=0
if [ "${SKIP_BUILD}" = "1" ]; then
  info "Checking if cluster pods are already running..."
  _PODS=$(timeout 8 kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true)
  _KC=$(printf '%s\n' "${_PODS}" | grep -c "techbleat-bank-keycloak" || true)
  _FE=$(printf '%s\n' "${_PODS}" | grep -c "techbleat-bank-frontend"  || true)
  if [ "${_KC}" -gt 0 ] && [ "${_FE}" -gt 0 ]; then
    # Check if Keycloak needs a mode change: start-dev (H2) → start (productionMode).
    # Read what values-local.yaml says; check the running pod's actual args.
    _KC_POD=$(printf '%s\n' "${_PODS}" | awk '/techbleat-bank-keycloak/{print $1; exit}')
    _KC_ARG0=$(timeout 5 kubectl get pod "${_KC_POD}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.containers[?(@.name=="keycloak")].args[0]}' 2>/dev/null || echo "")
    _WANT_PROD=$(grep 'productionMode:' "${CHART_DIR}/values-local.yaml" 2>/dev/null \
      | awk '{print $2}' | tr -d ' \r' | head -1 || echo "false")
    if [ "${FORCE_DEPLOY}" = "1" ]; then
      info "Helm deploy forced (--force-deploy) — running upgrade to re-trigger provisioner hook."
      # SKIP_HELM stays 0 so the upgrade and provisioner hook run below.
    elif [ "${_KC_ARG0}" = "start-dev" ] && [ "${_WANT_PROD}" = "true" ]; then
      info "Keycloak is running in start-dev (H2) but productionMode: true is configured — upgrade needed."
      # SKIP_HELM stays 0 so the upgrade runs below and applies productionMode.
    else
      skip "Helm deploy (pods already running — skipping re-deploy in --skip-build mode)"
      SKIP_HELM=1
      phase_skipped "helm-deploy"
      # Restart any unhealthy pods without a full Helm upgrade
      UNHEALTHY=$(printf '%s\n' "${_PODS}" \
        | awk '{split($2,r,"/"); if (r[1]!=r[2] || r[1]=="0") print $1}' || true)
      if [ -n "${UNHEALTHY}" ]; then
        warn "Some pods not ready — restarting: ${UNHEALTHY}"
        for pod in ${UNHEALTHY}; do
          timeout 5 kubectl rollout restart deployment -n "${NAMESPACE}" \
            --selector="$(timeout 5 kubectl get pod "${pod}" -n "${NAMESPACE}" \
              -o jsonpath='app.kubernetes.io/name={.metadata.labels.app\.kubernetes\.io/name}' \
              2>/dev/null || true)" 2>/dev/null || true
        done
      fi
    fi
  else
    info "No running pods found — proceeding with Helm deploy."
  fi
fi

if [ "${SKIP_HELM}" = "0" ] && ([ "${FORCE_DEPLOY}" = "1" ] || [ "${HELM_STATUS}" != "deployed" ] || [ "${CURRENT_TAG:-}" != "${IMAGE_TAG}" ] || [ "${SKIP_BUILD}" != "1" ]); then
  # Pre-create keycloakdb if postgres is already running (init scripts only run on fresh PVC).
  # This must happen BEFORE the helm upgrade so Keycloak productionMode can start cleanly.
  _PRE_PG=$(timeout 5 kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '/techbleat-bank-postgres/{print $1; exit}' || echo "")
  if [ -n "${_PRE_PG}" ]; then
    # Wait for postgres pod to be fully ready before running psql
    info "Waiting for postgres pod to be ready (max 120s)..."
    kubectl wait pod "${_PRE_PG}" -n "${NAMESPACE}" \
      --for=condition=ready --timeout=120s 2>/dev/null || true
    # Use -d postgres (always exists) so psql can connect regardless of bankingdb state
    _PRE_KC_DB=$(timeout 10 kubectl exec "${_PRE_PG}" -n "${NAMESPACE}" -c postgres -- \
      psql -U bankuser -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='keycloakdb'" 2>/dev/null \
      | tr -d '[:space:]' || echo "")
    if [ "${_PRE_KC_DB}" != "1" ]; then
      info "Pre-creating keycloakdb before Helm upgrade (needed for Keycloak productionMode)..."
      if timeout 20 kubectl exec "${_PRE_PG}" -n "${NAMESPACE}" -c postgres -- \
          psql -U bankuser -d postgres -c "CREATE DATABASE keycloakdb" 2>/dev/null; then
        success "keycloakdb pre-created — Keycloak productionMode can now connect."
      else
        die "keycloakdb creation failed. Keycloak productionMode cannot start without it.
  Fix manually, then re-run this script:
    kubectl exec -it ${_PRE_PG} -n ${NAMESPACE} -c postgres -- psql -U bankuser -d postgres -c 'CREATE DATABASE keycloakdb'"
      fi
    else
      skip "keycloakdb (already exists in PostgreSQL)"
    fi
  fi

  # Helm adoption: secrets created by kubectl (Phase 3) lack Helm's ownership
  # labels/annotations.  Helm refuses to install if it encounters an unowned
  # resource that its chart also templates.  Annotate them first so Helm can
  # adopt them without touching their data.
  for _secret in banking-app-secrets cloudflare-tunnel-token; do
    if kubectl get secret "${_secret}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      kubectl annotate secret "${_secret}" -n "${NAMESPACE}" \
        "meta.helm.sh/release-name=${RELEASE}" \
        "meta.helm.sh/release-namespace=${NAMESPACE}" \
        --overwrite 2>/dev/null || true
      kubectl label secret "${_secret}" -n "${NAMESPACE}" \
        "app.kubernetes.io/managed-by=Helm" \
        --overwrite 2>/dev/null || true
      info "Helm adoption labels applied to secret/${_secret}"
    fi
  done

  # Helm adoption: NetworkPolicies that were kubectl-applied directly (e.g. as live
  # hotfixes) also lack ownership metadata. Adopt them before helm upgrade.
  for _np in allow-istio-control-plane-egress allow-cloudflared-egress allow-frontend-egress; do
    if kubectl get networkpolicy "${_np}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      kubectl annotate networkpolicy "${_np}" -n "${NAMESPACE}" \
        "meta.helm.sh/release-name=${RELEASE}" \
        "meta.helm.sh/release-namespace=${NAMESPACE}" \
        --overwrite 2>/dev/null || true
      kubectl label networkpolicy "${_np}" -n "${NAMESPACE}" \
        "app.kubernetes.io/managed-by=Helm" \
        --overwrite 2>/dev/null || true
      info "Helm adoption labels applied to networkpolicy/${_np}"
    fi
  done

  # Suspend ArgoCD auto-sync before upgrading so ArgoCD does not reconcile
  # the release back to git state and overwrite our env changes mid-deploy.
  # ArgoCD tracking annotation on the Keycloak deployment confirms it manages this app.
  if kubectl get application "${RELEASE}" -n argocd >/dev/null 2>&1; then
    info "Suspending ArgoCD auto-sync for ${RELEASE} (prevents silent reverts during deploy)..."
    kubectl patch application "${RELEASE}" -n argocd \
      --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null \
      && info "ArgoCD auto-sync suspended." \
      || warn "Could not patch ArgoCD app — continuing without suspension."
  fi

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
  [ -n "${OPENAI_API_KEY:-}"      ] && SET_ARGS+=("--set" "secrets.openaiApiKey=${OPENAI_API_KEY}")
  [ -n "${ANTHROPIC_API_KEY:-}"  ] && SET_ARGS+=("--set" "secrets.anthropicApiKey=${ANTHROPIC_API_KEY}")
  [ -n "${DD_API_KEY:-}"         ] && SET_ARGS+=("--set" "secrets.datadogApiKey=${DD_API_KEY}")
  [ -n "${DEMO_USER_PASSWORD:-}" ] && SET_ARGS+=("--set" "secrets.keycloakDemoPassword=${DEMO_USER_PASSWORD}")

  _HELM_OK=0
  helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" --create-namespace \
    -f "${CHART_DIR}/values.yaml" \
    -f "${CHART_DIR}/values-local.yaml" \
    "${SET_ARGS[@]}" \
    --timeout 20m && _HELM_OK=1 || true
  if [ "${_HELM_OK}" = "1" ]; then
    success "Helm deploy complete."
    phase_done "helm-deploy"
  else
    warn "Helm deploy failed (commonly a hook timeout — Keycloak races postgres init on fresh clusters)."
    warn "Phase 6.5 will fix dependencies (keycloakdb + password sync), then Phase 6.5b will retry."
    phase_warned "helm-deploy-partial"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6.5 — Ensure keycloakdb exists in PostgreSQL
# Keycloak productionMode requires a "keycloakdb" database. The postgres init
# scripts only run on a fresh PVC — on existing installs we must create it here.
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 6.5: keycloakdb database ━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
# After a helm upgrade the postgres pod may be briefly recreating — retry up to 60s.
_PG_POD=""
for _pg_i in $(seq 1 12); do
  _PG_POD=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '/techbleat-bank-postgres/{print $1; exit}') || true
  [ -n "${_PG_POD}" ] && break
  sleep 5
done
if [ -n "${_PG_POD}" ]; then
  # Wait for postgres to be ready (max 120s)
  # Wait for postgres (kubectl wait is more reliable than jsonpath container readiness)
  kubectl wait pod "${_PG_POD}" -n "${NAMESPACE}" \
    --for=condition=ready --timeout=120s 2>/dev/null || true
  # Use -d postgres (always exists) so psql connects even if bankingdb hasn't been created yet
  _KC_DB=$(timeout 10 kubectl exec "${_PG_POD}" -n "${NAMESPACE}" -c postgres -- \
    psql -U bankuser -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='keycloakdb'" 2>/dev/null \
    | tr -d '[:space:]' || echo "")
  if [ "${_KC_DB}" = "1" ]; then
    skip "keycloakdb (already exists in PostgreSQL)"
    phase_skipped "keycloakdb"
  else
    info "Creating keycloakdb in PostgreSQL (Keycloak productionMode requires it)..."
    if timeout 15 kubectl exec "${_PG_POD}" -n "${NAMESPACE}" -c postgres -- \
        psql -U bankuser -d postgres -c "CREATE DATABASE keycloakdb" 2>/dev/null; then
      success "keycloakdb created."
      phase_done "keycloakdb"
      # Restart Keycloak so it can now connect to the newly created database
      info "Restarting Keycloak to pick up new keycloakdb..."
      kubectl rollout restart deployment/"${RELEASE}-keycloak" -n "${NAMESPACE}" 2>/dev/null || true
    else
      warn "keycloakdb creation failed — check postgres pod logs."
      phase_warned "keycloakdb"
    fi
  fi

  # ── Post-deploy bankuser password sync ──────────────────────────────────────
  # Phase 3.5 skips this on fresh clusters (postgres not running at that point).
  # Running it here (after Helm deploys postgres) ensures the password inside
  # postgres always matches the secret. Idempotent and safe on every startup.
  if kubectl exec "${_PG_POD}" -n "${NAMESPACE}" -c postgres -- \
      psql -U bankuser -d postgres -c \
      "ALTER USER bankuser WITH PASSWORD '${POSTGRES_PASSWORD}'" >/dev/null 2>&1; then
    success "postgres bankuser password synced (post-deploy)."
    for _dep_svc in user-service transaction-service; do
      kubectl rollout restart deployment/"${RELEASE}-${_dep_svc}" \
        -n "${NAMESPACE}" >/dev/null 2>&1 || true
    done
    info "Restarted user-service and transaction-service to re-establish postgres connections."
  else
    warn "postgres bankuser password sync (post-deploy) failed — check postgres logs."
  fi
else
  warn "No postgres pod found — keycloakdb check skipped."
  phase_warned "keycloakdb"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6.5b — Helm retry after fresh-cluster hook timeout
# On a fresh cluster, Keycloak races postgres initialization. The provisioner
# hook fires before Keycloak is ready → hook times out → Helm exits non-zero.
# Phase 6.5 just created keycloakdb and synced the bankuser password, so a
# second Helm upgrade succeeds because Keycloak can start cleanly.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${_HELM_OK:-1}" = "0" ] && [ "${SKIP_HELM:-0}" = "0" ]; then
  printf "\n${BOLD}━━ Phase 6.5b: Helm retry ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
  info "Retrying Helm deploy (keycloakdb exists, password synced — Keycloak can now start cleanly)..."
  helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" --create-namespace \
    -f "${CHART_DIR}/values.yaml" \
    -f "${CHART_DIR}/values-local.yaml" \
    "${SET_ARGS[@]}" \
    --timeout 20m
  success "Helm deploy complete (retry succeeded)."
  phase_done "helm-deploy-retry"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Wait for Keycloak
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 7: Keycloak readiness ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
if kubectl rollout status deployment/"${RELEASE}-keycloak" \
    -n "${NAMESPACE}" --timeout=8m 2>/dev/null; then
  success "Keycloak deployment ready."
  phase_done "keycloak-ready"
else
  warn "Keycloak not ready in 8 min — continuing. Check: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=keycloak"
  phase_warned "keycloak-slow"
fi

# Verify Keycloak OIDC issuer setup.
# IMPORTANT: With KC_PROXY=edge, Keycloak determines the issuer scheme from the
# X-Forwarded-Proto header. Internal pod-to-pod requests (http://keycloak:8080/...)
# carry no X-Forwarded-Proto, so the discovery endpoint always returns http://.
# This is EXPECTED — real JWT tokens are issued via the ingress (https://) and
# carry the correct https:// issuer. We verify KEYCLOAK_ISSUER in user-service
# is configured correctly instead.
_US_POD=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '/techbleat-bank-user-service.*Running/{print $1; exit}' || echo "")
if [ -n "${_US_POD}" ]; then
  _KC_ISSUER_ENV=$(kubectl exec "${_US_POD}" -n "${NAMESPACE}" -c user-service -- \
    bash -c "echo \$KEYCLOAK_ISSUER" 2>/dev/null || echo "")
  if echo "${_KC_ISSUER_ENV}" | grep -q "^https://"; then
    success "KEYCLOAK_ISSUER in user-service: ${_KC_ISSUER_ENV} (https:// ✓)"
    phase_done "keycloak-issuer"
  elif [ -n "${_KC_ISSUER_ENV}" ]; then
    warn "KEYCLOAK_ISSUER in user-service is not https://: ${_KC_ISSUER_ENV}"
    warn "  Check publicKeycloakUrl in values-local.yaml — it must start with https://"
    phase_warned "keycloak-issuer"
  else
    warn "Could not read KEYCLOAK_ISSUER from user-service pod."
    phase_warned "keycloak-issuer"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — Cloudflared
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 8: Cloudflare Tunnel ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
# PHASE 9 — Istio sidecar injection (post-deploy)
# Restart all banking pods so Envoy sidecars are injected into every running
# container.  Skipped when sidecars are already present (2/2 ready containers).
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 9: Istio sidecar injection ━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
if ! kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  warn "istiod not found — Istio sidecar injection skipped."
  phase_warned "istio-sidecars"
else
  # Check whether any pod in the banking namespace lacks the istio-proxy container.
  # A pod with sidecars shows 2+ containers in READY column (e.g. 2/2).
  _PODS_WITHOUT_SIDECAR=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{split($2,r,"/"); if (r[2]=="1") print $1}' | head -5 || true)
  if [ -z "${_PODS_WITHOUT_SIDECAR}" ]; then
    skip "Istio sidecars (all pods already have 2+ containers)"
    phase_skipped "istio-sidecars"
  else
    info "Restarting banking pods to inject Envoy sidecars..."
    kubectl rollout restart deployment -n "${NAMESPACE}" 2>/dev/null || true
    kubectl rollout restart statefulset -n "${NAMESPACE}" 2>/dev/null || true
    info "Waiting for pods to come back up with sidecars (max 5 min)..."
    kubectl wait pods -n "${NAMESPACE}" \
      --for=condition=ready --all --timeout=300s 2>/dev/null \
      && success "All pods ready with Envoy sidecars." \
      || warn "Some pods slow to restart — check: kubectl get pods -n ${NAMESPACE}"
    phase_done "istio-sidecars"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 10 — Datadog Agent
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 10: Datadog Agent ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
printf "\n${BOLD}━━ Phase 11: CoreDNS AI API hosts ━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
# PHASE 12 — Port-forwards (all services: ingress, postgres, keycloak, user-svc)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 12: Port-forwards ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"

# _release_port: kill every process holding a TCP listen port.
# Tries ss + lsof + fuser in parallel — lsof is unreliable in WSL2.
# Also calls powershell.exe to kill Windows-side holders (WSL2 virtual ports
# show a fake PID that Linux kill -9 cannot reach).
_release_port() {
  local port="$1"
  # ss (most reliable in WSL2)
  ss -Htlnp 2>/dev/null \
    | awk -v p=":${port} " '$0~p { match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1] }' \
    | xargs -r kill -9 2>/dev/null || true
  # lsof as second opinion
  command -v lsof >/dev/null 2>&1 && \
    lsof -ti:"${port}" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  # fuser as last resort
  command -v fuser >/dev/null 2>&1 && \
    fuser -k "${port}/tcp" 2>/dev/null || true
  # Windows-side holder: WSL2 virtual network ports show a fake Linux PID.
  # Ask PowerShell to kill the real Windows process holding this port.
  command -v powershell.exe >/dev/null 2>&1 && \
    powershell.exe -NonInteractive -Command \
      "Get-NetTCPConnection -LocalPort ${port} -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess | Sort-Object -Unique | ForEach-Object { Stop-Process -Id \$_ -Force -ErrorAction SilentlyContinue }" \
      2>/dev/null || true
}

# pf_ensure <match-pattern> <svc/name> <ports-string> <namespace> <logfile> <label> <local-port> [extra-ports...]
# Retries up to 3 times with SIGKILL escalation to handle WSL2 socket cleanup delays.
pf_ensure() {
  local pattern="$1" svc="$2" ports="$3" ns="$4" log="$5" label="$6"
  shift 6
  local kill_ports=("$@")

  local attempt
  for attempt in 1 2 3; do
    # SIGTERM first, wait 1s, then SIGKILL to ensure the process is dead
    pkill -f "kubectl port-forward.*${pattern}" 2>/dev/null || true
    sleep 1
    pkill -9 -f "kubectl port-forward.*${pattern}" 2>/dev/null || true

    # Force-release each local port (ss + lsof + fuser)
    for kp in "${kill_ports[@]:-}"; do
      [ -n "${kp}" ] && _release_port "${kp}"
    done
    sleep 3   # give WSL2 time to release sockets

    # Start the port-forward
    # shellcheck disable=SC2086
    nohup kubectl port-forward "${svc}" ${ports} -n "${ns}" \
      --address=0.0.0.0 >"${log}" 2>&1 &
    disown
    sleep 4   # wait for kubectl to establish the tunnel

    if pgrep -f "kubectl port-forward.*${pattern}" >/dev/null 2>&1; then
      success "port-forward ${label} active (${ports})"
      return 0
    fi

    local _err
    _err=$(tail -1 "${log}" 2>/dev/null || true)
    if [ "${attempt}" -lt 3 ]; then
      warn "port-forward ${label} attempt ${attempt}/3 failed: ${_err:-see ${log}} — retrying..."
      sleep 5
    else
      warn "port-forward ${label} failed after 3 attempts: ${_err:-see ${log}}"
      # Show what is actually holding the ports for debugging
      local _port_list
      _port_list=$(printf '%s|' "${kill_ports[@]:-}" | sed 's/|$//')
      [ -n "${_port_list}" ] && \
        ss -Htlnp 2>/dev/null | grep -E "${_port_list}" | \
        while read -r ln; do warn "  port holder: ${ln}"; done || true
    fi
  done
  return 1
}

PF_ANY_FAILED=0

# 1. Ingress (main web traffic — all services behind ingress-nginx)
# Forward HTTP on port 9080 (not 8080 — port 8080 is held by other system services).
# HTTPS (8443) is not forwarded: Cloudflare terminates TLS at the edge, local ingress
# has TLS disabled (ssl-redirect: false, tls: [] in values-local.yaml).
# Portproxy: 80→9080 and 443→9080 (see k8s/scripts/portproxy.ps1).
pf_ensure "ingress-nginx" \
  "svc/ingress-nginx-controller" "9080:80" \
  "ingress-nginx" "/tmp/pf-ingress.log" \
  "ingress (9080→80)" "9080" \
  || PF_ANY_FAILED=1

# 2. Postgres (direct DB access — backup, restore, pgAdmin)
if timeout 5 kubectl get svc "techbleat-bank-postgresql" -n "${NAMESPACE}" \
    >/dev/null 2>&1 || \
   timeout 5 kubectl get svc "techbleat-bank-postgres" -n "${NAMESPACE}" \
    >/dev/null 2>&1; then
  _PG_SVC=$(timeout 5 kubectl get svc -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '/techbleat-bank-post(gres|gresql)/{print $1; exit}')
  [ -n "${_PG_SVC}" ] && \
    pf_ensure "postgres" \
      "svc/${_PG_SVC}" "5432:5432" \
      "${NAMESPACE}" "/tmp/pf-postgres.log" \
      "postgres (5432→5432)" "5432" \
    || PF_ANY_FAILED=1
fi

# 3. Keycloak direct (bypass ingress for admin/recovery tasks)
if timeout 5 kubectl get svc "techbleat-bank-keycloak" -n "${NAMESPACE}" \
    >/dev/null 2>&1; then
  pf_ensure "keycloak.*8280" \
    "svc/techbleat-bank-keycloak" "8280:8080" \
    "${NAMESPACE}" "/tmp/pf-keycloak.log" \
    "keycloak-direct (8280→8080)" "8280" \
  || PF_ANY_FAILED=1
fi

# 4. User service (direct API access for development/debugging)
if timeout 5 kubectl get svc "techbleat-bank-user-service" -n "${NAMESPACE}" \
    >/dev/null 2>&1; then
  pf_ensure "user-service.*8081" \
    "svc/techbleat-bank-user-service" "8081:8080" \
    "${NAMESPACE}" "/tmp/pf-user-svc.log" \
    "user-service (8081→8080)" \
  || true  # non-fatal
fi

# 5. Finance agent (AI assistant direct access) — runs on port 9001
if timeout 5 kubectl get svc "techbleat-bank-finance-agent" -n "${NAMESPACE}" \
    >/dev/null 2>&1; then
  pf_ensure "finance-agent.*8082" \
    "svc/techbleat-bank-finance-agent" "8082:9001" \
    "${NAMESPACE}" "/tmp/pf-finance-agent.log" \
    "finance-agent (8082→9001)" \
  || true  # non-fatal
fi

[ "${PF_ANY_FAILED}" = "0" ] \
  && phase_done "port-forward" \
  || phase_warned "port-forward"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 13 — WSL2 HTTPS proxy (AI API traffic from pods)
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━ Phase 13: WSL2 HTTPS proxy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
printf "\n${BOLD}━━ Phase 14: ArgoCD ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  [$(TS)]${NC}\n"
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
# Always apply the Application manifest so ignoreDifferences protects secrets
# and auto-sync stays wired after ArgoCD restarts or a fresh install.
_ARGOCD_APP="${REPO_ROOT}/k8s/argocd/application.yaml"
if [ -f "${_ARGOCD_APP}" ]; then
  kubectl apply -f "${_ARGOCD_APP}" >/dev/null 2>&1 \
    && info "ArgoCD Application manifest applied (auto-sync + ignoreDifferences active)." \
    || warn "ArgoCD Application manifest apply failed — run: kubectl apply -f k8s/argocd/application.yaml"
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
printf "  ArgoCD  :  https://argocd-banking.eaglesoncloude.com  (local: http://localhost:8088)\n"
printf "  Demo    :  bankingdemo / Demo@2024\n"

printf "\n  ── Windows netsh portproxy (run once as Admin after reboot) ──\n"
printf "  ${YELLOW}Run k8s/scripts/portproxy.ps1 as Administrator${NC}\n"
printf "  or manually:\n"
printf "    netsh interface portproxy add v4tov4 listenport=80  listenaddress=127.0.0.1 connectport=9080 connectaddress=127.0.0.1\n"
printf "    netsh interface portproxy add v4tov4 listenport=443 listenaddress=127.0.0.1 connectport=9080 connectaddress=127.0.0.1\n"

printf "\n  ── Auto-start on Windows login ───────────────────────────────\n"
printf "  Register Task Scheduler (one-time, elevated PowerShell):\n"
printf "    See k8s/scripts/startup-windows.ps1 for the exact command.\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
