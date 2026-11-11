#!/usr/bin/env bash
# Deep-dive: find what keeps reverting the Keycloak issuer fix
NS=banking

echo "============================================================"
echo "=== 1. LIVE Keycloak pod env (all KC_* vars) ==="
echo "============================================================"
KC_POD=$(kubectl get pods -n "$NS" --no-headers | awk '/techbleat-bank-keycloak.*Running/{print $1; exit}')
echo "Pod: $KC_POD"
kubectl exec "$KC_POD" -n "$NS" -c keycloak -- env 2>/dev/null | grep -E "^KC_" | sort

echo ""
echo "============================================================"
echo "=== 2. OIDC discovery issuer (internal) ==="
echo "============================================================"
US_POD=$(kubectl get pods -n "$NS" --no-headers | awk '/techbleat-bank-user-service.*Running/{print $1; exit}')
kubectl exec "$US_POD" -n "$NS" -c user-service -- \
  python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://keycloak:8080/realms/banking/.well-known/openid-configuration', timeout=15)
    d = json.loads(r.read())
    print('issuer:', d.get('issuer'))
    print('token_endpoint:', d.get('token_endpoint'))
except Exception as e:
    print('ERROR:', e)
" 2>&1

echo ""
echo "============================================================"
echo "=== 3. KEYCLOAK_ISSUER in all backend services ==="
echo "============================================================"
for svc in user-service activity-service finance-agent; do
  POD=$(kubectl get pods -n "$NS" --no-headers | awk "/techbleat-bank-${svc}.*Running/{print \$1; exit}")
  VAL=$(kubectl exec "$POD" -n "$NS" -c "$svc" -- env 2>/dev/null | grep KEYCLOAK_ISSUER || echo "(not found)")
  echo "$svc: $VAL"
done

echo ""
echo "============================================================"
echo "=== 4. Helm release state ==="
echo "============================================================"
helm status techbleat-bank -n "$NS" 2>/dev/null | grep -E "STATUS|REVISION|LAST DEPLOYED" || echo "helm status failed"
helm history techbleat-bank -n "$NS" --max 5 2>/dev/null || echo "helm history failed"

echo ""
echo "============================================================"
echo "=== 5. ArgoCD: is it managing the banking app? ==="
echo "============================================================"
kubectl get applications -n argocd 2>/dev/null || echo "No ArgoCD applications found (or argocd namespace missing)"
kubectl get applications -A 2>/dev/null | grep -i "bank\|techbleat" || echo "No banking ArgoCD apps found"

echo ""
echo "============================================================"
echo "=== 6. Any CronJobs or Jobs in banking namespace? ==="
echo "============================================================"
kubectl get cronjobs -n "$NS" 2>/dev/null
kubectl get jobs -n "$NS" 2>/dev/null | tail -5

echo ""
echo "============================================================"
echo "=== 7. Deployment annotation — who last changed keycloak? ==="
echo "============================================================"
kubectl get deployment techbleat-bank-keycloak -n "$NS" \
  -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(no annotations)"

echo ""
echo "============================================================"
echo "=== 8. ReplicaSets for keycloak (shows rollout history) ==="
echo "============================================================"
kubectl get replicasets -n "$NS" -l app.kubernetes.io/component=keycloak \
  --sort-by=.metadata.creationTimestamp 2>/dev/null

echo ""
echo "============================================================"
echo "=== 9. Deployment spec KC_HOSTNAME and KC_HOSTNAME_STRICT_HTTPS ==="
echo "============================================================"
echo -n "KC_HOSTNAME in spec: "
kubectl get deployment techbleat-bank-keycloak -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_HOSTNAME")].value}' 2>/dev/null
echo ""
echo -n "KC_HOSTNAME_STRICT_HTTPS in spec: "
kubectl get deployment techbleat-bank-keycloak -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_HOSTNAME_STRICT_HTTPS")].value}' 2>/dev/null
echo ""

echo ""
echo "============================================================"
echo "=== 10. Recent Kubernetes events for keycloak deployment ==="
echo "============================================================"
kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null \
  | grep -i keycloak | tail -15
