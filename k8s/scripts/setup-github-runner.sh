#!/usr/bin/env bash
# setup-github-runner.sh — Install a GitHub Actions self-hosted runner in WSL2.
#
# What this does:
#   1. Reads GITHUB_TOKEN and GITHUB_REPO_URL from the repo .env file.
#   2. Calls the GitHub API to exchange your PAT for a short-lived runner registration token.
#   3. Downloads the latest actions/runner binary for linux-x64.
#   4. Configures the runner with labels: self-hosted, linux, local-minikube.
#   5. Installs it as a systemd service so it auto-starts on WSL2 boot.
#
# Requirements (already present from your existing local setup):
#   kubectl, helm, docker, minikube — the runner inherits your PATH and ~/.kube/config.
#
# Run once from WSL2:
#   bash k8s/scripts/setup-github-runner.sh
#
# After setup, trigger a deploy from GitHub:
#   GitHub → your repo → Actions → "Deploy — Kubernetes" → Run workflow
#   Choose environment: local-minikube
#
# To check runner status:
#   sudo systemctl status actions.runner.*.service
#
# To uninstall:
#   cd ~/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
RUNNER_DIR="${HOME}/actions-runner"
RUNNER_LABEL="self-hosted,linux,local-minikube"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-minikube}"

# ── colours ─────────────────────────────────────────────────────────────────
info()    { printf '\033[0;36m[runner]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[runner]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[runner]\033[0m  WARNING: %s\n' "$*" >&2; }
die()     { printf '\033[0;31m[runner]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

# ── load .env ────────────────────────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and full-line comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Only export lines that are valid KEY=VALUE assignments (strip inline comments)
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)= ]]; then
      export "${BASH_REMATCH[1]}=${line#*=}" 2>/dev/null || true
    fi
  done < "${ENV_FILE}"
  info "Loaded .env from ${ENV_FILE}"
else
  die ".env file not found at ${ENV_FILE}. Add GITHUB_TOKEN and GITHUB_REPO_URL."
fi

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO_URL="${GITHUB_REPO_URL:-}"

[ -n "${GITHUB_TOKEN}"    ] || die "GITHUB_TOKEN not set in .env (needs repo + admin:org_hook scopes)."
[ -n "${GITHUB_REPO_URL}" ] || die "GITHUB_REPO_URL not set in .env (e.g. https://github.com/owner/repo.git)."

# ── extract owner/repo from URL ──────────────────────────────────────────────
# Handles: https://github.com/owner/repo.git  or  https://github.com/owner/repo
REPO_PATH="$(printf '%s' "${GITHUB_REPO_URL}" | sed 's|https://github.com/||' | sed 's|\.git$||')"
OWNER="$(printf '%s' "${REPO_PATH}" | cut -d'/' -f1)"
REPO="$(printf '%s' "${REPO_PATH}"  | cut -d'/' -f2)"

[ -n "${OWNER}" ] || die "Could not parse owner from GITHUB_REPO_URL: ${GITHUB_REPO_URL}"
[ -n "${REPO}"  ] || die "Could not parse repo from GITHUB_REPO_URL: ${GITHUB_REPO_URL}"
info "Target repo: ${OWNER}/${REPO}"

# ── check prerequisites ──────────────────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."
  command -v curl    >/dev/null 2>&1 || die "curl not found."
  command -v jq      >/dev/null 2>&1 || die "jq not found. Install: sudo apt-get install -y jq"
  command -v kubectl >/dev/null 2>&1 || warn "kubectl not in PATH — deploy steps will fail."
  command -v helm    >/dev/null 2>&1 || warn "helm not in PATH — deploy steps will fail."
  command -v docker  >/dev/null 2>&1 || warn "docker not in PATH — build steps will fail."
  minikube status --profile techbleat-bank >/dev/null 2>&1 \
    || warn "minikube cluster 'techbleat-bank' not running — start it before dispatching a deploy."
  success "Prerequisites checked."
}

# ── get runner registration token from GitHub API ────────────────────────────
get_registration_token() {
  info "Fetching runner registration token from GitHub API..."
  local response
  response=$(curl -fsSL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/registration-token")

  REGISTRATION_TOKEN=$(printf '%s' "${response}" | jq -r '.token // empty')
  [ -n "${REGISTRATION_TOKEN}" ] \
    || die "Failed to get registration token. API response: ${response}\nEnsure GITHUB_TOKEN has 'repo' scope."
  success "Registration token obtained (valid for 1 hour)."
}

# ── detect latest runner version ─────────────────────────────────────────────
get_latest_runner_version() {
  info "Fetching latest actions/runner release version..."
  RUNNER_VERSION=$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/actions/runner/releases/latest" \
    | jq -r '.tag_name' | sed 's/^v//')
  [ -n "${RUNNER_VERSION}" ] || die "Could not detect latest runner version."
  success "Latest runner version: v${RUNNER_VERSION}"
}

# ── download and extract runner ───────────────────────────────────────────────
download_runner() {
  if [ -d "${RUNNER_DIR}" ] && [ -f "${RUNNER_DIR}/config.sh" ]; then
    local existing_version
    existing_version=$(cat "${RUNNER_DIR}/package.json" 2>/dev/null | jq -r '.version // "unknown"' || echo "unknown")
    if [ "${existing_version}" = "${RUNNER_VERSION}" ]; then
      info "Runner v${RUNNER_VERSION} already downloaded at ${RUNNER_DIR}."
      return
    fi
    warn "Existing runner (v${existing_version}) at ${RUNNER_DIR} — upgrading to v${RUNNER_VERSION}."
  fi

  mkdir -p "${RUNNER_DIR}"
  local tarball="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  local url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"

  info "Downloading runner from ${url}..."
  curl -fsSL -o "/tmp/${tarball}" "${url}"
  tar xzf "/tmp/${tarball}" -C "${RUNNER_DIR}"
  rm -f "/tmp/${tarball}"
  success "Runner extracted to ${RUNNER_DIR}."
}

# ── configure runner ──────────────────────────────────────────────────────────
configure_runner() {
  info "Configuring runner '${RUNNER_NAME}' for ${OWNER}/${REPO}..."
  cd "${RUNNER_DIR}"

  # Remove any existing configuration so re-runs are idempotent
  if [ -f ".runner" ]; then
    info "Removing existing runner configuration..."
    ./config.sh remove --token "${REGISTRATION_TOKEN}" 2>/dev/null || true
    rm -f .runner .credentials .credentials_rsaparams
  fi

  ./config.sh \
    --url "https://github.com/${OWNER}/${REPO}" \
    --token "${REGISTRATION_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABEL}" \
    --work "_work" \
    --unattended \
    --replace

  success "Runner configured with labels: ${RUNNER_LABEL}"
}

# ── install as systemd service ────────────────────────────────────────────────
install_service() {
  info "Installing runner as systemd service..."
  cd "${RUNNER_DIR}"

  # Stop existing service if running
  local svc_name
  svc_name=$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
  if [ -n "${svc_name}" ]; then
    sudo systemctl stop "${svc_name}" 2>/dev/null || true
    sudo ./svc.sh uninstall 2>/dev/null || true
  fi

  sudo ./svc.sh install
  sudo systemctl daemon-reload
  sudo ./svc.sh start

  # Verify service is running
  sleep 2
  svc_name=$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
  if [ -n "${svc_name}" ] && sudo systemctl is-active --quiet "${svc_name}"; then
    success "Runner service '${svc_name}' is active and running."
  else
    warn "Service may not be running yet. Check: sudo systemctl status actions.runner.*.service"
  fi
}

# ── kubeconfig check ──────────────────────────────────────────────────────────
verify_kubeconfig() {
  info "Verifying kubeconfig access..."
  if kubectl config get-contexts techbleat-bank >/dev/null 2>&1; then
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "none")
    success "kubeconfig OK — current context: ${current_context}"
  else
    warn "minikube context 'techbleat-bank' not found in kubeconfig."
    warn "Start minikube and run: minikube update-context --profile techbleat-bank"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  printf '\n'
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf '  GitHub Actions Self-Hosted Runner Setup\n'
  printf '  Target: %s/%s\n' "${OWNER}" "${REPO}"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

  check_prereqs
  get_registration_token
  get_latest_runner_version
  download_runner
  configure_runner
  install_service
  verify_kubeconfig

  # Detect service name for status instructions
  local svc_name
  svc_name=$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "actions.runner.*.service")

  printf '\n'
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf '  Runner setup complete!\n\n'
  printf '  ── Status & control ────────────────────────────────────\n'
  printf '  Status :  sudo systemctl status %s\n' "${svc_name}"
  printf '  Logs   :  sudo journalctl -u %s -f\n' "${svc_name}"
  printf '  Stop   :  cd %s && sudo ./svc.sh stop\n' "${RUNNER_DIR}"
  printf '  Start  :  cd %s && sudo ./svc.sh start\n' "${RUNNER_DIR}"
  printf '\n'
  printf '  ── Trigger a deploy ────────────────────────────────────\n'
  printf '  1. Push a change to GitHub\n'
  printf '  2. Go to: https://github.com/%s/%s/actions\n' "${OWNER}" "${REPO}"
  printf '  3. Select: "Deploy — Kubernetes"\n'
  printf '  4. Click "Run workflow"\n'
  printf '  5. Choose environment: local-minikube\n'
  printf '  6. Click "Run workflow"\n'
  printf '\n'
  printf '  The runner on THIS machine picks up the job and deploys\n'
  printf '  to your local minikube cluster automatically.\n'
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
}

main "$@"
