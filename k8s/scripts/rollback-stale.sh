#!/usr/bin/env bash
# Roll back Keycloak and transaction-service to their last known-good ReplicaSets.
# The most-recent RS keeps crashing (wrong postgres password or config mismatch
# from a partial helm upgrade). Rolling back stops the crash-restart loop and
# restores the running healthy pods.
kubectl rollout undo deployment/techbleat-bank-keycloak -n banking
kubectl rollout undo deployment/techbleat-bank-transaction-service -n banking
echo "Rollback issued. Current pods:"
kubectl get pods -n banking --no-headers
