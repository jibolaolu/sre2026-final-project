# Techbleat Global Bank — RPO / RTO & Rollback Smoke Test

## Backup Strategy

| Item | Detail |
|------|--------|
| Tool | `pg_dump` (logical dump, gzip compressed) |
| Schedule | Daily at 02:00 UTC (`CronJob: postgres-backup`) |
| Storage | `postgres-backup-pvc` — 20 Gi PVC, 7-day retention |
| Location | `/backup/bankingdb_YYYYMMDD_HHMMSS.sql.gz` |
| Production upgrade | Replace PVC with S3/GCS pre-signed URL or AWS RDS snapshots |

## Recovery Point Objective (RPO)

**Target: ≤ 24 hours**

- Daily backups at 02:00 UTC mean up to 24 h of transactions can be lost in a worst-case failure.
- To reduce RPO to minutes, enable PostgreSQL streaming replication or use AWS RDS with continuous WAL archiving.

## Recovery Time Objective (RTO)

**Target: ≤ 30 minutes** for a full database restore using `k8s/scripts/restore-postgres.sh`.

Breakdown:
| Step | Estimated time |
|------|---------------|
| Identify and confirm backup file | 2 min |
| Scale down dependent services | 2 min |
| Run `pg_dump` restore (10 Gi database) | 10–20 min |
| Scale services back up and stabilise | 5 min |
| Smoke test verification | 5 min |
| **Total** | **≤ 30 min** |

## Restore Procedure

```bash
# List available backups and restore interactively
bash k8s/scripts/restore-postgres.sh

# Or restore a specific backup file directly
bash k8s/scripts/restore-postgres.sh bankingdb_20261022_020000.sql.gz
```

## Post-Restore Smoke Test Checklist (A9)

Run these checks after every restore **and** after every `helm rollback`:

### 1. Pod health

```bash
kubectl get pods -n banking
# Expected: all pods 1/1 Running, 0 CrashLoopBackOff
```

### 2. Database connectivity

```bash
kubectl exec -n banking techbleat-bank-postgres-0 -- \
  psql -U bankuser -d bankingdb -c "SELECT COUNT(*) FROM users;"
# Expected: returns a row count (not an error)
```

### 3. Keycloak token endpoint

```bash
curl -s -o /dev/null -w "%{http_code}" \
  http://keycloak.techbleat-bank.local/realms/banking/.well-known/openid-configuration
# Expected: 200
```

### 4. User-service health

```bash
curl -s http://techbleat-bank.local/api/users/health
# Expected: {"status":"ok"}
```

### 5. Transaction-service health

```bash
curl -s http://techbleat-bank.local/api/transactions/actuator/health
# Expected: {"status":"UP"}
```

### 6. Finance-agent health

```bash
curl -s http://techbleat-bank.local/api/agent/health
# Expected: {"status":"ok"}
```

### 7. End-to-end login

1. Open `http://techbleat-bank.local` in a browser.
2. Log in with a known test account.
3. Check account balance returns a number (not an error).
4. Confirm recent transaction history is visible.

### 8. Prometheus targets

```bash
kubectl port-forward -n banking svc/prometheus 9090:9090 &
# Open http://localhost:9090/targets — all targets should be UP.
```

## Helm Rollback Procedure

```bash
# List release history
helm history techbleat-bank -n banking

# Roll back to the previous version
helm rollback techbleat-bank -n banking

# Roll back to a specific revision
helm rollback techbleat-bank <REVISION> -n banking

# Monitor rollout
kubectl rollout status deployment -n banking --selector app.kubernetes.io/instance=techbleat-bank

# Run smoke tests above
```
