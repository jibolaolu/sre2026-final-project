# Techbleat Global Bank — Threat Model

**Version:** 1.0  
**Date:** 2026-10-22  
**Scope:** Kubernetes-deployed banking application (minikube / EKS)

---

## 1. Architecture Overview

```
Internet
  │
  ▼
[Nginx Ingress] ──── TLS termination (cert-manager / ACM)
  │
  ├── techbleat-bank.local     → [Frontend (React/Nginx)]
  │                                │
  │                                ├── POST /users          → [user-service]  → [PostgreSQL]
  │                                ├── /transactions/*      → [transaction-service] → [PostgreSQL, Kafka]
  │                                ├── /activities/*        → [activity-service]  → [PostgreSQL]
  │                                └── /chat                → [finance-agent] → [Anthropic/OpenAI API]
  │
  └── keycloak.techbleat-bank.local → [Keycloak] → [PostgreSQL]
```

**Identity flow:** Browser → Keycloak (OIDC/PKCE) → Access token → API services (JWT RS256 verification via JWKS endpoint)

---

## 2. Trust Boundaries

| Boundary | Description |
|----------|-------------|
| **T1** Internet → Ingress | Untrusted; TLS required |
| **T2** Ingress → Services | In-cluster; NetworkPolicy enforced |
| **T3** Services → PostgreSQL | In-cluster; password auth; NetworkPolicy enforced |
| **T4** Services → Kafka | In-cluster; NetworkPolicy enforced |
| **T5** finance-agent → External AI APIs | Egress through WSL2 proxy (local) or NAT gateway (EKS) |
| **T6** CI → Docker Hub / GitHub | Secrets via GitHub Actions secrets |

---

## 3. Assets

| Asset | Sensitivity | Protection |
|-------|-------------|------------|
| User credentials (passwords) | Critical | Keycloak-managed; never stored by services |
| Account balances / transactions | High | PostgreSQL encrypted at rest (EKS); JWT ownership check |
| JWT access tokens | High | Short-lived (5 min default); HTTPS in transit |
| Postgres password | Critical | Kubernetes Secret; `.env` gitignored |
| Keycloak admin secret | Critical | Kubernetes Secret; not in logs |
| AI API keys (OpenAI, Anthropic) | High | Kubernetes Secret; stripped of `\r` before use |
| Kafka messages | Medium | In-cluster only; contains userId + transaction events |

---

## 4. STRIDE Threat Analysis

### T1: Internet → Ingress

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Intercept cleartext traffic | Information Disclosure | High | TLS enforced (nginx ssl-redirect); cert-manager issues certs |
| Brute-force Keycloak login | Elevation of Privilege | Medium | Keycloak brute-force policy; rate limiting via Nginx |
| DDoS against Ingress | Denial of Service | Medium | HPA + PDB limit blast radius; cloud-level WAF for EKS |

### T2: Services — Authentication & Authorization (A4/A5)

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Forged JWT (unsigned) | Spoofing | Critical | All services verify RS256 signature against Keycloak JWKS |
| Expired token reuse | Elevation of Privilege | Medium | `exp` claim verified by PyJWT / Spring Security |
| Cross-user data access | Elevation of Privilege | High | JWT `preferred_username` compared to path/resource userId; 403 on mismatch |
| Bypass via X-User-Id header | Spoofing | High | JWT claim takes precedence; X-User-Id only accepted in no-auth dev mode |
| Access AI agent without role | Elevation of Privilege | Medium | `banking-ai-agent` realm role enforced by `require_ai_agent_user` in finance-agent |

### T3: Secrets Management (A6)

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Secret committed to Git | Information Disclosure | Critical | `.gitignore` covers `.env`; gitleaks in CI; pre-commit hook |
| Secret leaked in container logs | Information Disclosure | High | Secrets mounted as env vars (not echoed); log levels reviewed |
| Secret leaked in image layers | Information Disclosure | Medium | `--secret` build arg for sensitive values; Trivy SBOM scan |

### T4: Backup & Restore (A7)

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Backup PVC accessible to other pods | Information Disclosure | Medium | NetworkPolicy restricts access; backup pod uses dedicated SA |
| Corrupt restore wipes live data | Tampering | High | Restore requires explicit `yes` confirmation; services scaled down first |

### T5: CI/CD Pipeline (A8)

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Malicious dependency in image | Tampering | High | Trivy blocks CRITICAL/HIGH CVEs; SBOM generated per image |
| Unsigned image deployed | Tampering | Medium | cosign keyless signing via OIDC; digest verified at deploy time |
| Secret exfiltration in CI | Information Disclosure | High | GitHub Actions secrets never printed; gitleaks scans history |

### T6: Observability (A10)

| Threat | Category | Risk | Mitigation |
|--------|----------|------|------------|
| Prometheus scrape endpoint leaks internals | Information Disclosure | Low | `/metrics` + `/actuator/prometheus` in-cluster only; no Ingress route |
| Log injection via user input | Tampering | Low | Structured JSON logging; no raw string concatenation in log calls |

---

## 5. Residual Risks & Accepted Gaps

| ID | Gap | Accepted Risk | Remediation Path |
|----|-----|---------------|------------------|
| R1 | No WAF (Web Application Firewall) | Medium — DDoS/injection mitigated by app-level validation | Add AWS WAFv2 in front of ALB for EKS deployment |
| R2 | Postgres plaintext in-cluster (no TLS) | Low — NetworkPolicy restricts access to authorised pods only | Enable `ssl = on` in Postgres config + sslmode=require in JDBC URL |
| R3 | Kafka no authentication | Low — In-cluster only, no external access | Add SASL/SCRAM if Kafka is exposed externally |
| R4 | No mTLS between services (Istio disabled) | Low — NetworkPolicy enforces pod-to-pod allow-lists | Enable `istio.enabled: true` + `mtls: STRICT` for zero-trust mesh |
| R5 | Single Postgres instance (no HA) | Medium — SPOF for all services | Add read replica or migrate to AWS RDS Multi-AZ |

---

## 6. Security Controls Summary

| Control | Status |
|---------|--------|
| TLS at Ingress | ✅ cert-manager (minikube), ACM (EKS) |
| JWT RS256 verification (all services) | ✅ A4 fixed |
| Cross-user ownership checks | ✅ A5 fixed |
| banking-ai-agent role enforcement | ✅ A11 fixed |
| Secrets not in Git | ✅ .gitignore + gitleaks + pre-commit |
| Trivy CVE scanning (blocking) | ✅ A8 fixed |
| SBOM generation | ✅ syft per image |
| Image signing | ✅ cosign keyless |
| Daily backup with 7-day retention | ✅ CronJob |
| Restore script with smoke test | ✅ A7 fixed |
| SLO burn-rate alerting | ✅ A10 fixed |
| NetworkPolicy default-deny | ✅ A2 (existing) |
| OIDC/PKCE login | ✅ A3 (existing) |
