#!/usr/bin/env bash
# permanent-fix.sh — Deploy the correct Helm revision with:
#   KC_HOSTNAME=https://auth.eaglesoncloude.com (full URL → https:// issuer)
#   KC_HOSTNAME_STRICT_HTTPS=true (hardcoded in template already)
# Also suspends ArgoCD auto-sync so it can't revert us.
set -euo pipefail

NS=banking
CHART_DIR="./helm/techbleat-bank"
VALUES_BASE="${CHART_DIR}/values.yaml"
VALUES_LOCAL="${CHART_DIR}/values-local.yaml"

echo "============================================================"
echo "=== Step 1: Read secrets from existing k8s secret ==="
echo "============================================================"
# Read from the secret that's already in the cluster (avoids password mismatch)
PG_PASS=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.postgres-password}' | base64 -d)
KC_ADMIN_PASS=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.keycloak-admin-password}' | base64 -d)
KC_CLIENT_SECRET=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.keycloak-admin-client-secret}' 2>/dev/null | base64 -d || echo "changeme")
TXN_SECRET=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.transaction-service-kc-secret}' 2>/dev/null | base64 -d || echo "changeme")
ACT_SECRET=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.activity-service-kc-secret}' 2>/dev/null | base64 -d || echo "changeme")
FA_SECRET=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.finance-agent-kc-secret}' 2>/dev/null | base64 -d || echo "changeme")
OAI_KEY=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.openai-api-key}' 2>/dev/null | base64 -d || echo "changeme")
ANT_KEY=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.anthropic-api-key}' 2>/dev/null | base64 -d || echo "changeme")
DD_KEY=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.datadog-api-key}' 2>/dev/null | base64 -d || echo "changeme")
DEMO_PASS=$(kubectl get secret banking-app-secrets -n "$NS" \
  -o jsonpath='{.data.keycloak-demo-password}' 2>/dev/null | base64 -d || echo "Demo@2024")
echo "Secrets read from cluster."

echo ""
echo "============================================================"
echo "=== Step 2: Suspend ArgoCD auto-sync (stop the reverter) ==="
echo "============================================================"
if kubectl get application techbleat-bank -n argocd &>/dev/null; then
  kubectl patch application techbleat-bank -n argocd \
    --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null \
    && echo "ArgoCD auto-sync suspended for techbleat-bank." \
    || echo "WARNING: Could not patch ArgoCD app (may need manual patch). Continuing..."
else
  echo "ArgoCD app not found in argocd namespace — skipping."
fi

echo ""
echo "============================================================"
echo "=== Step 3: Helm upgrade with correct values ==="
echo "============================================================"
echo "KC_HOSTNAME will be: https://auth.eaglesoncloude.com (from values-local.yaml)"
echo "KC_HOSTNAME_STRICT_HTTPS will be: true (hardcoded in template)"
helm upgrade techbleat-bank "$CHART_DIR" \
  -n "$NS" \
  -f "$VALUES_BASE" \
  -f "$VALUES_LOCAL" \
  --set "secrets.postgresPassword=${PG_PASS}" \
  --set "secrets.keycloakAdminPassword=${KC_ADMIN_PASS}" \
  --set "secrets.keycloakAdminClientSecret=${KC_CLIENT_SECRET}" \
  --set "secrets.transactionServiceKcSecret=${TXN_SECRET}" \
  --set "secrets.activityServiceKcSecret=${ACT_SECRET}" \
  --set "secrets.financeAgentKcSecret=${FA_SECRET}" \
  --set "secrets.openaiApiKey=${OAI_KEY}" \
  --set "secrets.anthropicApiKey=${ANT_KEY}" \
  --set "secrets.datadogApiKey=${DD_KEY}" \
  --set "secrets.keycloakDemoPassword=${DEMO_PASS}" \
  --timeout 10m \
  --wait=false
echo "Helm upgrade submitted (revision 3)."

echo ""
echo "============================================================"
echo "=== Step 4: Watch Keycloak pod come up ==="
echo "============================================================"
echo "Waiting 15s for old pod to terminate..."
sleep 15
kubectl rollout status deployment/techbleat-bank-keycloak -n "$NS" --timeout=300s || {
  echo "Rollout status timed out — checking pod directly..."
  kubectl get pods -n "$NS" --no-headers | grep keycloak
}

echo ""
echo "============================================================"
echo "=== Step 5: Verify deployment spec ==="
echo "============================================================"
echo -n "KC_HOSTNAME in spec: "
kubectl get deployment techbleat-bank-keycloak -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_HOSTNAME")].value}'
echo ""
echo -n "KC_HOSTNAME_STRICT_HTTPS in spec: "
kubectl get deployment techbleat-bank-keycloak -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_HOSTNAME_STRICT_HTTPS")].value}'
echo ""

echo ""
echo "============================================================"
echo "=== Step 6: Verify OIDC issuer (wait 60s for Keycloak warmup) ==="
echo "============================================================"
echo "Waiting 60s for Keycloak to finish starting..."
sleep 60
US_POD=$(kubectl get pods -n "$NS" --no-headers | awk '/techbleat-bank-user-service.*Running/{print $1; exit}')
if [ -n "$US_POD" ]; then
  kubectl exec "$US_POD" -n "$NS" -c user-service -- \
    python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://keycloak:8080/realms/banking/.well-known/openid-configuration', timeout=20)
    d = json.loads(r.read())
    issuer = d.get('issuer','')
    print('OIDC issuer:', issuer)
    if issuer.startswith('https://'):
        print('SUCCESS: issuer is https:// — Invalid issuer error will be gone!')
    else:
        print('PROBLEM: issuer is still http:// — need to investigate further')
except Exception as e:
    print('Keycloak not ready yet:', e)
" 2>&1
else
  echo "user-service pod not Running yet — check manually with bash scripts/deep-dive.sh"
fi

echo ""
echo "============================================================"
echo "=== Step 7: Final pod state ==="
echo "============================================================"
kubectl get pods -n "$NS" --no-headers
echo ""
echo "DONE. Now:"
echo "  1. Sign out of the banking app completely"
echo "  2. Sign back in to get a fresh token with the new https:// issuer"
echo "  3. Push the Helm chart changes to git so ArgoCD stays in sync"
