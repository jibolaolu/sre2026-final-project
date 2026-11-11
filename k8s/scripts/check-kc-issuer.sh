#!/usr/bin/env bash
kubectl exec -n banking techbleat-bank-keycloak-58c9759bb9-chpdj -c keycloak -- \
  curl -s http://localhost:8080/realms/banking/.well-known/openid-configuration \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('issuer:', d.get('issuer'))"
