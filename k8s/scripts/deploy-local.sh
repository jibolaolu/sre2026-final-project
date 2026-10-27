#!/usr/bin/env bash
# deploy-local.sh — Deploy Techbleat Global Bank to a local minikube cluster.
#
# Prerequisites:
#   - Docker (24+)            https://docs.docker.com/get-docker/
#   - minikube                https://minikube.sigs.k8s.io/docs/start/
#   - kubectl (1.28+)         https://kubernetes.io/docs/tasks/tools/
#   - helm (3.15+)            https://helm.sh/docs/intro/install/
#   - A Docker Hub account    https://hub.docker.com/  (free tier is fine)
#
# Usage:
#   bash k8s/scripts/deploy-local.sh
#   (credentials are loaded automatically from .env at the repo root)
#
# Optional env vars:
#   POSTGRES_PASSWORD          (default: bankingdev2026)
#   KEYCLOAK_ADMIN_PASSWORD    (default: admin)
#   KC_ADMIN_CLIENT_SECRET     (default: localdevsecret2026)
#   SKIP_BUILD                 set to 1 to skip image build/push
#   SKIP_CLUSTER               set to 1 to skip minikube start
#   IMAGE_TAG                  override image tag (default: git short SHA)
set -euo pipefail
trap 'echo "[local] ERROR: script exited at line $LINENO (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/techbleat-bank"
REPO_ROOT="${SCRIPT_DIR}/../.."

CLUSTER_NAME="techbleat-bank"
NAMESPACE="banking"
RELEASE="techbleat-bank"

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-bankingdev2026}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KC_ADMIN_CLIENT_SECRET="${KC_ADMIN_CLIENT_SECRET:-localdevsecret2026}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_CLUSTER="${SKIP_CLUSTER:-0}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo latest)}"

info()    { printf '\033[0;36m[local]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[local]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[local]\033[0m  WARNING: %s\n' "$*" >&2; }
die()     { printf '\033[0;31m[local]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

# ── Prerequisites check ───────────────────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."
  command -v docker   >/dev/null 2>&1 || die "docker not found. Is Docker Desktop installed and in PATH?"
  command -v minikube >/dev/null 2>&1 || die "minikube not found. See https://minikube.sigs.k8s.io/docs/start/"
  command -v kubectl  >/dev/null 2>&1 || die "kubectl not found."
  command -v helm     >/dev/null 2>&1 || die "helm not found."
  docker info >/dev/null 2>&1         || die "Docker daemon not responding. Start Docker Desktop and try again."
  success "Prerequisites OK (docker, minikube, kubectl, helm)."
}

# ── WSL2 HTTPS proxy ─────────────────────────────────────────────────────────
# minikube pods (Docker driver) cannot reach the internet directly; this proxy
# relays HTTPS CONNECT tunnels from pods through WSL2 to the public internet.
start_wsl2_proxy() {
  if pgrep -f "k8s-proxy.py" >/dev/null 2>&1; then
    info "WSL2 HTTPS proxy already running."
    return
  fi
  local proxy_script="${SCRIPT_DIR}/k8s-proxy.py"
  if [ ! -f "${proxy_script}" ]; then
    warn "Proxy script not found at ${proxy_script} — skipping proxy start."
    warn "AI features (FinanceAgent) will not have internet access."
    return
  fi
  info "Starting WSL2 HTTPS proxy for minikube AI traffic..."
  nohup python3 "${proxy_script}" >/tmp/k8s-proxy.log 2>&1 &
  disown
  sleep 1
  if pgrep -f "k8s-proxy.py" >/dev/null 2>&1; then
    success "WSL2 proxy started on :3128 (log: /tmp/k8s-proxy.log)"
  else
    warn "Proxy failed to start — check /tmp/k8s-proxy.log"
  fi
}

# Auto-source .env from the repo root if it exists (keeps secrets out of shell history)
ENV_FILE="${REPO_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  info "Loaded environment from ${ENV_FILE}"
fi

# Strip Windows carriage returns from all secrets — prevents Postgres password hash mismatches
# on fresh PVC init and httpcore rejecting API keys as illegal header values
OPENAI_API_KEY="$(printf '%s' "${OPENAI_API_KEY:-}" | tr -d '\r')"
ANTHROPIC_API_KEY="$(printf '%s' "${ANTHROPIC_API_KEY:-}" | tr -d '\r')"
POSTGRES_PASSWORD="$(printf '%s' "${POSTGRES_PASSWORD}" | tr -d '\r')"
KEYCLOAK_ADMIN_PASSWORD="$(printf '%s' "${KEYCLOAK_ADMIN_PASSWORD}" | tr -d '\r')"
KC_ADMIN_CLIENT_SECRET="$(printf '%s' "${KC_ADMIN_CLIENT_SECRET}" | tr -d '\r')"
# Public-facing Keycloak URL baked into the frontend image at build time.
# Set to https://auth.<your-domain> when using Cloudflare Tunnel; defaults to local.
KEYCLOAK_PUBLIC_URL="$(printf '%s' "${KEYCLOAK_PUBLIC_URL:-http://keycloak.techbleat-bank.local}" | tr -d '\r')"

# ── Registry: GHCR (recommended) or Docker Hub ───────────────────────────────
# Set GITHUB_USERNAME in .env to push to ghcr.io/<username>/<service> (matches CI).
# Falls back to DOCKERHUB_USERNAME if GITHUB_USERNAME is not set.
GITHUB_USERNAME="$(printf '%s' "${GITHUB_USERNAME:-}" | tr -d '\r')"
DOCKERHUB_USERNAME="$(printf '%s' "${DOCKERHUB_USERNAME:-}" | tr -d '\r')"
IMAGE_TAG="$(printf '%s' "${IMAGE_TAG}" | tr -d '\r')"

if [ -n "${GITHUB_USERNAME}" ]; then
  IMAGE_REGISTRY="ghcr.io/${GITHUB_USERNAME}/"
  REGISTRY_LOGIN_HOST="ghcr.io"
  info "Using GHCR registry: ${IMAGE_REGISTRY}"
elif [ -n "${DOCKERHUB_USERNAME}" ]; then
  IMAGE_REGISTRY="${DOCKERHUB_USERNAME}/"
  REGISTRY_LOGIN_HOST="docker.io"
  info "Using Docker Hub registry: ${IMAGE_REGISTRY}"
else
  die "Set GITHUB_USERNAME (GHCR) or DOCKERHUB_USERNAME (Docker Hub) in .env before running this script."
fi
info "Image tag: ${IMAGE_TAG}"

# ── 0. Check prerequisites ────────────────────────────────────────────────────
check_prereqs

# ── 0b. Start WSL2 proxy (must run before pods need internet) ────────────────
start_wsl2_proxy

# ── 1. Start minikube cluster ─────────────────────────────────────────────────
if [ "${SKIP_CLUSTER}" != "1" ]; then
  if minikube status --profile "${CLUSTER_NAME}" 2>/dev/null | grep -q "Running"; then
    info "minikube profile '${CLUSTER_NAME}' already running — skipping start."
  else
    info "Starting minikube cluster '${CLUSTER_NAME}'..."
    minikube start \
      --profile "${CLUSTER_NAME}" \
      --driver=docker \
      --cni=bridge \
      --cpus=4 \
      --memory=6g \
      --disk-size=30g
    success "minikube cluster started."
  fi
fi

# Always point kubectl at the cluster
kubectl config use-context "${CLUSTER_NAME}"

# ── 2. Install NGINX ingress controller ───────────────────────────────────────
# Runs even with SKIP_CLUSTER=1 so re-runs after cluster deletion work correctly.
if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  info "Installing NGINX ingress controller via Helm..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.hostPort.enabled=false \
    --set controller.admissionWebhooks.enabled=false \
    --set controller.image.pullPolicy=IfNotPresent \
    --set controller.image.digest=""
  info "Waiting for ingress-nginx controller to be ready (up to 5 minutes)..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s
  success "NGINX ingress controller installed."
else
  info "NGINX ingress controller already installed."
fi

# ── Remove stale ingress admission webhooks (cause "context deadline exceeded") ─
# The ingress-nginx-admission webhook is created by the addon or old Helm installs.
# On minikube Docker+bridge, the kube-apiserver cannot reach webhook pods, so any
# Ingress resource creation hangs until timeout. Always purge these before deploying.
kubectl delete validatingwebhookconfigurations ingress-nginx-admission --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfigurations ingress-nginx-admission --ignore-not-found 2>/dev/null || true

# ── Pre-load third-party images into minikube ─────────────────────────────────
# Prevents Helm deploy from timing out while Keycloak/Postgres/Kafka are pulling
# large images from the internet inside the minikube VM.
_load_image_into_minikube() {
  local img=$1
  # Direct import into minikube's containerd via docker exec — more reliable than
  # 'minikube image load' which silently exits 0 on Docker-driver clusters.
  docker save "${img}" \
    | docker exec -i "${CLUSTER_NAME}" ctr --namespace k8s.io images import - \
    && return 0
  # Fallback to minikube image load if direct import fails
  minikube image load "${img}" --profile "${CLUSTER_NAME}"
}

preload_image() {
  local img=$1
  info "  Pre-loading ${img} into minikube..."
  if ! docker pull "${img}"; then
    printf '\033[0;33m[local]\033[0m  WARNING: docker pull failed for %s — will pull at pod start\n' "${img}" >&2
    return
  fi
  if ! _load_image_into_minikube "${img}"; then
    printf '\033[0;33m[local]\033[0m  WARNING: minikube load failed for %s — will pull at pod start\n' "${img}" >&2
  fi
}

info "Pre-loading third-party images (first run may take several minutes)..."
preload_image "busybox:1.36"
preload_image "postgres:15"
preload_image "quay.io/keycloak/keycloak:24.0.5"
preload_image "redis:7"
preload_image "confluentinc/cp-kafka:8.1.1"
preload_image "curlimages/curl:8.10.1"
preload_image "otel/opentelemetry-collector-contrib:0.111.0"
success "Third-party images ready."

# ── 2. Build, push, and load service images ──────────────────────────────────
# SKIP_BUILD=1 → skip build+push but still load existing images into minikube.
# This avoids ImagePullBackOff when pods can't pull from Docker Hub.
load_into_minikube() {
  local img=$1
  info "  Loading ${img} into minikube..."
  docker pull "${img}" || die "Cannot pull ${img}. Run without SKIP_BUILD=1 to rebuild images."
  _load_image_into_minikube "${img}" || die "Failed to load ${img} into minikube containerd."
}

if [ "${SKIP_BUILD}" != "1" ]; then
  if [ "${REGISTRY_LOGIN_HOST}" = "ghcr.io" ]; then
    info "Logging in to GitHub Container Registry (ghcr.io)..."
    _ghcr_token="$(printf '%s' "${GITHUB_TOKEN:-${GITHUB_PAT:-}}" | tr -d '\r')"
    if [ -z "${_ghcr_token}" ]; then
      die "Set GITHUB_TOKEN or GITHUB_PAT in .env to push to ghcr.io."
    fi
    echo "${_ghcr_token}" | docker login ghcr.io -u "${GITHUB_USERNAME}" --password-stdin
  else
    info "Logging in to Docker Hub..."
    if [ -n "${DOCKERHUB_TOKEN:-}" ]; then
      echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
    else
      docker login -u "${DOCKERHUB_USERNAME}"
    fi
  fi

  build_push_load() {
    local name=$1
    local context=$2
    local dockerfile=${3:-${context}/Dockerfile}
    local image="${IMAGE_REGISTRY}${name}:${IMAGE_TAG}"
    info "Building ${image}..."
    docker build -t "${image}" -f "${dockerfile}" "${context}"
    docker push "${image}"
    _load_image_into_minikube "${image}" || die "Failed to load ${image} into minikube containerd."
    success "${name} pushed and loaded into minikube."
  }

  build_push_load user-service        "${REPO_ROOT}/techbleat-global-bank-backend/user-service"
  build_push_load transaction-service "${REPO_ROOT}/techbleat-global-bank-backend/transaction-service"
  build_push_load activity-service    "${REPO_ROOT}/techbleat-global-bank-backend/activity-service"
  build_push_load finance-agent       "${REPO_ROOT}/finance-agent"

  FRONTEND_IMAGE="${IMAGE_REGISTRY}frontend:${IMAGE_TAG}"
  docker build \
    --build-arg VITE_KEYCLOAK_URL="${KEYCLOAK_PUBLIC_URL}" \
    --build-arg VITE_KEYCLOAK_REALM="banking" \
    --build-arg VITE_KEYCLOAK_CLIENT_ID="banking-frontend" \
    -t "${FRONTEND_IMAGE}" \
    -f "${REPO_ROOT}/techbleat-global-bank-frontend/dockerfile" \
    "${REPO_ROOT}/techbleat-global-bank-frontend"
  docker push "${FRONTEND_IMAGE}"
  _load_image_into_minikube "${FRONTEND_IMAGE}" || die "Failed to load ${FRONTEND_IMAGE} into minikube containerd."
  success "All images built, pushed, and loaded into minikube."
else
  info "SKIP_BUILD=1 — loading existing images from ${IMAGE_REGISTRY} into minikube..."
  # Image name = imageRegistry + repository (mirrors Helm: {{ .Values.global.imageRegistry }}{{ .Values.*.image.repository }})
  for svc in user-service transaction-service activity-service finance-agent frontend; do
    load_into_minikube "${IMAGE_REGISTRY}${svc}:${IMAGE_TAG}"
  done
  success "Banking app images loaded into minikube."
fi

# ── 3. Create namespace ───────────────────────────────────────────────────────
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Clear any stuck Helm release (pending-install / pending-upgrade) ──────────
# A previous run that was killed mid-install leaves a lock in a Helm secret.
# Deleting it lets the next install start clean.
HELM_STATUS=$(helm status "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)
if [ "${HELM_STATUS}" = "pending-install" ] || [ "${HELM_STATUS}" = "pending-upgrade" ] || [ "${HELM_STATUS}" = "pending-rollback" ]; then
  info "Clearing stuck Helm release (status: ${HELM_STATUS})..."
  kubectl delete secret -n "${NAMESPACE}" -l "owner=helm,name=${RELEASE}" --ignore-not-found 2>/dev/null || true
fi

# ── Adopt any kubectl-applied Istio resources into Helm ──────────────────────
# Older versions of this script applied Istio policies via `kubectl apply -f k8s/istio/`
# without Helm ownership labels. Helm upgrade refuses to manage resources it doesn't own.
# This block stamps them idempotently so the upgrade proceeds cleanly on re-deploys.
info "Adopting any existing Istio policies into Helm ownership..."
for ap in $(kubectl get authorizationpolicy -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  kubectl label authorizationpolicy "$ap" -n "${NAMESPACE}" \
    app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
  kubectl annotate authorizationpolicy "$ap" -n "${NAMESPACE}" \
    meta.helm.sh/release-name="${RELEASE}" \
    meta.helm.sh/release-namespace="${NAMESPACE}" --overwrite 2>/dev/null || true
done
if kubectl get peerauthentication default -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl label peerauthentication default -n "${NAMESPACE}" \
    app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
  kubectl annotate peerauthentication default -n "${NAMESPACE}" \
    meta.helm.sh/release-name="${RELEASE}" \
    meta.helm.sh/release-namespace="${NAMESPACE}" --overwrite 2>/dev/null || true
fi
success "Istio policies adopted into Helm ownership."

# ── Delete Kafka PVC so KRaft cluster metadata is always fresh ───────────────
# Kafka writes its CLUSTER_ID into the PVC on first start. If the PVC survives
# a helm uninstall, the next deploy finds stale metadata and crashes on startup.
# Deleting the PVC here means Kafka always formats storage clean on each deploy.
kubectl delete pvc "kafka-data-${RELEASE}-kafka-0" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

# ── 4. Helm deploy ───────────────────────────────────────────────────────────
info "Deploying with Helm (release: ${RELEASE}) — this takes 60-90s with no output, please wait..."
HELM_SET_KEYS=(
  "global.imageRegistry=${IMAGE_REGISTRY}"
  "global.imagePullPolicy=IfNotPresent"
  "userService.image.tag=${IMAGE_TAG}"
  "transactionService.image.tag=${IMAGE_TAG}"
  "activityService.image.tag=${IMAGE_TAG}"
  "financeAgent.image.tag=${IMAGE_TAG}"
  "frontend.image.tag=${IMAGE_TAG}"
  "secrets.postgresPassword=${POSTGRES_PASSWORD}"
  "secrets.keycloakAdminPassword=${KEYCLOAK_ADMIN_PASSWORD}"
  "secrets.keycloakAdminClientSecret=${KC_ADMIN_CLIENT_SECRET}"
)
# Pass AI API keys only if set in .env — strip \r so httpcore never rejects them
[ -n "${OPENAI_API_KEY}"     ] && HELM_SET_KEYS+=("secrets.openaiApiKey=${OPENAI_API_KEY}")
[ -n "${ANTHROPIC_API_KEY}"  ] && HELM_SET_KEYS+=("secrets.anthropicApiKey=${ANTHROPIC_API_KEY}")
[ -n "${DD_API_KEY:-}"       ] && HELM_SET_KEYS+=("secrets.datadogApiKey=$(printf '%s' "${DD_API_KEY}" | tr -d '\r')")

SET_ARGS=()
for kv in "${HELM_SET_KEYS[@]}"; do SET_ARGS+=(--set "${kv}"); done

helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${CHART_DIR}/values.yaml" \
  -f "${CHART_DIR}/values-local.yaml" \
  "${SET_ARGS[@]}"

success "Helm deployment complete. Pods are starting in the background."
info "Waiting for Postgres to be ready (up to 3 min)..."
kubectl rollout status deployment/postgres -n "${NAMESPACE}" --timeout=180s 2>/dev/null \
  || warn "Postgres not ready yet — check: kubectl get pods -n ${NAMESPACE}"
info "Waiting for Keycloak to be ready (up to 5 min)..."
kubectl rollout status deployment/"${RELEASE}"-keycloak -n "${NAMESPACE}" --timeout=300s 2>/dev/null \
  || warn "Keycloak not ready yet — check: kubectl get pods -n ${NAMESPACE}"
info "Tip: watch all pods with:  kubectl get pods -n ${NAMESPACE} -w"

# ── 4a. Grant Keycloak banking-provisioner service account required roles ─────
# user-service calls the Keycloak admin API to create users; for that to work
# the banking-provisioner service account must have manage-users + view-users
# from the realm-management client. Re-granting an already-assigned role is safe.
info "Granting manage-users + view-users to banking-provisioner service account..."
_KC="deploy/${RELEASE}-keycloak"
if kubectl get deployment "${RELEASE}-keycloak" -n "${NAMESPACE}" >/dev/null 2>&1; then
  KC_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
  kubectl exec -n "${NAMESPACE}" "${_KC}" -- \
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 --realm master \
      --user admin --password "${KC_PASS}" >/dev/null 2>&1 && \
  kubectl exec -n "${NAMESPACE}" "${_KC}" -- \
    /opt/keycloak/bin/kcadm.sh add-roles -r banking \
      --uusername service-account-banking-provisioner \
      --cclientid realm-management \
      --rolename manage-users >/dev/null 2>&1 && \
  kubectl exec -n "${NAMESPACE}" "${_KC}" -- \
    /opt/keycloak/bin/kcadm.sh add-roles -r banking \
      --uusername service-account-banking-provisioner \
      --cclientid realm-management \
      --rolename view-users >/dev/null 2>&1 \
  && success "banking-provisioner: manage-users + view-users granted." \
  || warn "Role grant failed — run manually: k8s/scripts/grant-keycloak-roles.sh"
else
  warn "Keycloak deployment not found — skipping role grant."
fi

# ── 4b. Install Datadog Operator + Agent (logs, APM, metrics) ────────────────
# Uses the Datadog Operator pattern (DatadogAgent CR) so the Agent DaemonSet
# is fully managed and can be upgraded without re-running this script.
# Requires DD_API_KEY in .env. Skipped gracefully when not set.
DD_API_KEY_CLEAN="$(printf '%s' "${DD_API_KEY:-}" | tr -d '\r')"
DD_SITE_CLEAN="$(printf '%s' "${DD_SITE:-datadoghq.com}" | tr -d '\r')"

if [ -n "${DD_API_KEY_CLEAN}" ]; then
  info "Setting up Datadog Operator + Agent (site: ${DD_SITE_CLEAN})..."

  # ── Remove old Helm-managed agent if it was installed the wrong way ──────
  if helm status datadog-agent -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "  Removing legacy datadog-agent Helm release from ${NAMESPACE}..."
    helm uninstall datadog-agent -n "${NAMESPACE}" 2>/dev/null || true
  fi

  # ── Remove old self-hosted stack (loki, grafana, prometheus, jaeger) ─────
  info "  Removing old observability stack (Loki, Grafana, Prometheus, Jaeger)..."
  helm uninstall loki -n "${NAMESPACE}" 2>/dev/null || true
  for dep in grafana prometheus jaeger; do
    kubectl delete deployment "${RELEASE}-${dep}" -n "${NAMESPACE}" \
      --ignore-not-found 2>/dev/null || true
  done

  # ── Install Datadog Operator into its own namespace ──────────────────────
  helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
  helm repo update datadog 2>/dev/null || true
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install datadog-operator datadog/datadog-operator \
    --namespace datadog \
    --set image.pullPolicy=IfNotPresent \
    --wait --timeout=120s
  success "  Datadog Operator installed."

  # ── Create API key secret ─────────────────────────────────────────────────
  kubectl create secret generic datadog-secret \
    --from-literal api-key="${DD_API_KEY_CLEAN}" \
    -n datadog \
    --dry-run=client -o yaml | kubectl apply -f -
  success "  datadog-secret created in namespace datadog."

  # ── Apply DatadogAgent CR ─────────────────────────────────────────────────
  kubectl apply -f - <<DDAGENT
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
  namespace: datadog
spec:
  global:
    clusterName: "${CLUSTER_NAME}"
    site: "${DD_SITE_CLEAN}"
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
    clusterChecks:
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

  success "DatadogAgent CR applied. Agent DaemonSet is starting — check: kubectl get pods -n datadog"
  info "  View logs, traces, and metrics at https://app.${DD_SITE_CLEAN}"
else
  warn "DD_API_KEY not set — Datadog Agent skipped."
  warn "Add DD_API_KEY=<your-key> (and optionally DD_SITE=datadoghq.eu) to .env and re-run."
fi

# ── 4c. Install Istio service mesh ────────────────────────────────────────────
# mTLS between all services, fine-grained AuthorizationPolicies, and WAF-ready ingress.
if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  info "Istio (istiod) already installed — skipping."
else
  info "Installing Istio via Helm (base → istiod → ingressgateway)..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
  helm repo update istio 2>/dev/null || true
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install istio-base istio/base \
    -n istio-system --wait --timeout=120s
  helm upgrade --install istiod istio/istiod \
    -n istio-system --wait --timeout=300s
  helm upgrade --install istio-ingressgateway istio/gateway \
    -n istio-system --wait --timeout=120s \
    --set service.type=NodePort
  success "Istio installed (istiod + ingressgateway)."
fi

kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite

# Istio policies (PeerAuthentication, AuthorizationPolicies) are now managed by the
# Helm chart (templates/istio/istio-policies.yaml, gated by istio.enabled=true in
# values-local.yaml). The adoption block above ensures Helm owns any existing resources.
# Do NOT re-apply standalone k8s/istio/ files here — that would strip Helm ownership.
info "Istio policies are managed by Helm (istio.enabled=true in values-local.yaml) — no separate apply needed."

# ── Patch CoreDNS to resolve external AI API hosts from inside pods ───────────
# minikube pods cannot reach 8.8.8.8 (UDP blocked); static hosts bypass forwarding.
info "Patching CoreDNS with static AI API hosts..."
ANTHROPIC_IP=$(python3 -c "import socket; print(socket.gethostbyname('api.anthropic.com'))" 2>/dev/null || echo "")
OPENAI_IP=$(python3 -c "import socket; print(socket.gethostbyname('api.openai.com'))" 2>/dev/null || echo "")
if [ -n "${ANTHROPIC_IP}" ] && [ -n "${OPENAI_IP}" ]; then
  COREDNS_CM=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
  if echo "${COREDNS_CM}" | grep -q "api.anthropic.com"; then
    info "CoreDNS hosts block already present — skipping patch."
  else
    HOSTS_BLOCK="        hosts {\n            ${ANTHROPIC_IP} api.anthropic.com\n            ${OPENAI_IP} api.openai.com\n            fallthrough\n        }"
    NEW_CM=$(echo "${COREDNS_CM}" | sed "s/        kubernetes cluster.local/${HOSTS_BLOCK}\n        kubernetes cluster.local/")
    kubectl create configmap coredns -n kube-system \
      --from-literal=Corefile="${NEW_CM}" \
      --dry-run=client -o yaml \
      | kubectl apply -f -
    kubectl rollout restart deployment/coredns -n kube-system
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s
    success "CoreDNS patched with AI API hosts (${ANTHROPIC_IP} / ${OPENAI_IP})."
  fi
else
  warn "Could not resolve AI API hosts from WSL2 — skipping CoreDNS patch."
fi

# ── Network access helpers ────────────────────────────────────────────────────
# Port-forward the NGINX ingress controller so the Windows browser can reach the
# app via http://techbleat-bank.local. minikube's Docker-driver node IP
# (192.168.49.x) is only reachable from WSL2 — not from Windows directly.
# Binding to 0.0.0.0 lets Windows reach it via localhost (WSL2 shares localhost).
setup_ingress_portforward() {
  # Kill any stale ingress port-forward and wait for the port to be released
  pkill -f "kubectl port-forward.*ingress-nginx-controller" 2>/dev/null || true
  sleep 3

  # WSL2 non-root cannot bind ports < 1024; use 8080/8443 directly.
  # Windows hosts file must point to 127.0.0.1 (WSL2 shares localhost with Windows).
  # Port 8443 handles any browser HSTS / ssl-redirect that still tries HTTPS.
  info "Starting ingress port-forwards (0.0.0.0:8080 → :80, 0.0.0.0:8443 → :443)..."
  nohup kubectl port-forward svc/ingress-nginx-controller \
    8080:80 8443:443 \
    -n ingress-nginx \
    --address=0.0.0.0 \
    >/tmp/pf-ingress.log 2>&1 &
  disown
  sleep 2
  if pgrep -f "kubectl port-forward.*ingress-nginx" >/dev/null 2>&1; then
    success "Ingress port-forwards active on ports 8080 (HTTP) and 8443 (HTTPS)"
    INGRESS_PORT=8080
  else
    warn "Ingress port-forward failed — check /tmp/pf-ingress.log"
  fi
}
INGRESS_PORT=8080

setup_observability_portforwards() {
  # Observability is now via Datadog — no local port-forwards needed.
  # OTel Collector health check: kubectl port-forward svc/otel-collector 13133:13133 -n "${NAMESPACE}"
  info "Observability via Datadog — no local port-forwards needed."
  if [ -n "${DD_API_KEY:-}" ]; then
    info "View logs, traces, and metrics at https://app.${DD_SITE_CLEAN:-datadoghq.eu}"
  else
    warn "DD_API_KEY not set — Datadog Agent not running. Telemetry will be discarded by the debug exporter."
  fi
}

# Check whether the Windows hosts file has 127.0.0.1 entries for the app.
# With the port-forward approach the entry must point to 127.0.0.1, not the
# minikube node IP — so we warn and print the correct lines if they're missing.
check_windows_hosts() {
  local hosts_file="/mnt/c/Windows/System32/drivers/etc/hosts"
  [ -f "${hosts_file}" ] || { warn "Windows hosts file not found at ${hosts_file}"; return; }

  local ok=true
  grep -q "techbleat-bank.local"         "${hosts_file}" 2>/dev/null || ok=false
  grep -q "keycloak.techbleat-bank.local" "${hosts_file}" 2>/dev/null || ok=false

  if ${ok}; then
    info "Windows hosts file: techbleat-bank.local entries present ✓"
    # Warn if entries point to minikube IP (old style) instead of 127.0.0.1
    if grep "techbleat-bank.local" "${hosts_file}" | grep -qv "127.0.0.1"; then
      warn "Hosts file entries do NOT use 127.0.0.1 — update to use port-forward approach."
      warn "Edit C:\\Windows\\System32\\drivers\\etc\\hosts (Notepad as Admin):"
      printf '    127.0.0.1  techbleat-bank.local\n'
      printf '    127.0.0.1  keycloak.techbleat-bank.local\n'
      printf '  Then access via http://techbleat-bank.local (after setting up netsh portproxy)\n\n'
    fi
  else
    printf '\n'
    warn "ACTION REQUIRED — Windows hosts file is missing techbleat-bank.local entries."
    printf '\033[0;33m[local]\033[0m  Open Notepad as Administrator and add to:\n'
    printf '\033[0;33m[local]\033[0m  C:\\Windows\\System32\\drivers\\etc\\hosts\n\n'
    printf '    127.0.0.1  techbleat-bank.local\n'
    printf '    127.0.0.1  keycloak.techbleat-bank.local\n\n'
  fi
}

# ── 5. Network access, observability, and print access instructions ──────────
setup_ingress_portforward
setup_observability_portforwards

# ── 5b. Install ArgoCD (GitOps controller) ───────────────────────────────────
if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  info "ArgoCD already installed."
else
  info "Installing ArgoCD via Helm..."
  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo 2>/dev/null || true
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --set server.insecure=true \
    --wait --timeout=300s
  success "ArgoCD installed in namespace argocd."
fi

GITHUB_REPO_URL_CLEAN="$(printf '%s' "${GITHUB_REPO_URL:-}" | tr -d '\r')"
if [ -n "${GITHUB_REPO_URL_CLEAN}" ] && [ -f "${REPO_ROOT}/k8s/argocd/local-app.yaml" ]; then
  _REVISION="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  sed -e "s|__REPO_URL__|${GITHUB_REPO_URL_CLEAN}|g" \
      -e "s|__REVISION__|${_REVISION}|g" \
      "${REPO_ROOT}/k8s/argocd/local-app.yaml" | kubectl apply -f -
  success "ArgoCD Application CR applied (repo: ${GITHUB_REPO_URL_CLEAN})."
else
  [ -z "${GITHUB_REPO_URL_CLEAN}" ] && \
    info "ArgoCD installed — add GITHUB_REPO_URL=https://github.com/<you>/sre2026-final-project.git to .env to wire the Application."
fi

# ── 5c. Cloudflare Tunnel (cloudflared) ──────────────────────────────────────
# Routes public traffic through Cloudflare (WAF + DDoS protection) — no public IP required.
# One-time setup: https://one.dash.cloudflare.com → Zero Trust → Access → Tunnels
#   1. Create Tunnel → copy the token → add CLOUDFLARE_TUNNEL_TOKEN=<token> to .env
#   2. Add Public Hostname: banking-app.<domain> → http://ingress-nginx-controller.ingress-nginx:80
#   3. Add Public Hostname: auth.<domain>        → http://ingress-nginx-controller.ingress-nginx:80
#   4. Set KEYCLOAK_PUBLIC_URL=https://auth.<domain> in .env so the frontend image is built with the right URL
CLOUDFLARE_TUNNEL_TOKEN_CLEAN="$(printf '%s' "${CLOUDFLARE_TUNNEL_TOKEN:-}" | tr -d '\r')"
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN_CLEAN}" ]; then
  info "Deploying Cloudflare Tunnel (cloudflared)..."
  kubectl create secret generic cloudflare-tunnel-token \
    --from-literal token="${CLOUDFLARE_TUNNEL_TOKEN_CLEAN}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  [ -f "${REPO_ROOT}/k8s/cloudflare/cloudflared-deployment.yaml" ] && \
    kubectl apply -f "${REPO_ROOT}/k8s/cloudflare/cloudflared-deployment.yaml"
  success "Cloudflare Tunnel deployed. Traffic: Cloudflare Edge → cloudflared → Istio ingressgateway → services"
else
  info "CLOUDFLARE_TUNNEL_TOKEN not set — add to .env to enable public access via Cloudflare WAF."
fi

# ArgoCD port-forward — only if ArgoCD is installed
if kubectl get svc argocd-server -n argocd >/dev/null 2>&1; then
  pkill -f "kubectl port-forward svc/argocd-server" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward svc/argocd-server 8088:80 \
    -n argocd --address=0.0.0.0 \
    >/tmp/pf-argocd.log 2>&1 &
  disown
  success "ArgoCD port-forward active on http://localhost:8088"
fi

check_windows_hosts

MINIKUBE_IP=$(minikube ip --profile "${CLUSTER_NAME}")

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  Deployment successful!  (minikube IP: %s)\n\n' "${MINIKUBE_IP}"
printf '  ── Windows hosts file (run Notepad as Administrator) ──\n'
printf '  C:\\Windows\\System32\\drivers\\etc\\hosts must contain:\n\n'
printf '    127.0.0.1  techbleat-bank.local\n'
printf '    127.0.0.1  keycloak.techbleat-bank.local\n\n'
printf '  ── Windows port proxy (resets on reboot — run as Admin) ──\n'
printf '  netsh interface portproxy add v4tov4 listenport=80 listenaddress=127.0.0.1 connectport=8080 connectaddress=127.0.0.1\n'
printf '  netsh interface portproxy add v4tov4 listenport=443 listenaddress=127.0.0.1 connectport=8443 connectaddress=127.0.0.1\n\n'
printf '  ── Application URLs ────────────────────────────────────\n'
printf '  Ingress port-forwards running: WSL=8080/8443, Windows=80/443.\n\n'
printf '    Frontend  : http://techbleat-bank.local\n'
printf '    Keycloak  : http://keycloak.techbleat-bank.local/admin\n'
printf '    Demo user : bankingdemo / Demo@2024\n\n'
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN_CLEAN}" ]; then
printf '  ── Cloudflare public access ────────────────────────────\n'
printf '    Frontend  : https://banking-app.%s\n'  "${KEYCLOAK_PUBLIC_URL#*://auth.}"
printf '    Keycloak  : %s/admin\n' "${KEYCLOAK_PUBLIC_URL}"
printf '  (Routes must be configured in Cloudflare Zero Trust dashboard)\n\n'
fi
printf '  ── Observability ───────────────────────────────────────\n'
printf '    Datadog    : https://app.%s\n' "${DD_SITE_CLEAN:-datadoghq.eu}"
printf '                 (requires DD_API_KEY in .env)\n'
printf '    ArgoCD     : http://localhost:8088  (admin / see below)\n\n'
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
printf '    ArgoCD password: %s\n\n' "${ARGOCD_PASS}"
printf '  ── Minikube dashboard ──────────────────────────────────\n'
printf '    minikube dashboard --profile %s\n\n' "${CLUSTER_NAME}"
printf '  ── Port-forward logs ───────────────────────────────────\n'
printf '    Ingress    : /tmp/pf-ingress.log\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
