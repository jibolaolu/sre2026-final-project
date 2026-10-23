#!/usr/bin/env bash
# One-shot startup for the Techbleat Global Bank stack.
# 1. Starts (or resumes) Keycloak and waits until it is healthy.
# 2. Provisions the banking realm, clients and roles via the Keycloak API.
# 3. Rebuilds and starts all banking services via docker compose.
#
# Usage:
#   bash start-banking-app.sh           # foreground compose (Ctrl-C to stop)
#   bash start-banking-app.sh --detach  # background compose (-d flag)
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────

KEYCLOAK_CONTAINER="keycloak"
KEYCLOAK_IMAGE="quay.io/keycloak/keycloak:24.0.5"
KEYCLOAK_PORT=8280
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD="admin"
KEYCLOAK_HEALTH_URL="http://localhost:${KEYCLOAK_PORT}/realms/master"
KEYCLOAK_API="http://localhost:${KEYCLOAK_PORT}"
KEYCLOAK_MAX_WAIT=300
BANKING_NETWORK="banking-net"
# Public-facing URL that the browser uses to reach Keycloak (via the local HTTPS proxy).
# Keycloak's frontendUrl is set to this so all OIDC redirects use it, not localhost.
KEYCLOAK_PUBLIC_URL="https://techbleat-bank-keycloak.localtest.me"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/techbleat-global-bank-backend"

# ── helpers ───────────────────────────────────────────────────────────────────

info()    { printf '\033[0;36m[banking]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[banking]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[banking]\033[0m  %s\n' "$*"; }
die()     { printf '\033[0;31m[banking]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }
step()    { printf '\n\033[1;37m══ %s ══\033[0m\n\n' "$*"; }

container_status() {
  docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || true
}

port_in_use() {
  nc -z 127.0.0.1 "$1" 2>/dev/null
}

wait_for_keycloak() {
  local elapsed=0
  info "Waiting for Keycloak to become ready (up to ${KEYCLOAK_MAX_WAIT}s)…"
  while [[ $elapsed -lt $KEYCLOAK_MAX_WAIT ]]; do
    if curl -sf "${KEYCLOAK_HEALTH_URL}" >/dev/null 2>&1; then
      printf '\n'
      return 0
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
    printf '.'
  done
  printf '\n'
  return 1
}

wait_for_postgres() {
  local elapsed=0 max_wait=60
  info "Waiting for PostgreSQL to become ready (up to ${max_wait}s)…"
  while [[ $elapsed -lt $max_wait ]]; do
    if docker exec banking-postgres pg_isready -U bankuser -q 2>/dev/null; then
      printf '\n'
      return 0
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
    printf '.'
  done
  printf '\n'
  return 1
}

kc_admin_token() {
  curl -sf -X POST "${KEYCLOAK_API}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}&grant_type=password" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

kc_get() {
  curl -s "${KEYCLOAK_API}/$1" -H "Authorization: Bearer $KC_TOKEN"
}

kc_post() {
  curl -s -X POST "${KEYCLOAK_API}/$1" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" -o /dev/null
}

kc_put() {
  curl -s -X PUT "${KEYCLOAK_API}/$1" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" -o /dev/null
}

kc_post_status() {
  curl -s -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_API}/$1" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2"
}

# ── keycloak provisioning ─────────────────────────────────────────────────────

provision_keycloak() {
  info "Provisioning Keycloak banking realm…"

  # /health/ready may pass before the master realm finishes initialising.
  # Retry the token request for up to 120 s to bridge that gap.
  local _tok="" _ta=0 _tm=24
  info "Waiting for Keycloak master realm token endpoint…"
  while [[ $_ta -lt $_tm ]]; do
    _tok=$(kc_admin_token 2>/dev/null || true)
    [[ -n "$_tok" ]] && break
    _ta=$(( _ta + 1 ))
    [[ $_ta -ge $_tm ]] && die "Admin token not available after $(( _tm * 5 ))s.
       Check: docker logs ${KEYCLOAK_CONTAINER}"
    printf '.'; sleep 5
  done
  printf '\n'
  KC_TOKEN="$_tok"

  # ── realm ──────────────────────────────────────────────────────────────────

  local realm_http
  realm_http=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $KC_TOKEN" "${KEYCLOAK_API}/admin/realms/banking")

  if [[ "$realm_http" == "404" ]]; then
    kc_post "admin/realms" \
      '{"realm":"banking","enabled":true,"displayName":"Techbleat Global Bank"}'
    info "Created banking realm."
  fi

  # ── realm login features (idempotent PUT — safe to re-apply) ─────────────────
  curl -s -X PUT "${KEYCLOAK_API}/admin/realms/banking" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "resetPasswordAllowed": true,
      "rememberMe": true,
      "smtpServer": {
        "host": "mailpit",
        "port": "1025",
        "from": "noreply@techbleat.local",
        "fromDisplayName": "Techbleat Global Bank",
        "ssl": "false",
        "starttls": "false",
        "auth": "false"
      }
    }' -o /dev/null || true
  info "Realm login features set (forgot-password enabled, SMTP → mailpit:1025)."

  # ── set frontendUrl so all OIDC redirects use the localtest.me domain ────────
  # Without this Keycloak falls back to the Host header of each request, which
  # means the browser sees localhost:8280 in the auth redirect.
  # Refresh token before the PUT — realm-creation may have consumed lifetime.
  KC_TOKEN=$(kc_admin_token 2>/dev/null || echo "$KC_TOKEN")

  info "Setting Keycloak Frontend URL to ${KEYCLOAK_PUBLIC_URL}…"

  # Method 1: targeted PUT on the plain field.
  curl -s -X PUT "${KEYCLOAK_API}/admin/realms/banking" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"frontendUrl\":\"${KEYCLOAK_PUBLIC_URL}\"}" -o /dev/null || true

  # Method 2: full-JSON PUT — Keycloak 24 may also store it in attributes.
  local realm_json updated_json
  realm_json=$(curl -s "${KEYCLOAK_API}/admin/realms/banking" \
    -H "Authorization: Bearer $KC_TOKEN" || true)
  if command -v python3 >/dev/null 2>&1 && [[ -n "$realm_json" ]]; then
    updated_json=$(printf '%s' "$realm_json" | python3 -c "
import json, sys, os
url = os.environ.get('KEYCLOAK_PUBLIC_URL','')
r = json.load(sys.stdin)
r['frontendUrl'] = url
if isinstance(r.get('attributes'), dict):
    r['attributes']['frontendUrl'] = url
print(json.dumps(r))
" 2>/dev/null || true)
    [[ -n "$updated_json" ]] && \
      curl -s -X PUT "${KEYCLOAK_API}/admin/realms/banking" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$updated_json" -o /dev/null || true
  fi

  # Authoritative check — verify the discovery doc now returns the right host.
  local auth_ep
  auth_ep=$(curl -s "${KEYCLOAK_API}/realms/banking/.well-known/openid-configuration" \
    | grep -o '"authorization_endpoint":"[^"]*"' | cut -d'"' -f4 || true)
  if [[ "$auth_ep" != "${KEYCLOAK_PUBLIC_URL}"* ]]; then
    warn "Frontend URL may not have applied yet. Auth endpoint: ${auth_ep}"
    warn "Expected it to start with: ${KEYCLOAK_PUBLIC_URL}"
    warn "If the browser still redirects to localhost, re-run this script."
  else
    success "Frontend URL set. Auth endpoint: ${auth_ep}"
  fi

  # ── roles ──────────────────────────────────────────────────────────────────

  for role in "banking-customer" "banking-transact" "banking-ai-agent"; do
    local role_http
    role_http=$(kc_post_status "admin/realms/banking/roles" "{\"name\":\"${role}\"}")
    if [[ "$role_http" == "201" ]]; then
      info "Created role: ${role}"
    fi
  done

  # ── banking-frontend client (public PKCE) ──────────────────────────────────

  local fe_id
  fe_id=$(kc_get "admin/realms/banking/clients?clientId=banking-frontend" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  local fe_payload='{
    "clientId":                  "banking-frontend",
    "name":                      "Banking Frontend",
    "enabled":                   true,
    "publicClient":              true,
    "standardFlowEnabled":       true,
    "directAccessGrantsEnabled": false,
    "redirectUris":  ["https://techbleat-bank.localtest.me/*","http://localhost:3180/*"],
    "webOrigins":    ["https://techbleat-bank.localtest.me","http://localhost:3180"],
    "attributes":    {"pkce.code.challenge.method":"S256"}
  }'

  if [[ -z "$fe_id" ]]; then
    kc_post "admin/realms/banking/clients" "$fe_payload"
    info "Created banking-frontend client."
  else
    kc_put  "admin/realms/banking/clients/${fe_id}" "$fe_payload"
    info "Updated banking-frontend client."
  fi

  # ── banking-provisioner client (confidential service account) ──────────────

  local prov_id
  prov_id=$(kc_get "admin/realms/banking/clients?clientId=banking-provisioner" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [[ -z "$prov_id" ]]; then
    kc_post "admin/realms/banking/clients" '{
      "clientId":               "banking-provisioner",
      "name":                   "Banking Provisioner",
      "enabled":                true,
      "publicClient":           false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled":    false,
      "directAccessGrantsEnabled": false
    }'
    info "Created banking-provisioner client."
    prov_id=$(kc_get "admin/realms/banking/clients?clientId=banking-provisioner" \
      | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fi

  # Grant manage-users to the provisioner service account
  if [[ -n "$prov_id" ]]; then
    local realm_mgmt_id sa_user_id manage_users_role
    realm_mgmt_id=$(kc_get "admin/realms/banking/clients?clientId=realm-management" \
      | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    if [[ -n "$realm_mgmt_id" ]]; then
      sa_user_id=$(kc_get "admin/realms/banking/clients/${prov_id}/service-account-user" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      manage_users_role=$(kc_get "admin/realms/banking/clients/${realm_mgmt_id}/roles/manage-users" || true)

      if [[ -n "$sa_user_id" && -n "$manage_users_role" && "$manage_users_role" != *"error"* ]]; then
        curl -sf -X POST \
          "${KEYCLOAK_API}/admin/realms/banking/users/${sa_user_id}/role-mappings/clients/${realm_mgmt_id}" \
          -H "Authorization: Bearer $KC_TOKEN" \
          -H "Content-Type: application/json" \
          -d "[${manage_users_role}]" -o /dev/null \
          && info "Granted manage-users to banking-provisioner service account." || true
      fi
    fi

    # Extract provisioner secret and write to .env
    local secret
    secret=$(kc_get "admin/realms/banking/clients/${prov_id}/client-secret" \
      | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -n "$secret" && "$secret" != "null" ]]; then
      local env_file="${COMPOSE_DIR}/.env"
      if grep -q "^KEYCLOAK_ADMIN_CLIENT_SECRET=" "$env_file"; then
        sed -i "s|^KEYCLOAK_ADMIN_CLIENT_SECRET=.*|KEYCLOAK_ADMIN_CLIENT_SECRET=${secret}|" "$env_file"
      else
        printf '\nKEYCLOAK_ADMIN_CLIENT_SECRET=%s\n' "$secret" >> "$env_file"
      fi
      success "KEYCLOAK_ADMIN_CLIENT_SECRET written to .env"
    fi
  fi

  # ── per-service machine clients ────────────────────────────────────────────

  for svc_client in "transaction-service-client" "activity-service-client" "user-service-client" "finance-agent-client"; do
    svc_id=$(kc_get "admin/realms/banking/clients?clientId=${svc_client}" \
      | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [[ -z "$svc_id" ]]; then
      kc_post "admin/realms/banking/clients" \
        "{\"clientId\":\"${svc_client}\",\"enabled\":true,\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false}"
      info "Created ${svc_client} client."
      svc_id=$(kc_get "admin/realms/banking/clients?clientId=${svc_client}" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    fi
    if [[ -n "$svc_id" ]]; then
      svc_secret=$(kc_get "admin/realms/banking/clients/${svc_id}/client-secret" \
        | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true)
      if [[ -n "$svc_secret" && "$svc_secret" != "null" ]]; then
        # derive env var name: transaction-service-client → TRANSACTION_SERVICE_KC_SECRET
        env_var=$(echo "$svc_client" | sed 's/-client$//' | tr '-' '_' | tr '[:lower:]' '[:upper:]')_KC_SECRET
        if grep -q "^${env_var}=" "${COMPOSE_DIR}/.env"; then
          sed -i "s|^${env_var}=.*|${env_var}=${svc_secret}|" "${COMPOSE_DIR}/.env"
        else
          printf '\n%s=%s\n' "$env_var" "$svc_secret" >> "${COMPOSE_DIR}/.env"
        fi
        info "${env_var} written to .env"
      fi
    fi
  done

  # ── demo user ─────────────────────────────────────────────────────────────────
  # Create a single demo account so the app is immediately usable after startup.
  # Idempotent — skipped if the user already exists.
  local demo_user="demo"
  local demo_pass="demo123"
  local demo_email="demo@techbleat.local"
  local existing_user
  existing_user=$(kc_get "admin/realms/banking/users?username=${demo_user}" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [[ -z "$existing_user" ]]; then
    local create_status
    create_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "${KEYCLOAK_API}/admin/realms/banking/users" \
      -H "Authorization: Bearer $KC_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${demo_user}\",
        \"email\": \"${demo_email}\",
        \"firstName\": \"Demo\",
        \"lastName\": \"User\",
        \"enabled\": true,
        \"emailVerified\": true,
        \"credentials\": [{
          \"type\": \"password\",
          \"value\": \"${demo_pass}\",
          \"temporary\": false
        }]
      }")
    if [[ "$create_status" == "201" ]]; then
      info "Demo user created: ${demo_user} / ${demo_pass}"
      # Assign all banking roles to the demo user
      existing_user=$(kc_get "admin/realms/banking/users?username=${demo_user}" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    else
      warn "Demo user creation returned HTTP ${create_status} — may already exist or realm not ready."
    fi
  else
    info "Demo user '${demo_user}' already exists — skipping creation."
  fi

  # Assign all banking roles to the demo user
  if [[ -n "$existing_user" ]]; then
    local roles_json=""
    for role in "banking-customer" "banking-transact" "banking-ai-agent"; do
      local role_id
      role_id=$(kc_get "admin/realms/banking/roles/${role}" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      [[ -n "$role_id" ]] && roles_json+="${roles_json:+,}{\"id\":\"${role_id}\",\"name\":\"${role}\"}"
    done
    if [[ -n "$roles_json" ]]; then
      curl -s -X POST \
        "${KEYCLOAK_API}/admin/realms/banking/users/${existing_user}/role-mappings/realm" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "[${roles_json}]" -o /dev/null || true
      info "Assigned all banking roles to demo user."
    fi
  fi

  # ── Priority 1: Authorization Services on transaction-service-client ──────────
  # Enables Keycloak as a policy decision point for banking resources.

  local tx_id fa_id
  tx_id=$(kc_get "admin/realms/banking/clients?clientId=transaction-service-client" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fa_id=$(kc_get "admin/realms/banking/clients?clientId=finance-agent-client" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [[ -n "$tx_id" ]] && command -v python3 >/dev/null 2>&1; then
    KC_TOKEN=$(kc_admin_token 2>/dev/null || echo "$KC_TOKEN")
    local tx_json tx_updated
    tx_json=$(kc_get "admin/realms/banking/clients/${tx_id}" || true)
    if [[ -n "$tx_json" ]]; then
      tx_updated=$(printf '%s' "$tx_json" | python3 -c "
import json, sys
c = json.load(sys.stdin)
c['authorizationServicesEnabled'] = True
c['serviceAccountsEnabled'] = True
print(json.dumps(c))
" 2>/dev/null || true)
      [[ -n "$tx_updated" ]] && \
        curl -sf -X PUT "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}" \
          -H "Authorization: Bearer $KC_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$tx_updated" -o /dev/null || true
      info "Enabled Authorization Services on transaction-service-client."
    fi

    KC_TOKEN=$(kc_admin_token 2>/dev/null || echo "$KC_TOKEN")

    # Define authorization scopes
    for scope_name in "read" "write"; do
      curl -sf -X POST \
        "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/authz/resource-server/scope" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${scope_name}\"}" -o /dev/null 2>/dev/null || true
    done
    info "Defined authorization scopes: read, write."

    # Define resources: account, transaction, ai-chat
    for res_type in "account" "transaction" "ai-chat"; do
      curl -sf -X POST \
        "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/authz/resource-server/resource" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"name\":\"${res_type}\",
          \"type\":\"${res_type}\",
          \"ownerManagedAccess\":false,
          \"scopes\":[{\"name\":\"read\"},{\"name\":\"write\"}]
        }" -o /dev/null 2>/dev/null || true
    done
    info "Defined authorization resources: account, transaction, ai-chat."

    # Create a role-based policy for banking-customer role
    local bc_role_id
    bc_role_id=$(kc_get "admin/realms/banking/roles/banking-customer" \
      | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    if [[ -n "$bc_role_id" ]]; then
      curl -sf -X POST \
        "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/authz/resource-server/policy/role" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"type\":\"role\",
          \"logic\":\"POSITIVE\",
          \"decisionStrategy\":\"UNANIMOUS\",
          \"name\":\"banking-customer-policy\",
          \"roles\":[{\"id\":\"${bc_role_id}\",\"required\":false}]
        }" -o /dev/null 2>/dev/null || true
      info "Created banking-customer-policy."

      # Create resource permission covering all resources for banking-customer
      curl -sf -X POST \
        "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/authz/resource-server/permission/resource" \
        -H "Authorization: Bearer $KC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"type\":\"resource\",
          \"logic\":\"POSITIVE\",
          \"decisionStrategy\":\"UNANIMOUS\",
          \"name\":\"banking-resource-access-permission\",
          \"applyPolicies\":[\"banking-customer-policy\"]
        }" -o /dev/null 2>/dev/null || true
      info "Created banking-resource-access-permission."
    fi
  fi

  # ── Priority 2: Token Exchange — finance-agent-client → transaction-service-client ──
  # Allows the finance agent to obtain a narrowed token (RFC 8693) when calling
  # the transaction service on behalf of the authenticated user.

  if [[ -n "$fa_id" && -n "$tx_id" ]]; then
    KC_TOKEN=$(kc_admin_token 2>/dev/null || echo "$KC_TOKEN")

    # Enable management permissions on the target client
    curl -sf -X PUT \
      "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/management/permissions" \
      -H "Authorization: Bearer $KC_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"enabled":true}' -o /dev/null || true

    # Get the token-exchange permission UUID from management permissions
    local mgmt_perms te_perm_id
    mgmt_perms=$(curl -sf \
      "${KEYCLOAK_API}/admin/realms/banking/clients/${tx_id}/management/permissions" \
      -H "Authorization: Bearer $KC_TOKEN" || true)
    te_perm_id=$(printf '%s' "$mgmt_perms" \
      | grep -o '"token-exchange":"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -n "$te_perm_id" ]]; then
      local rm_id
      rm_id=$(kc_get "admin/realms/banking/clients?clientId=realm-management" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

      if [[ -n "$rm_id" ]]; then
        # Create a client policy allowing only finance-agent-client to exchange tokens
        local cp_id
        cp_id=$(curl -sf -X POST \
          "${KEYCLOAK_API}/admin/realms/banking/clients/${rm_id}/authz/resource-server/policy/client" \
          -H "Authorization: Bearer $KC_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{
            \"type\":\"client\",
            \"logic\":\"POSITIVE\",
            \"decisionStrategy\":\"UNANIMOUS\",
            \"name\":\"finance-agent-exchange-policy\",
            \"clients\":[\"${fa_id}\"]
          }" 2>/dev/null \
          | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

        # If creation returned 409 (already exists), look it up
        if [[ -z "$cp_id" ]]; then
          cp_id=$(curl -sf \
            "${KEYCLOAK_API}/admin/realms/banking/clients/${rm_id}/authz/resource-server/policy?name=finance-agent-exchange-policy" \
            -H "Authorization: Bearer $KC_TOKEN" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        fi

        if [[ -n "$cp_id" ]]; then
          # Attach the client policy to the token-exchange permission
          curl -sf -X PUT \
            "${KEYCLOAK_API}/admin/realms/banking/clients/${rm_id}/authz/resource-server/permission/scope/${te_perm_id}" \
            -H "Authorization: Bearer $KC_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
              \"id\":\"${te_perm_id}\",
              \"type\":\"scope\",
              \"logic\":\"POSITIVE\",
              \"decisionStrategy\":\"UNANIMOUS\",
              \"name\":\"token-exchange.permission.client.${tx_id}\",
              \"policies\":[\"${cp_id}\"]
            }" -o /dev/null || true
          info "Token exchange configured: finance-agent-client → transaction-service-client."
        fi
      fi
    fi

    # Also write FINANCE_AGENT_KC_SECRET to finance-agent/.env so the container
    # can read it via env_file (it cannot read the backend .env directly).
    local fa_secret _fa_env
    fa_secret=$(kc_get "admin/realms/banking/clients/${fa_id}/client-secret" \
      | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true)
    _fa_env="${SCRIPT_DIR}/finance-agent/.env"
    if [[ -n "$fa_secret" && "$fa_secret" != "null" && -f "$_fa_env" ]]; then
      if grep -q "^FINANCE_AGENT_KC_SECRET=" "$_fa_env"; then
        sed -i "s|^FINANCE_AGENT_KC_SECRET=.*|FINANCE_AGENT_KC_SECRET=${fa_secret}|" "$_fa_env"
      else
        printf '\nFINANCE_AGENT_KC_SECRET=%s\n' "$fa_secret" >> "$_fa_env"
      fi
      info "FINANCE_AGENT_KC_SECRET written to finance-agent/.env"
    fi
  fi

  success "Keycloak banking realm is provisioned."
  printf '  Realm   : banking\n'
  printf '  Clients : banking-frontend (PKCE), banking-provisioner (service account)\n'
  printf '            transaction-service-client (authz + token-exchange target),\n'
  printf '            activity-service-client, user-service-client,\n'
  printf '            finance-agent-client (token exchange enabled)\n'
  printf '  Roles   : banking-customer, banking-transact, banking-ai-agent\n'
  printf '  Demo    : username=\033[0;33m%s\033[0m  password=\033[0;33m%s\033[0m\n' "$demo_user" "$demo_pass"
}

# ── service URL table ─────────────────────────────────────────────────────────

print_urls() {
  local G='\033[0;32m' C='\033[0;36m' Y='\033[0;33m' M='\033[0;35m' W='\033[1;37m' D='\033[2m' R='\033[0m'
  local L="${W}  │${R}"        # left border
  local HR="  ├─────────────────────────────────────────────────────────────────────┤"
  local HL="  ╞═════════════════════════════════════════════════════════════════════╡"
  printf '\n'
  printf "${W}  ╭─────────────────────────────────────────────────────────────────────╮${R}\n"
  printf "${W}  │           Techbleat Global Bank — Stack URLs                       │${R}\n"

  # ── Banking App ──────────────────────────────────────────────────────────────
  printf "${W}${HL}${R}\n"
  printf "%s  ${D}Banking App${R}\n" "$L"
  printf "${HR}\n"
  printf "%s  %-22s  ${G}%s${R}\n"  "$L" "Frontend"            "https://techbleat-bank.localtest.me"
  printf "%s  %-22s  ${C}%s${R}\n"  "$L" "User service"        "https://techbleat-bank-user-api.localtest.me"
  printf "%s  %-22s  ${C}%s${R}\n"  "$L" "Transaction service" "https://techbleat-bank-transaction-api.localtest.me"
  printf "%s  %-22s  ${C}%s${R}\n"  "$L" "Activity service"    "https://techbleat-bank-activity-api.localtest.me"
  printf "%s  %-22s  ${C}%s${R}\n"  "$L" "Finance agent /docs" "https://techbleat-bank-agent.localtest.me/docs"

  # ── Auth / Security ──────────────────────────────────────────────────────────
  printf "${W}${HL}${R}\n"
  printf "%s  ${D}Auth / Security${R}\n" "$L"
  printf "${HR}\n"
  printf "%s  %-22s  ${Y}%s${R}\n"  "$L" "Keycloak admin"      "https://techbleat-bank-keycloak.localtest.me/admin"
  printf "%s  %-22s  ${Y}%s${R}\n"  "$L" "Keycloak OIDC"       "https://techbleat-bank-keycloak.localtest.me/realms/banking"
  printf "%s  %-22s  ${Y}%s${R}\n"  "$L" "Keycloak account"    "https://techbleat-bank-keycloak.localtest.me/realms/banking/account"

  # ── SRE Signals ──────────────────────────────────────────────────────────────
  printf "${W}${HL}${R}\n"
  printf "%s  ${D}SRE — Logs, Metrics, Traces${R}\n" "$L"
  printf "${HR}\n"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Grafana"             "https://techbleat-bank-grafana.localtest.me"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Jaeger (traces)"     "https://techbleat-bank-jaeger.localtest.me"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Prometheus"          "https://techbleat-bank-prometheus.localtest.me"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Prometheus targets"  "https://techbleat-bank-prometheus.localtest.me/targets"
  printf "%s  %-22s  ${D}%s${R}\n"  "$L" "Txn metrics (direct)" "http://localhost:8090/actuator/prometheus"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Alertmanager"        "http://localhost:9093"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Loki"                "http://localhost:3100"
  printf "%s  %-22s  ${M}%s${R}\n"  "$L" "Mailpit (email UI)"  "https://techbleat-bank-mailpit.localtest.me"

  # ── Infra (direct only) ───────────────────────────────────────────────────────
  printf "${W}${HL}${R}\n"
  printf "%s  ${D}Infra — direct localhost only${R}\n" "$L"
  printf "${HR}\n"
  printf "%s  %-22s  ${D}%s${R}\n"  "$L" "PostgreSQL"          "localhost:5433"
  printf "%s  %-22s  ${D}%s${R}\n"  "$L" "Redis"               "localhost:6380"
  printf "%s  %-22s  ${D}%s${R}\n"  "$L" "Kafka"               "localhost:9092"

  printf "${W}  ╰─────────────────────────────────────────────────────────────────────╯${R}\n"
  printf '\n'
  printf "  ${Y}Requires local HTTPS proxy:${R}\n"
  printf "    bash /mnt/c/Users/EAGLESOLUTIONS/Documents/localproxy/setup_local_https_proxy.sh\n"
  printf '\n'
  printf "  Keycloak admin  — username: ${Y}%s${R}   password: ${Y}%s${R}\n" \
    "$KEYCLOAK_ADMIN_USER" "$KEYCLOAK_ADMIN_PASSWORD"
  printf "  Grafana         — username: ${M}admin${R}   password: ${M}admin${R}\n"
  printf "  Banking app login — username: ${G}demo${R}   password: ${G}demo123${R}\n"
  printf '\n'
}

# ── parse args ────────────────────────────────────────────────────────────────

COMPOSE_FLAGS=()
DO_STOP=0
for arg in "$@"; do
  case "$arg" in
    --detach|-d) COMPOSE_FLAGS+=("--detach") ;;
    --stop|-s)   DO_STOP=1 ;;
    --help|-h)
      printf 'Usage: %s [--detach | --stop]\n' "$(basename "$0")"
      printf '  --detach  Start the stack in the background\n'
      printf '  --stop    Stop all running stack containers (compose down)\n'
      exit 0
      ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

if [[ $DO_STOP -eq 1 ]]; then
  step "Stopping Techbleat Global Bank stack"
  cd "$COMPOSE_DIR"
  docker compose down
  success "Stack stopped. Keycloak container left running (stop manually with: docker stop ${KEYCLOAK_CONTAINER:-keycloak})"
  exit 0
fi

# ── step 1: shared docker network + keycloak container ───────────────────────

step "Step 1 — Keycloak (identity provider)"

# Create the shared bridge network that Keycloak and compose services both join.
# Compose containers reach Keycloak as http://keycloak:8080 (container name DNS).
if ! docker network inspect "$BANKING_NETWORK" >/dev/null 2>&1; then
  docker network create "$BANKING_NETWORK"
  info "Created Docker network: ${BANKING_NETWORK}"
else
  info "Docker network '${BANKING_NETWORK}' already exists."
fi

KC_STATUS=$(container_status "$KEYCLOAK_CONTAINER")

case "$KC_STATUS" in
  running)
    success "Keycloak container is already running."
    # Ensure it is attached to the shared network (may not be on a partial restart).
    docker network connect "$BANKING_NETWORK" "$KEYCLOAK_CONTAINER" 2>/dev/null || true
    ;;
  exited|created|paused)
    # Restart the stopped container — the named volume keeps all user/realm data.
    # frontendUrl is re-applied via the API in provision_keycloak below.
    info "Keycloak container is stopped. Restarting it (data volume preserved)…"
    docker start "$KEYCLOAK_CONTAINER"
    docker network connect "$BANKING_NETWORK" "$KEYCLOAK_CONTAINER" 2>/dev/null || true
    ;;
  "")
    if port_in_use "$KEYCLOAK_PORT"; then
      if curl -sf "${KEYCLOAK_HEALTH_URL}" >/dev/null 2>&1; then
        warn "Port ${KEYCLOAK_PORT} is in use and Keycloak is already answering there."
        warn "Skipping docker run and using the existing instance."
        docker network connect "$BANKING_NETWORK" "$KEYCLOAK_CONTAINER" 2>/dev/null || true
      else
        die "Port ${KEYCLOAK_PORT} is already in use by a non-Keycloak process.
       Find and stop it first:  sudo lsof -i :${KEYCLOAK_PORT}  (Linux/Mac)
                                netstat -ano | findstr :${KEYCLOAK_PORT}  (Windows)"
      fi
    else
      info "No Keycloak container found. Starting PostgreSQL first (Priority 6), then Keycloak…"

      # Priority 6: bring up postgres so Keycloak can use it as its database backend.
      _KC_DB_ARGS=()
      _KC_FEATURE_ARGS=()
      if [[ -f "${COMPOSE_DIR}/.env" ]]; then
        (cd "${COMPOSE_DIR}" && docker compose up -d postgres) || true
        if wait_for_postgres; then
          _PG_PASS=$(grep -m1 '^POSTGRES_PASSWORD=' "${COMPOSE_DIR}/.env" | cut -d= -f2- || true)
          if [[ -n "$_PG_PASS" ]]; then
            # Create keycloakdb if it does not already exist; verify with retries.
            _kc_db_ready=false
            for _attempt in 1 2 3 4 5; do
              # Try create — suppresses "already exists" which is fine; other errors stay visible.
              # -d postgres: connect to the maintenance DB (psql defaults to dbname=username which doesn't exist).
              docker exec banking-postgres psql -U bankuser -d postgres \
                -c "CREATE DATABASE keycloakdb;" 2>&1 \
                | { grep -v "already exists" || true; } || true
              # Confirm the database is now visible in pg_database.
              if docker exec banking-postgres psql -U bankuser -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname='keycloakdb'" 2>/dev/null \
                | grep -q 1; then
                _kc_db_ready=true
                break
              fi
              warn "keycloakdb not confirmed yet (attempt ${_attempt}/5) — retrying in 3s…"
              sleep 3
            done
            if [[ "$_kc_db_ready" == "true" ]]; then
              info "keycloakdb confirmed in banking-postgres."
              _KC_DB_ARGS=(
                -e KC_DB=postgres
                -e "KC_DB_URL=jdbc:postgresql://banking-postgres:5432/keycloakdb"
                -e KC_DB_USERNAME=bankuser
                -e "KC_DB_PASSWORD=${_PG_PASS}"
              )
              _KC_FEATURE_ARGS=(--features=token-exchange)
              info "Keycloak will use PostgreSQL backend with token-exchange feature."
            else
              warn "Could not confirm keycloakdb after 5 attempts — Keycloak will use H2 fallback."
            fi
          fi
        else
          warn "PostgreSQL did not start in time — Keycloak will use H2 fallback."
        fi
      else
        warn "Backend .env not found yet — Keycloak will use H2 fallback."
      fi

      docker run -d \
        --name "$KEYCLOAK_CONTAINER" \
        --network "$BANKING_NETWORK" \
        -p "${KEYCLOAK_PORT}:8080" \
        -v keycloak_data:/opt/keycloak/data \
        -e KEYCLOAK_ADMIN="$KEYCLOAK_ADMIN_USER" \
        -e KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
        -e KC_PROXY=edge \
        -e KC_HOSTNAME_STRICT=false \
        -e KC_HOSTNAME_STRICT_HTTPS=false \
        "${_KC_DB_ARGS[@]}" \
        "$KEYCLOAK_IMAGE" \
        start-dev \
        "${_KC_FEATURE_ARGS[@]}"
    fi
    ;;
  *)
    die "Keycloak container is in an unexpected state: ${KC_STATUS}"
    ;;
esac

if wait_for_keycloak; then
  success "Keycloak is ready."
else
  die "Keycloak master realm did not respond after ${KEYCLOAK_MAX_WAIT}s.
       Check logs with: docker logs ${KEYCLOAK_CONTAINER}
       Test manually:   curl http://localhost:${KEYCLOAK_PORT}/realms/master"
fi

# ── step 2: keycloak realm provisioning ───────────────────────────────────────

step "Step 2 — Keycloak realm provisioning"

provision_keycloak

# ── step 3: docker compose ────────────────────────────────────────────────────

step "Step 3 — Banking stack (docker compose)"

[[ -d "$COMPOSE_DIR" ]] || die "Compose directory not found: ${COMPOSE_DIR}"
[[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] || die "docker-compose.yml not found in ${COMPOSE_DIR}"
[[ -f "${COMPOSE_DIR}/.env" ]] || die ".env file missing in ${COMPOSE_DIR}
       Create it with at minimum: POSTGRES_PASSWORD=<password>"

# ── inject JAVA_TOOL_OPTIONS into .env if not already set ─────────────────────
# The transaction-service Dockerfile bundles the OTel Java agent at
# /app/opentelemetry-javaagent.jar.  JAVA_TOOL_OPTIONS activates it.
# Write the default only if the key is absent — do not overwrite a
# user-supplied override (e.g., extra JVM flags).
BACKEND_ENV="${COMPOSE_DIR}/.env"
if ! grep -q "^JAVA_TOOL_OPTIONS=" "${BACKEND_ENV}" 2>/dev/null; then
  printf '\nJAVA_TOOL_OPTIONS=-javaagent:/app/opentelemetry-javaagent.jar\n' >> "${BACKEND_ENV}"
  info "Added JAVA_TOOL_OPTIONS to ${BACKEND_ENV} (OTel Java agent enabled)."
fi

# ── verify observability config files exist (docker treats missing files as dirs) ──
OBS_DIR="${SCRIPT_DIR}/observability"
[[ -f "${OBS_DIR}/otel-collector-config.yaml" ]] || die \
  "Missing: ${OBS_DIR}/otel-collector-config.yaml
   This file is required for the OTel Collector.
   Re-run the project setup or create the observability/ directory manually."
[[ -f "${OBS_DIR}/prometheus.yml" ]] || die \
  "Missing: ${OBS_DIR}/prometheus.yml
   This file is required for Prometheus.
   Re-run the project setup or create the observability/ directory manually."

# In foreground mode compose blocks forever, so print URLs now (before logs fill the terminal).
# In --detach mode we print them again AFTER compose returns so they're always the last thing visible.
if [[ " ${COMPOSE_FLAGS[*]} " != *"--detach"* ]]; then
  print_urls
fi

info "Building images and starting all services…"
cd "$COMPOSE_DIR"

# Pre-pull third-party images so a transient registry failure surfaces early
# with a clear message rather than a cryptic compose error.
THIRD_PARTY_IMAGES=(
  "otel/opentelemetry-collector-contrib:0.113.0"
  "jaegertracing/all-in-one:1.62.0"
  "prom/prometheus:v2.55.0"
  "prom/alertmanager:v0.27.0"
  "grafana/grafana:11.4.0"
  "grafana/loki:3.3.2"
  "grafana/promtail:3.3.2"
  "redis:7"
  "postgres:15"
  "confluentinc/cp-kafka:8.1.1"
)
pull_failed=0
for img in "${THIRD_PARTY_IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    info "Already cached: ${img}"
  else
    info "Pulling ${img}…"
    if ! docker pull "$img" 2>&1; then
      warn "Could not pull ${img} — check Docker Hub connectivity or your VPN."
      pull_failed=1
    fi
  fi
done
if [[ $pull_failed -eq 1 ]]; then
  die "One or more third-party images failed to pull. Fix the errors above, then re-run this script."
fi

docker compose up --build --force-recreate "${COMPOSE_FLAGS[@]}"

# ── reached only when compose exits (foreground Ctrl-C or --detach) ───────────

printf '\n'
if [[ " ${COMPOSE_FLAGS[*]} " == *"--detach"* ]]; then
  success "Stack is running in the background."
  print_urls
else
  success "Stack stopped."
fi
