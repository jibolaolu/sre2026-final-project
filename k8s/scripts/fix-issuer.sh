#!/usr/bin/env bash
# Fixes: postgres password sync + KC_HOSTNAME_STRICT_HTTPS=true
set -euo pipefail
NS=banking
ENV_FILE="/mnt/c/Users/EAGLESOLUTIONS/Documents/AI_BANKING_APP/sre2026-final-project/.env"

echo "=== 1. Read POSTGRES_PASSWORD ==="
PG_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')
[ -z "$PG_PASS" ] && { echo "ERROR: POSTGRES_PASSWORD not found in .env"; exit 1; }
echo "Got password (length: ${#PG_PASS})"

echo ""
echo "=== 2. Sync postgres bankuser password ==="
PG_POD=$(kubectl get pods -n "$NS" --no-headers | awk '/techbleat-bank-postgres/{print $1; exit}')
echo "Postgres pod: $PG_POD"
kubectl exec "$PG_POD" -n "$NS" -c postgres -- \
  psql -U bankuser -d bankingdb -c "ALTER USER bankuser WITH PASSWORD '${PG_PASS}';"
echo "Password synced."

echo ""
echo "=== 3. Delete CrashLoopBackOff pods ==="
kubectl get pods -n "$NS" --no-headers | awk '/CrashLoopBackOff|OOMKilled/{print $1}' | while read p; do
  echo "Deleting: $p"
  kubectl delete pod "$p" -n "$NS" --grace-period=0 --force 2>/dev/null || true
done

echo ""
echo "=== 4. Apply KC_HOSTNAME_STRICT_HTTPS=true ==="
kubectl set env deployment/techbleat-bank-keycloak -n "$NS" KC_HOSTNAME_STRICT_HTTPS=true
echo "Applied. Waiting for rollout..."
kubectl rollout status deployment/techbleat-bank-keycloak -n "$NS" --timeout=180s

echo ""
echo "=== 5. Verify OIDC issuer (30s warmup) ==="
sleep 30
US_POD=$(kubectl get pods -n "$NS" --no-headers | awk '/techbleat-bank-user-service.*Running/{print $1; exit}')
kubectl exec "$US_POD" -n "$NS" -c user-service -- \
  python3 -c "import urllib.request,json; d=json.loads(urllib.request.urlopen('http://keycloak:8080/realms/banking/.well-known/openid-configuration',timeout=15).read()); print('issuer:',d.get('issuer'))"

echo ""
echo "=== 6. Pod state ==="
kubectl get pods -n "$NS" --no-headers
echo ""
echo "DONE. Sign out of the banking app and log back in."
