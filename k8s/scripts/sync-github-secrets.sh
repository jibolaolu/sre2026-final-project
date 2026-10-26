#!/usr/bin/env bash
# sync-github-secrets.sh — Push all deployment secrets from .env to GitHub repo secrets.
#
# This lets the self-hosted runner (and GitHub-hosted runners for EKS) read secrets
# from GitHub's encrypted secret store instead of relying on a local .env.
#
# Requires: gh CLI (GitHub CLI) authenticated with repo + secrets scopes.
# Install:  https://cli.github.com/
#
# Usage:
#   bash k8s/scripts/sync-github-secrets.sh
#
# Run again whenever you rotate a secret in .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

info()    { printf '\033[0;36m[secrets]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[secrets]\033[0m  %s\n' "$*"; }
die()     { printf '\033[0;31m[secrets]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

# ── prerequisites ────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || die "gh CLI not found. Install: https://cli.github.com/"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run: gh auth login"

# ── load .env ────────────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || die ".env not found at ${ENV_FILE}"
while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank lines and full-line comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # Only export lines that are valid KEY=VALUE assignments (strip inline comments)
  if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)= ]]; then
    export "${BASH_REMATCH[1]}=${line#*=}" 2>/dev/null || true
  fi
done < "${ENV_FILE}"
info "Loaded .env"

# ── detect repo from GITHUB_REPO_URL ─────────────────────────────────────────
GITHUB_REPO_URL="${GITHUB_REPO_URL:-}"
[ -n "${GITHUB_REPO_URL}" ] || die "GITHUB_REPO_URL not set in .env"
REPO_PATH="$(printf '%s' "${GITHUB_REPO_URL}" | sed 's|https://github.com/||' | sed 's|\.git$||')"
info "Target repo: ${REPO_PATH}"

# ── helper: set a secret silently (value never printed) ──────────────────────
set_secret() {
  local name="$1"
  local value="$2"
  if [ -z "${value}" ]; then
    info "Skipping ${name} (empty value)"
    return
  fi
  printf '%s' "${value}" | gh secret set "${name}" --repo "${REPO_PATH}" --body -
  success "Set secret: ${name}"
}

# ── push secrets ─────────────────────────────────────────────────────────────
printf '\n'
info "Syncing secrets to ${REPO_PATH}..."
printf '\n'

# Docker Hub (for image builds and local-kind deploys)
set_secret "DOCKERHUB_USERNAME"               "${DOCKERHUB_USERNAME:-}"
set_secret "DOCKERHUB_TOKEN"                  "${DOCKERHUB_TOKEN:-}"

# Kubernetes app secrets
set_secret "POSTGRES_PASSWORD"                "${POSTGRES_PASSWORD:-}"
set_secret "KEYCLOAK_ADMIN_PASSWORD"          "${KEYCLOAK_ADMIN_PASSWORD:-}"
set_secret "KEYCLOAK_ADMIN_CLIENT_SECRET"     "${KC_ADMIN_CLIENT_SECRET:-}"
set_secret "TRANSACTION_SERVICE_KC_SECRET"    "${TRANSACTION_SERVICE_KC_SECRET:-}"
set_secret "ACTIVITY_SERVICE_KC_SECRET"       "${ACTIVITY_SERVICE_KC_SECRET:-}"
set_secret "FINANCE_AGENT_KC_SECRET"          "${FINANCE_AGENT_KC_SECRET:-}"

# AI API keys
set_secret "OPENAI_API_KEY"                   "${OPENAI_API_KEY:-}"
set_secret "ANTHROPIC_API_KEY"                "${ANTHROPIC_API_KEY:-}"

# Observability
set_secret "DATADOG_API_KEY"                  "${DD_API_KEY:-}"

# GitHub PAT (used by CI for private registry pulls / API calls).
# Must NOT be named GITHUB_* — that prefix is reserved by GitHub Actions.
set_secret "GH_PAT"                           "${GITHUB_TOKEN:-}"

printf '\n'
info "All configured secrets synced."
info "View at: https://github.com/${REPO_PATH}/settings/secrets/actions"
printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  Optional: AWS secrets for EKS deploys\n'
printf '  Set these manually if you have an EKS cluster:\n\n'
printf '  gh secret set AWS_ACCESS_KEY_ID     --repo %s\n' "${REPO_PATH}"
printf '  gh secret set AWS_SECRET_ACCESS_KEY --repo %s\n' "${REPO_PATH}"
printf '  gh variable set AWS_REGION          --repo %s --body us-east-1\n' "${REPO_PATH}"
printf '  gh variable set AWS_ACCOUNT_ID      --repo %s --body <your-account-id>\n' "${REPO_PATH}"
printf '  gh variable set EKS_CLUSTER_NAME    --repo %s --body techbleat-bank\n' "${REPO_PATH}"
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
