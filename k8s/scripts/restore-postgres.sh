#!/usr/bin/env bash
# restore-postgres.sh — Restore a Techbleat Global Bank PostgreSQL backup.
#
# Backups are stored on the postgres-backup-pvc (PVC mounted at /backup) as
# gzipped pg_dump files: bankingdb_YYYYMMDD_HHMMSS.sql.gz
#
# Usage:
#   bash k8s/scripts/restore-postgres.sh [BACKUP_FILE]
#
# If BACKUP_FILE is omitted, the script lists available backups and prompts.
# The restore is performed via a temporary pod that mounts the backup PVC.
#
# RPO / RTO summary (see k8s/docs/rpo-rto.md for full details):
#   RPO: ≤ 24 hours (daily backup schedule; data written after last backup is lost)
#   RTO: ≤ 30 minutes for a full database restore using this script
set -euo pipefail

NAMESPACE="${NAMESPACE:-banking}"
POSTGRES_POD_LABEL="app.kubernetes.io/component=postgres"
BACKUP_PVC="postgres-backup-pvc"
RESTORE_POD="postgres-restore-$$"

info()    { printf '\033[0;36m[restore]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[restore]\033[0m  %s\n' "$*"; }
die()     { printf '\033[0;31m[restore]\033[0m  ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  info "Cleaning up restore pod..."
  kubectl delete pod "${RESTORE_POD}" -n "${NAMESPACE}" --ignore-not-found=true --wait=false
}
trap cleanup EXIT

# ── 1. List available backups ─────────────────────────────────────────────────
info "Listing available backups on ${BACKUP_PVC}..."
BACKUP_FILE="${1:-}"

if [ -z "${BACKUP_FILE}" ]; then
  # Spin up a temporary pod to list the backup files
  kubectl run "${RESTORE_POD}-ls" \
    --image=postgres:15 \
    --restart=Never \
    --rm \
    --attach \
    -n "${NAMESPACE}" \
    --overrides="{
      \"spec\": {
        \"volumes\": [{\"name\":\"backup\",\"persistentVolumeClaim\":{\"claimName\":\"${BACKUP_PVC}\"}}],
        \"containers\": [{
          \"name\":\"ls\",
          \"image\":\"postgres:15\",
          \"command\":[\"/bin/sh\",\"-c\",\"ls -lht /backup/bankingdb_*.sql.gz 2>/dev/null || echo No backups found\"],
          \"volumeMounts\":[{\"name\":\"backup\",\"mountPath\":\"/backup\"}]
        }]
      }
    }" 2>/dev/null || true

  echo
  read -rp "Enter backup filename (e.g. bankingdb_20261022_020000.sql.gz): " BACKUP_FILE
fi

if [ -z "${BACKUP_FILE}" ]; then
  die "No backup file specified."
fi

# ── 2. Confirm ────────────────────────────────────────────────────────────────
echo
printf '\033[0;33m[restore]\033[0m  WARNING: This will DROP and recreate the bankingdb database.\n'
printf '\033[0;33m[restore]\033[0m  All data written after the backup was taken will be lost.\n'
echo
read -rp "Type 'yes' to proceed with restoring from ${BACKUP_FILE}: " CONFIRM
[ "${CONFIRM}" = "yes" ] || die "Restore cancelled."

# ── 3. Scale down services that hold DB connections ───────────────────────────
info "Scaling down transaction-service and user-service to release DB connections..."
kubectl scale deployment \
  -n "${NAMESPACE}" \
  -l "app.kubernetes.io/component in (transaction-service, user-service, activity-service)" \
  --replicas=0
kubectl rollout status deployment -n "${NAMESPACE}" \
  -l "app.kubernetes.io/component in (transaction-service, user-service, activity-service)" \
  --timeout=120s || true

# ── 4. Run restore pod ────────────────────────────────────────────────────────
info "Starting restore pod..."
POSTGRES_PASSWORD="$(kubectl get secret -n "${NAMESPACE}" banking-app-secrets \
  -o jsonpath='{.data.postgres-password}' | base64 -d)"

kubectl run "${RESTORE_POD}" \
  --image=postgres:15 \
  --restart=Never \
  -n "${NAMESPACE}" \
  --overrides="{
    \"spec\": {
      \"volumes\": [{\"name\":\"backup\",\"persistentVolumeClaim\":{\"claimName\":\"${BACKUP_PVC}\"}}],
      \"containers\": [{
        \"name\":\"restore\",
        \"image\":\"postgres:15\",
        \"env\":[{\"name\":\"PGPASSWORD\",\"value\":\"${POSTGRES_PASSWORD}\"}],
        \"command\":[\"/bin/bash\",\"-c\",\"
          set -eu
          echo '[restore] Dropping existing database...'
          psql -h postgres -U bankuser -d postgres -c 'DROP DATABASE IF EXISTS bankingdb;'
          psql -h postgres -U bankuser -d postgres -c 'CREATE DATABASE bankingdb;'
          echo '[restore] Restoring from /backup/${BACKUP_FILE}...'
          gunzip -c /backup/${BACKUP_FILE} | psql -h postgres -U bankuser -d bankingdb
          echo '[restore] Restore complete.'
        \"],
        \"volumeMounts\":[{\"name\":\"backup\",\"mountPath\":\"/backup\"}]
      }]
    }
  }"

info "Waiting for restore to complete (up to 20 minutes)..."
kubectl wait pod "${RESTORE_POD}" -n "${NAMESPACE}" \
  --for=condition=Ready --timeout=60s || true
kubectl logs -n "${NAMESPACE}" "${RESTORE_POD}" -f || true
kubectl wait pod "${RESTORE_POD}" -n "${NAMESPACE}" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=1200s

# ── 5. Scale services back up ─────────────────────────────────────────────────
info "Scaling services back up..."
kubectl scale deployment \
  -n "${NAMESPACE}" \
  -l "app.kubernetes.io/component in (transaction-service, user-service, activity-service)" \
  --replicas=1
kubectl rollout status deployment -n "${NAMESPACE}" \
  -l "app.kubernetes.io/component in (transaction-service, user-service, activity-service)" \
  --timeout=300s

success "Restore from ${BACKUP_FILE} complete."
success "Run the smoke-test checklist in k8s/docs/rpo-rto.md to verify the cluster is healthy."
