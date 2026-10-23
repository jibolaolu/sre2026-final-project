# Techbleat Global Bank — Kubernetes Deployment Guide

## Directory layout

```
k8s/
├── helm/
│   └── techbleat-bank/
│       ├── Chart.yaml
│       ├── values.yaml              # base defaults (all environments)
│       ├── values-local.yaml        # kind / Docker Desktop overrides
│       ├── values-eks.yaml          # AWS EKS overrides
│       └── templates/
│           ├── _helpers.tpl
│           ├── configmaps/          # postgres-init.sql, keycloak-realm.json
│           ├── cronjobs/            # postgres-backup (daily, 7-day retention)
│           ├── deployments/         # one file per service + keycloak
│           ├── hpa/                 # HorizontalPodAutoscaler for all services
│           ├── ingress/             # NGINX ingress (frontend + keycloak hosts)
│           ├── jobs/                # keycloak-provisioner (Helm post-install hook)
│           ├── networkpolicies/     # default-deny + per-service allow rules
│           ├── pdb/                 # PodDisruptionBudgets
│           ├── secrets/             # banking-app-secrets (dev placeholders)
│           ├── serviceaccounts/     # one SA per component, no token automount
│           ├── services/            # ClusterIP services for all components
│           └── statefulsets/        # postgres, redis, kafka
├── istio/
│   ├── peer-authentication.yaml     # STRICT mTLS for the banking namespace
│   ├── authorization-policy/        # deny-all + per-service allow rules
│   └── destination-rules/           # mTLS per service
├── scripts/
│   ├── kind-config.yaml             # kind cluster with port 80/443 mapped
│   ├── deploy-local.sh              # kind + Docker Hub one-step deploy
│   └── deploy-eks.sh                # AWS EKS deploy
└── README.md                        # this file
```

---

## Prerequisites

### Local (minikube)

| Tool | Min version | Install |
|------|------------|---------|
| Docker | 24+ | https://docs.docker.com/get-docker/ |
| minikube | 1.33+ | https://minikube.sigs.k8s.io/docs/start/ |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.15+ | https://helm.sh/docs/intro/install/ |
| Docker Hub account | — | https://hub.docker.com/ (free tier is fine) |

### EKS (additional)

| Tool | Notes |
|------|-------|
| aws cli v2 | `aws configure` with a role that has ECR push + EKS access |
| eksctl | Simplifies cluster creation |
| AWS Load Balancer Controller | Required for ALB Ingress (values-eks.yaml) |
| ACM certificate | ARN goes in `values-eks.yaml ingress.annotations` |

---

## Local deployment (minikube + Docker Hub)

```bash
# Run the deploy script from the repo root
# Credentials are loaded automatically from .env
bash k8s/scripts/deploy-local.sh
```

The script will:
1. Start a minikube cluster (`techbleat-bank`) using the Docker driver (no host port conflicts)
2. Enable the built-in NGINX ingress addon
3. Build all five service images and push to Docker Hub, then load into minikube
4. Run `helm upgrade --install` with `values.yaml` + `values-local.yaml`
5. The `keycloak-provisioner` Helm post-install Job completes the Keycloak realm setup

After the script finishes, get your minikube IP:
```bash
minikube ip --profile techbleat-bank
```

Add to `/etc/hosts` (WSL: `/etc/hosts`; Windows: `C:\Windows\System32\drivers\etc\hosts`):
```
<minikube-ip>   techbleat-bank.local   keycloak.techbleat-bank.local
```

Then start the tunnel in a **separate terminal** (keep it running):
```bash
minikube tunnel --profile techbleat-bank
```

Access the application:

| Service | URL |
|---------|-----|
| Frontend | http://techbleat-bank.local |
| Keycloak admin | http://keycloak.techbleat-bank.local/admin (admin / admin) |
| Demo user | bankingdemo / Demo@2024 |
| Dashboard | `minikube dashboard --profile techbleat-bank` |

For observability, use port-forward (not exposed via ingress):
```bash
kubectl port-forward svc/jaeger     16686:16686  -n banking
kubectl port-forward svc/prometheus  9090:9090   -n banking
```

---

## HTTPS (TLS) — local with cert-manager

To enable TLS locally:

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=60s

# Create a self-signed ClusterIssuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# Re-deploy with TLS enabled
helm upgrade techbleat-bank k8s/helm/techbleat-bank \
  -n banking --reuse-values \
  --set tls.enabled=true
```

---

## Secrets management

**Local / CI dev:** Override `secrets.*` via `--set` at deploy time.
Never commit real secrets — `values.yaml` ships with `"changeme"` placeholders.

**Production (AWS):** Use the External Secrets Operator:
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

See the `ExternalSecret` example in `templates/secrets/app-secrets.yaml`.

GitHub Actions secrets required for CI/CD:
| Secret | Purpose |
|--------|---------|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (read/write) |
| `POSTGRES_PASSWORD` | Postgres password to deploy with |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | Secret for banking-provisioner client |
| `AWS_ACCESS_KEY_ID` | (EKS only) |
| `AWS_SECRET_ACCESS_KEY` | (EKS only) |

GitHub Actions variables (`vars.*`):
| Variable | Purpose |
|----------|---------|
| `VITE_KEYCLOAK_URL` | Public Keycloak URL baked into frontend image |
| `EKS_CLUSTER_NAME` | (EKS only) |
| `AWS_REGION` | (EKS only, default: us-east-1) |
| `AWS_ACCOUNT_ID` | (EKS only) |

---

## Requirement coverage

| ID | Requirement | Implementation |
|----|------------|---------------|
| A1 | HTTPS with valid cert | NGINX ingress + cert-manager (self-signed local, ACM on EKS) |
| A2 | Only approved public routes reachable | NetworkPolicy default-deny + per-service allow; Ingress exposes only frontend and Keycloak |
| A3 | OIDC with PKCE | Keycloak banking realm, banking-frontend client with S256 PKCE, KC_HOSTNAME set |
| A4 | Invalid tokens rejected | `KEYCLOAK_JWK_SET_URI` wired to transaction-service; user-service validates via Keycloak token exchange |
| A5 | Cross-account access denied | Transaction-service enforces user_id == token sub; ownership checked server-side |
| A6 | Least privilege; no secrets in Git | K8s Secrets from Helm `--set`; `automountServiceAccountToken: false` on all SAs; gitleaks in CI |
| A7 | Data encrypted, backups, restore demo | Postgres backup CronJob (daily, 7-day retention); restore via `psql < backup.sql.gz` |
| A8 | CI tests, scans, versioned images | GitHub Actions: build → Trivy scan → push with git-SHA tag → SBOM via syft |
| A9 | Rollback demonstrated | `helm rollback techbleat-bank <revision> -n banking` |
| A10 | Dashboards without sensitive data | Prometheus + Grafana + Jaeger; sensitive fields excluded from OTel attribute config |
| A11 | FinanceAgent secured | JWT validated at finance-agent API boundary; read-only tools only; guardrails in agent.py |
| A12 | Documentation for another engineer | This README + `deploy-local.sh` + `deploy-eks.sh` |

---

## Rollback procedure (A9)

```bash
# List release history
helm history techbleat-bank -n banking

# Rollback to previous revision
helm rollback techbleat-bank -n banking

# Or rollback to a specific revision
helm rollback techbleat-bank 2 -n banking
```

---

## EKS migration checklist

1. Create your EKS cluster and configure `kubectl`.
2. Install the [AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html).
3. Push images to ECR (or Docker Hub — update `global.imageRegistry`).
4. Request an ACM certificate for your domain and note the ARN.
5. Update `values-eks.yaml`:
   - `global.imageRegistry`: your ECR or Docker Hub registry prefix
   - `ingress.annotations.alb.ingress.kubernetes.io/certificate-arn`: your ACM ARN
   - `ingress.hosts[*].host`: your public domain
   - `publicFrontendUrl` / `publicKeycloakUrl`: your HTTPS domains
6. Run the deploy script:
   ```bash
   AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 EKS_CLUSTER_NAME=my-cluster \
     bash k8s/scripts/deploy-eks.sh
   ```
7. Verify: `kubectl get pods -n banking && kubectl get ingress -n banking`

---

## Adding Istio (optional — for strict mTLS)

```bash
# Install Istio demo profile
istioctl install --set profile=demo -y

# Enable sidecar injection for the banking namespace
kubectl label namespace banking istio-injection=enabled --overwrite

# Restart pods so sidecars are injected
kubectl rollout restart deployment -n banking

# Apply Istio policies
kubectl apply -f k8s/istio/peer-authentication.yaml
kubectl apply -f k8s/istio/authorization-policy/
kubectl apply -f k8s/istio/destination-rules/
```
