# OTP Relay Kubernetes — Project Documentation

**Repository:** [psi1703/k8s](https://github.com/psi1703/k8s)  
**License:** MIT  
**Status:** Phase 3 SCH-alignment validation baseline  

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Technology Stack](#4-technology-stack)
5. [How It Works](#5-how-it-works)
6. [Cluster Configuration](#6-cluster-configuration)
7. [Deployment Guide](#7-deployment-guide)
8. [Environment Variables & Secrets](#8-environment-variables--secrets)
9. [API Reference](#9-api-reference)
10. [Redis HA Model](#10-redis-ha-model)
11. [NFS Shared Storage](#11-nfs-shared-storage)
12. [TLS & DNS](#12-tls--dns)
13. [Monitor Service](#13-monitor-service)
14. [Observability & Grafana Dashboard](#14-observability--grafana-dashboard)
15. [Operations Runbook](#15-operations-runbook)
16. [Troubleshooting](#16-troubleshooting)
17. [Development Guide](#17-development-guide)
18. [Validation Checklists](#18-validation-checklists)
19. [SCH Production Alignment](#19-sch-production-alignment)

---

## 1. Project Overview

**OTP Relay** is an internal, LAN-only One-Time Password relay portal deployed on Kubernetes (K3s). It bridges iOS Shortcuts and a web-based portal so that OTPs received via SMS on a company iPhone can be securely displayed to a waiting user in their browser — without exposing any SMS gateway or routing OTPs through email.

### Key characteristics

- No external API dependencies; runs entirely on the company LAN.
- OTP values are **never written to disk** — runtime state is held in Redis with TTL expiry.
- Persistent application files (users, audit log, wizard state, admin config) are stored on an NFS-backed shared volume at `/app/data`.
- The portal is exposed over HTTPS through a Traefik ingress. All other services use `ClusterIP` with no public exposure.
- A dedicated monitor pod runs with `hostNetwork` and `NET_RAW` to check phone presence and send Telegram alerts for iPhone state changes. It has no Service and no Ingress.

---

## 2. Architecture

### High-level traffic flow

```
Client browser
  ──► DNS: srvotptest26.init-db.lan
  ──► Traefik HTTPS Ingress (TLS termination)
  ──► Kubernetes Service: otp-relay (ClusterIP)
  ──► FastAPI portal pod (2 replicas, RollingUpdate)
  ──► Redis HAProxy service
  ──► Redis Sentinel-managed master/replicas (StatefulSet × 3)
  ──► NFS /app/data (users.xlsx, audit.log, wizard state, admin config)

iPhone (receives OTP via SMS)
  ──► iOS Shortcut
  ──► POST /sms-received
  ──► FastAPI portal
  ──► Redis (pending OTP state, TTL-gated)
  ──► Browser polling (/otp-status) displays OTP to waiting user

Monitor pod
  ──► hostNetwork + NET_RAW
  ──► Phone presence checks
  ──► SMS-path checks
  ──► Shared audit log checks
  ──► Telegram alerts
  (no Service / no Ingress)
```

### Topology diagram

```
                  ┌─────────────────────────────┐
                  │   srvotptest26.init-db.lan   │
                  └──────────────┬──────────────┘
                                 │
                  ┌──────────────▼──────────────┐
                  │   Traefik HTTPS Ingress      │
                  └──────────────┬──────────────┘
                                 │
                  ┌──────────────▼──────────────┐
                  │   Service: otp-relay         │
                  │   Type: ClusterIP            │
                  └──────┬───────────────┬───────┘
                         │               │
            ┌────────────▼──┐       ┌───▼────────────┐
            │ otp-relay pod │       │ otp-relay pod  │
            │ FastAPI       │       │ FastAPI        │
            └────────┬──────┘       └──────┬─────────┘
                     └──────────┬──────────┘
                                │
                  ┌─────────────▼──────────────┐
                  │  Service: otp-redis-haproxy │
                  └──────┬──────────────┬───────┘
                         │              │
              ┌──────────▼──┐      ┌───▼──────────┐
              │ HAProxy pod │      │ HAProxy pod  │
              │ otp-worker-1│      │ otp-worker-2 │
              └──────┬──────┘      └──────┬───────┘
                     └──────────┬──────────┘
                                │
                  ┌─────────────▼──────────────┐
                  │  Redis StatefulSet (× 3)    │
                  │  Sentinel-managed           │
                  └─────────────────────────────┘
```

---

## 3. Repository Structure

```
.
├── main.py                              # FastAPI portal application
├── monitor.py                           # Monitor service logic and Prometheus metrics
├── requirements.txt                     # Python dependencies
├── install-otp-relay-k8s.sh             # Deployment installer script
├── otp-relayk3s-monitor.sh              # Symlinked health-check script
├── package.json / package-lock.json     # Node.js frontend tooling
├── .dockerignore
├── .gitignore
├── LICENSE
│
├── frontend/
│   ├── app.jsx                          # React source of truth
│   ├── app.js                           # Generated production bundle served by portal
│   ├── index.html                       # Portal entry point
│   ├── style.css                        # Portal styles
│   ├── guide.html                       # Pop-out RTA wizard guide
│   └── help/                            # Generated help output
│       ├── manifest.json
│       ├── wizard-guide.json
│       ├── rendered/                    # Generated HTML help pages
│       └── assets/                      # Copied/generated help screenshots
│
├── docs/
│   ├── help/                            # Help page markdown sources
│   │   └── assets/                      # Help screenshot sources
│   ├── architecture/
│   ├── deployment/
│   ├── development/
│   └── operations/
│
├── scripts/
│   ├── build_help_docs.py               # Converts docs/help/ → frontend/help/
│   ├── build_grafana_dashboard_configmap.py
│   │                                    # Converts Grafana dashboard source → ConfigMap
│   └── generate_sample_users.py
│
├── k8s/
│   ├── Dockerfile                       # Portal app image
│   ├── Dockerfile.monitor               # Monitor image
│   ├── manifests/                       # Core Kubernetes YAML manifests
│   └── observability/
│       ├── dashboards/
│       │   └── otp-relay-live.json      # Grafana dashboard source of truth
│       ├── grafana-dashboard-otp-relay-live.yaml
│       │                                # Generated dashboard ConfigMap
│       ├── grafana-ingressroute.yaml
│       ├── prometheus-stack-values.yaml
│       ├── loki-values.yaml
│       ├── alloy-values.yaml
│       ├── servicemonitor-otp-relay.yaml
│       └── servicemonitor-otp-monitor.yaml
│
└── .github/
    └── workflows/                       # GitHub Actions CI/CD
```

### Source-of-truth rules

| Area | Edit this | Generate this | Command |
|------|-----------|---------------|---------|
| Frontend | `frontend/app.jsx` | `frontend/app.js` | Installer / frontend build |
| Help docs | `docs/help/*.md`, `docs/help/assets/*` | `frontend/help/*` | `python3 scripts/build_help_docs.py` |
| Grafana dashboard | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` | `python3 scripts/generate_grafana_dashboard_configmap.py` |

> **Important:** `frontend/app.jsx` is the React source. `frontend/app.js` is the generated production bundle actually served by the portal. Make frontend behavior changes in `app.jsx`, rebuild `app.js`, and commit both when the generated bundle changes.

> **Single source of truth:** The root `README.md` is the canonical operational document. Do **not** restore legacy doc paths (`docs/k8s-plan.md`, `k8s/docs/`, `docs/dev/`, `docs/diagrams/`).

---

## 4. Technology Stack

### Backend

| Component | Technology |
|-----------|-----------|
| Portal API | FastAPI + Python 3.12 |
| ASGI server | Uvicorn (standard extras) |
| User store | `openpyxl` reads `users.xlsx` |
| Runtime state | Redis ≥ 5.0.0 |
| Auth hashing | `bcrypt` |
| Configuration | `python-dotenv` |
| Help doc build | `markdown`, `pyyaml` |

**Python dependencies (`requirements.txt`):**
```
fastapi
uvicorn[standard]
openpyxl
python-dotenv
bcrypt
pydantic
markdown
pyyaml
python-multipart
redis>=5.0.0,<6.0.0
```

### Frontend

| Component | Technology |
|-----------|-----------|
| UI | React (JSX → bundled `app.js`) |
| Styling | CSS (`style.css`) |
| Help pages | Generated static HTML |

> Do **not** use browser-side Babel or `text/babel` scripts — the production model is a pre-built bundle.

### Infrastructure

| Component | Technology |
|-----------|-----------|
| Container runtime | K3s (embedded containerd) |
| Ingress | Traefik (bundled with K3s) |
| Redis HA | StatefulSet + Sentinel + HAProxy |
| Storage | NFS RWX PVC |
| CI/CD | GitHub Actions + self-hosted runner |
| Images | Built locally, imported via `k3s ctr images import` |

### Observability

| Component | Technology |
|-----------|-----------|
| Metrics | Prometheus via kube-prometheus-stack |
| Dashboards | Grafana provisioned from ConfigMap |
| App metrics | `/metrics` from portal and monitor |
| Scrape config | `ServiceMonitor` resources |
| Logs | Loki + Alloy |
| Dashboard source | Grafana `dashboard.grafana.app/v2` JSON converted to classic JSON for provisioning |

---

## 5. How It Works

### OTP flow (end-to-end)

1. A user navigates to `https://srvotptest26.init-db.lan` and logs in with their 2–3 character token.
2. The portal validates the token against `users.xlsx` via `POST /user/login`.
3. The user claims the OTP slot via `POST /claim` — their token is enqueued in Redis.
4. Meanwhile, the company iPhone receives an SMS containing the OTP.
5. An **iOS Shortcut** on the iPhone forwards the raw SMS body to `POST /sms-received` with an `Authorization` header carrying `SMS_SECRET_TOKEN`.
6. The portal extracts the OTP via regex (`\b\d{4,8}\b`), stores it in Redis under `otp:pending:<TOKEN>` with a TTL of `OTP_DISPLAY_SEC` (default 285 s).
7. The user's browser polls the portal and receives the OTP for display.
8. The OTP is **never written to disk or logs** — it exists only in Redis memory with TTL expiry.

### Claim queue mechanics

- The queue is a Redis list (`otp:queue`). Claims expire after `CLAIM_EXPIRY_SEC` (default 90 s).
- A background task (`background_purge`) runs every 15 seconds to evict stale claims and expired OTP display windows.
- If two claims arrive within `CONCURRENT_RISK_SEC` (default 30 s), a `concurrent_risk` audit event is logged.
- Redis distributed locking (`otp:lock:queue`) prevents race conditions on claim operations.

### Admin sessions

- Admin tokens are configurable via the `admin_tokens` array in `admin_config.json` or the `ADMIN_TOKENS` env var.
- Sessions are stored in Redis with sliding TTL of 8 hours (`ADMIN_TTL_SECONDS`).
- Login brute-force protection: 8 attempts in 300 s window triggers a 900 s lockout (configurable).

---

## 6. Cluster Configuration

### Nodes

| Role | Hostname |
|------|----------|
| Control-plane | `debian` |
| Worker | `otp-worker-1` |
| Worker | `otp-worker-2` |

### Current live posture

```
Namespace:         otp-relay
Portal URL:        https://srvotptest26.init-db.lan
SERVICE_TYPE:      ClusterIP
INGRESS_ENABLED:   1
TLS_ENABLED:       1
TLS_HOST:          srvotptest26.init-db.lan
REPLICA_COUNT:     2
REDIS_REQUIRED:    1
REDIS_URL:         redis://otp-redis-haproxy:6379/0
NFS_ENABLED:       1
PVC_STORAGE_CLASS: otp-relay-nfs
strategy:          RollingUpdate (maxUnavailable=0, maxSurge=1)
```

### Pod placement (validated)

| Pod | Node |
|-----|------|
| `otp-redis-haproxy` | `otp-worker-1` |
| `otp-redis-haproxy` | `otp-worker-2` |
| `otp-redis-sentinel` | `debian` |
| `otp-redis-sentinel` | `otp-worker-1` |
| `otp-redis-sentinel` | `otp-worker-2` |
| `otp-relay` | `debian` |
| `otp-relay` | `otp-worker-1` |

Portal app placement is flexible — it has been validated across all nodes including control-plane cordon and pod recreation.

### Kubernetes services

| Service | Type | Purpose |
|---------|------|---------|
| `otp-relay` | ClusterIP | Portal app service (Ingress target) |
| `otp-redis` | ClusterIP | Redis access (may point to HAProxy) |
| `otp-redis-haproxy` | ClusterIP | Redis HAProxy frontend |
| `otp-redis-headless` | None (headless) | Redis StatefulSet pod discovery |
| `otp-redis-sentinel` | ClusterIP | Redis Sentinel service |

---

## 7. Deployment Guide

### Recommended path — GitHub Actions

```
git push origin main
  ──► GitHub Actions job triggers
  ──► Self-hosted runner checks out the repo
  ──► Installer syncs /opt/otp-relay-k8s to origin/main
  ──► Installer builds frontend app.js and help docs
  ──► Installer generates the Grafana dashboard ConfigMap
  ──► Installer builds/imports app and monitor images
  ──► Installer renders/applies Kubernetes manifests
  ──► Installer waits for rollouts
```

All deployment logic lives in `install-otp-relay-k8s.sh` and the manifests in `k8s/manifests/`. Do **not** duplicate deployment logic in the workflow YAML.

### Required GitHub Actions secrets

| Secret | Description |
|--------|-------------|
| `PHONE_IP` | IP address of the company iPhone |
| `PHONE_INTERFACE` | Network interface to the phone |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token for monitor alerts |
| `TELEGRAM_CHAT_ID` | Telegram chat ID for monitor alerts |
| `PORTAL_URL` | Public portal URL |

### Manual fallback

Clone or update the repo on the runner host:

```bash
git clone https://github.com/psi1703/k8s.git /opt/otp-relay-k8s
cd /opt/otp-relay-k8s
sudo ./install-otp-relay-k8s.sh
```

### Verify deployment

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard
sudo k3s kubectl -n observability get servicemonitor
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected health result:
```
OK: OTP Relay K3s deployment is healthy.
```

### Updating

```bash
git add .
git commit -m "Update OTP Relay Kubernetes deployment"
git push origin main
# Then let GitHub Actions run the deployment

# Manual verification after workflow:
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout status deployment/otp-monitor
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-haproxy
sudo k3s kubectl -n otp-relay get pods -o wide
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

### Files never to commit

```
.env
secret.env
Runtime tokens or Telegram credentials
users.xlsx (production copy)
admin_auth.json
admin_config.json
audit.log
*.tar
*.log
```

---

## 8. Environment Variables & Secrets

| Variable | Default | Description |
|----------|---------|-------------|
| `SMS_SECRET_TOKEN` | `changeme` | Bearer token for `/sms-received` |
| `SMTP_HOST` | `mail.company.local` | SMTP server (diagnostics only) |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USER` | `otp-relay@company.com` | SMTP user |
| `SMTP_PASSWORD` | _(empty)_ | SMTP password |
| `SMTP_USE_TLS` | `true` | Enable STARTTLS |
| `SMTP_AUTH` | `true` | Enable SMTP auth |
| `FROM_EMAIL` | _same as SMTP_USER_ | Sender email |
| `FROM_NAME` | `OTP Relay` | Sender display name |
| `CLAIM_EXPIRY_SEC` | `90` | Seconds before a claim is evicted |
| `OTP_DISPLAY_SEC` | `285` | Seconds the OTP stays visible |
| `CONCURRENT_RISK_SEC` | `30` | Window to flag concurrent claims |
| `USERS_EXCEL_PATH` | `data/users.xlsx` | Path to user store |
| `USERS_EXCEL_MAX_BYTES` | `5242880` (5 MB) | Max upload size |
| `AUDIT_LOG_PATH` | `data/audit.log` | Audit log path |
| `REDIS_URL` | _(empty)_ | Redis URL; empty = in-memory fallback |
| `REDIS_REQUIRED` | `0` | Set to `1` to make Redis mandatory |
| `OTP_RELAY_DATA_DIR` | `data` | Base data directory |
| `ADMIN_TOKENS` | `JPR,AMD,SCH` | Comma-separated admin token list |
| `ADMIN_LOGIN_WINDOW_SECONDS` | `300` | Brute-force detection window |
| `ADMIN_LOGIN_MAX_ATTEMPTS` | `8` | Attempts before lockout |
| `ADMIN_LOGIN_LOCKOUT_SECONDS` | `900` | Lockout duration |
| `WIZARD_CLIENT_SECRET_MIN_LENGTH` | `32` | Minimum wizard client secret length |

---

## 9. API Reference

### Health endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/healthz` | GET | Liveness check. Returns `{"status": "ok"}` |
| `/readyz` | GET | Readiness check. Returns Redis status, user count, and `redis_required` flag. Returns HTTP 503 if Redis required but unavailable. |

### User endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/user/login` | POST | Validate user token. Body: `{"token": "ABC"}`. Returns name, email, environment assignments. |
| `/claim` | POST | Enqueue the authenticated user to receive the next OTP. |
| `/otp-status` | GET | Poll for pending OTP. Returns OTP value, `expires_in` TTL, and queue position. |
| `/sms-received` | POST | Receive SMS forwarded from iOS Shortcut. Requires `Authorization: Bearer <SMS_SECRET_TOKEN>`. Extracts OTP and routes to the front-of-queue claim. |

### Admin endpoints (require `X-Admin-Session` header)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/admin/login` | POST | Authenticate with admin token. Returns session cookie. Rate-limited per IP. |
| `/admin/logout` | POST | Invalidate session. |
| `/admin/queue` | GET | List current OTP claim queue with expiry times. |
| `/admin/users` | GET | Return loaded user list. |
| `/admin/reload-users` | POST | Hot-reload `users.xlsx` without pod restart. |
| `/admin/upload-users` | POST | Upload a new `users.xlsx` (multipart, max 5 MB). |
| `/admin/audit` | GET | Return last N audit log entries (default 200, max 2000). |
| `/admin/smtp-test` | POST | Send a test email via SMTP (diagnostics only). |
| `/admin/config` | GET / POST | Read or update admin configuration (admin token list). |
| `/admin/wizard/*` | GET / POST | Manage per-user onboarding wizard progress. |

### Wizard state endpoints

Wizard progress is stored in `admin_config.json` on the shared PVC. Each user token owns a wizard record. A client secret (≥ 32 chars) is required to bind edits to a specific browser session.

---

## 10. Redis HA Model

Redis is **required** in the current validated posture (`REDIS_REQUIRED=1`).

```
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

### Components

| Component | Kind | Replicas | Purpose |
|-----------|------|---------|---------|
| `otp-redis` | StatefulSet | 3 | Redis data nodes (1 master, 2 replicas) |
| `otp-redis-sentinel` | Deployment | 3 (one per node) | Leader election & failover |
| `otp-redis-haproxy` | Deployment | 2 (workers only) | Routes traffic to current master |
| `otp-redis-headless` | Service (None) | — | StatefulSet pod DNS discovery |

The app connects only to HAProxy. HAProxy queries Sentinel to determine the current master and routes all Redis traffic accordingly. If the master fails, Sentinel promotes a replica and HAProxy re-routes automatically.

### Redis key schema

| Key pattern | TTL | Contents |
|-------------|-----|---------|
| `otp:queue` | — | Redis list of queued user tokens |
| `otp:lock:queue` | 10 s | Distributed lock for queue operations |
| `otp:claim:<TOKEN>` | — | Hash: token, name, email, claimed_at |
| `otp:pending:<TOKEN>` | `OTP_DISPLAY_SEC` | Hash: otp, arrived_at |
| `admin:session:<SESSION>` | `ADMIN_TTL_SECONDS` | Admin session timestamp |
| `admin:login_attempt:<IP>` | max(window, lockout) | Brute-force tracking |

### Useful Redis commands

```bash
# Check Redis pod and HAProxy placement
sudo k3s kubectl -n otp-relay get pods -o wide | grep -E 'redis|haproxy'

# Check Sentinel-reported master
SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
  -l app=otp-redis-sentinel -o jsonpath='{.items[0].metadata.name}')
sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# Tail Sentinel logs
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-sentinel --tail=100

# Tail HAProxy logs
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-haproxy --tail=100
```

---

## 11. NFS Shared Storage

Application state files that **must** survive pod restarts are stored on a shared NFS volume.

| Property | Value |
|----------|-------|
| PVC name | `otp-relay-data` |
| PV name | `otp-relay-data-nfs-pv` |
| Access mode | `ReadWriteMany` (RWX) |
| StorageClass | `otp-relay-nfs` |
| NFS server | `172.31.11.108` |
| NFS export path | `/export/otp-relay-data` |
| Container mount | `/app/data` |
| App UID/GID | `999:999` (user `otprelay`) |

### Files on the PVC

```
/app/data/
  users.xlsx            # User token store
  admin_auth.json       # Hashed admin credentials
  admin_config.json     # Admin token list & config
  wizard_progress.json  # Per-user onboarding wizard state
  audit.log             # Append-only audit log (JSON lines)
```

### NFS server permissions

```bash
sudo chown -R 999:999 /export/otp-relay-data
sudo chmod -R u+rwX,g+rwX /export/otp-relay-data
```

### Validate write access from both pods

```bash
sudo k3s kubectl -n otp-relay get pods -l app=otp-relay -o name | while read p; do
  echo "=== $p ==="
  sudo k3s kubectl -n otp-relay exec "${p#pod/}" -- sh -c '
    id
    touch /app/data/write-test &&
    rm -f /app/data/write-test &&
    echo WRITE_OK || echo WRITE_FAILED
  '
done
```

Expected output: `WRITE_OK` from both pods.

---

## 12. TLS & DNS

| Property | Value |
|----------|-------|
| Portal URL | `https://srvotptest26.init-db.lan` |
| Certificate | Self-signed (pending IT Group Policy trust rollout) |
| DNS resolution | Internal LAN DNS |

Because the certificate is self-signed, CLI validation uses `curl -k`:

```bash
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

**Production requirement:** IT distributes and trusts the internal CA certificate via Group Policy, or a CA-signed certificate is installed. Until then, browser users will see a certificate warning.

---

## 13. Monitor Service

The monitor pod is a required internal workload with elevated capabilities and no external exposure.

### Properties

| Property | Value |
|----------|-------|
| Image source | `k8s/Dockerfile.monitor` |
| `hostNetwork` | `true` |
| `dnsPolicy` | `ClusterFirstWithHostNet` |
| Capabilities | `NET_RAW` |
| Service | None |
| Ingress | None |
| Audit log access | Reads `/app/data/audit.log` |
| Alerting | Telegram for phone state changes (when configured) |

### Checks performed

- Phone presence on phone network (ping/ARP)
- Telegram alerting for `phone_online` / `phone_offline` events
- Shared audit log integrity
- Overall deployment health

### Run health check

```bash
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected:
```
OK: OTP Relay K3s deployment is healthy.
```

### Configure alerts

```bash
sudo nano /etc/otp-relay-k3s-monitor.env
```

If Telegram settings are incomplete, the monitor still reports health locally but may not send Telegram phone-state alerts.

---

## 14. Observability & Grafana Dashboard

The observability stack is deployed in the `observability` namespace and provides live operational visibility for the OTP Relay portal, monitor pod, Redis-related behavior, and iPhone presence.

### Components

| Component | Purpose |
|-----------|---------|
| Prometheus / kube-prometheus-stack | Scrapes portal, monitor, Kubernetes, and platform metrics |
| Grafana | Displays the OTP Relay live dashboard |
| ServiceMonitor `otp-relay` | Scrapes portal metrics |
| ServiceMonitor `otp-monitor` | Scrapes monitor metrics, including iPhone presence and ARP age |
| Loki | Stores logs |
| Alloy | Collects and forwards logs |
| Grafana dashboard ConfigMap | Provisions the OTP Relay live dashboard |

### Dashboard source and generated output

| Item | Path / value |
|------|--------------|
| Dashboard source | `k8s/observability/dashboards/otp-relay-live.json` |
| Generated ConfigMap | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` |
| ConfigMap name | `otp-relay-live-dashboard` |
| ConfigMap namespace | `observability` |
| ConfigMap data key | `otp-relay-live.json` |
| Dashboard UID | `otp-relay-live` |

The dashboard source may be a Grafana `dashboard.grafana.app/v2` export. The generator converts that source into classic Grafana dashboard JSON because the Grafana sidecar provisioning path expects classic dashboard JSON.

The generator must preserve:

- `id: null`
- `uid: otp-relay-live`
- `refresh: 15s`
- `timepicker.refresh_intervals`
- Stat panel type from `vizConfig.group`
- Grid layout and panel sizing from the dashboard source

### Regenerate the dashboard ConfigMap

Run this after editing `k8s/observability/dashboards/otp-relay-live.json`:

```bash
python3 scripts/generate_grafana_dashboard_configmap.py
```

Commit both files:

```bash
git add k8s/observability/dashboards/otp-relay-live.json \
        k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

### Validate generated dashboard JSON

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

The generated ConfigMap should include:

```json
"refresh": "15s"
```

and:

```json
"timepicker": {
  "refresh_intervals": [
    "5s",
    "10s",
    "15s"
  ]
}
```

### Apply dashboard changes manually

```bash
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
sudo k3s kubectl -n observability rollout status deployment/kube-prometheus-stack-grafana
```

### Live observability checks

```bash
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard
sudo k3s kubectl -n observability get servicemonitor
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

### Dashboard metrics

The OTP Relay live dashboard depends on these metrics:

| Metric | Meaning |
|--------|---------|
| `up{job="otp-relay"}` | Portal scrape status |
| `up{job="otp-monitor"}` | Monitor scrape status |
| `otp_iphone_present` | iPhone presence from monitor |
| `otp_monitor_arp_last_success_timestamp_seconds` | Timestamp of last successful ARP probe |
| `otp_queue_depth` | Waiting queue depth |
| `otp_active_user` | Whether an OTP user currently holds the active slot |
| `otp_delivered_total` | Delivered OTP counter |
| `otp_claims_total` | Claim counter |
| `otp_iphone_absence_events_total` | iPhone absence event counter |

---

## 15. Operations Runbook

### Daily health checks

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get pvc -n otp-relay
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard
sudo k3s kubectl -n observability get servicemonitor
sudo /usr/local/bin/otp-relayk3s-monitor.sh
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected state: all required pods Running/Ready, all PVCs Bound, monitor reports OK, both health endpoints return 200.

### Useful kubectl commands

```bash
# All resources in namespace
sudo k3s kubectl get all -n otp-relay

# Events (sorted)
sudo k3s kubectl get events -n otp-relay --sort-by=.lastTimestamp

# Persistent volumes
sudo k3s kubectl get pv

# Service endpoints
sudo k3s kubectl -n otp-relay get endpoints otp-relay -o wide
sudo k3s kubectl -n otp-relay get endpoints otp-redis-haproxy -o wide
sudo k3s kubectl -n otp-relay get endpoints otp-redis-sentinel -o wide
```

### Logs

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-relay --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=200
sudo k3s kubectl -n observability logs deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl -n observability logs deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

### Rollouts

```bash
# Status
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout status deployment/otp-monitor
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-haproxy

# Restart
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-monitor
```

### Pod failover (manual test)

```bash
# Delete one app pod and watch continuity
sudo k3s kubectl -n otp-relay delete pod <POD_NAME>
for i in $(seq 1 30); do
  curl -k -s -o /dev/null -w "%{http_code}\n" \
    https://srvotptest26.init-db.lan/readyz
  sleep 0.5
done
```

### Node cordon test

```bash
sudo k3s kubectl cordon debian
sudo k3s kubectl -n otp-relay delete pod -l app=otp-relay \
  --field-selector spec.nodeName=debian
# Test portal continuity with curl loop above
sudo k3s kubectl uncordon debian
sudo k3s kubectl -n otp-relay get pods -o wide
```

### Fix Redis Sentinel/HAProxy spread

If pods end up on the same node:

```bash
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-redis-haproxy
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-haproxy
sudo k3s kubectl -n otp-relay get pods -o wide | grep -E 'redis-sentinel|redis-haproxy|NAME'
```

> Do **not** delete multiple Sentinel pods simultaneously unless a maintenance window explicitly allows it.

---

## 16. Troubleshooting

### Portal readyz fails — SSL certificate error

**Symptom:**
```
curl: (60) SSL certificate problem: self-signed certificate
HTTP_CODE=000
```

**Cause:** Monitor or curl does not trust the self-signed certificate.

**Temporary fix:** Use `curl -k` for validation.

**Permanent fix:** Install a trusted certificate or distribute the internal CA through IT Group Policy.

---

### Wizard progress returns 500 PermissionError

**Symptom:**
```
PermissionError: [Errno 13] Permission denied: '/app/data/wizard_progress.json.tmp'
```

**Cause:** NFS export ownership does not match the app container UID/GID (999:999).

**Fix on NFS server:**
```bash
sudo chown -R 999:999 /export/otp-relay-data
sudo chmod -R u+rwX,g+rwX /export/otp-relay-data
```

Then validate write access (see Section 11).

---

### Redis StatefulSet not fully ready

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis -o wide
sudo k3s kubectl -n otp-relay describe pod otp-redis-<N>
sudo k3s kubectl -n otp-relay logs otp-redis-<N>
```

---

### Sentinel or HAProxy did not spread across nodes

```bash
# Inspect live affinity/topology rules
sudo k3s kubectl -n otp-relay get deployment otp-redis-haproxy -o yaml \
  | grep -A45 -E 'affinity:|topologySpreadConstraints:'
sudo k3s kubectl -n otp-relay get deployment otp-redis-sentinel -o yaml \
  | grep -A45 -E 'affinity:|topologySpreadConstraints:'

# Restart to re-schedule
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-redis-haproxy
```

---

### Grafana dashboard panels show as small graphs instead of big status tiles

**Symptom:** Portal, iPhone, Monitor, Prometheus, or other top dashboard panels render as mini time-series graphs instead of large Stat tiles.

**Cause:** The Grafana v2 dashboard converter did not preserve `vizConfig.group`, so `stat` panels were converted as `timeseries`.

**Fix:**
```bash
python3 scripts/generate_grafana_dashboard_configmap.py
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
```

Then verify the generated dashboard JSON contains `"type": "stat"` for the top panels.

---

### Grafana dashboard does not show 15s auto-refresh

**Symptom:** The generated ConfigMap contains `"refresh": "15s"`, but the Grafana UI does not show the 15s refresh interval.

**Cause:** The generated classic dashboard JSON is missing `timepicker.refresh_intervals`.

**Fix:**
```bash
python3 scripts/generate_grafana_dashboard_configmap.py
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
```

---

### Grafana tile text is cut off

**Symptom:** Words such as `ONLINE`, `RUNNING`, or `IN USE` are clipped in dashboard tiles.

**Cause:** Stat panel tile width/height is too small, or `text.valueSize` is too large.

**Fix:** Edit `k8s/observability/dashboards/otp-relay-live.json`, adjust the relevant `layout.spec.items[*].spec.width`, `height`, and panel `vizConfig.spec.options.text.valueSize`, then regenerate the ConfigMap.

---

### Wizard overlay image is broken but pop-out guide works

**Symptom:** A help image is visible in the pop-out guide but broken in the portal overlay.

**Cause:** The overlay renders generated help HTML inside a sandboxed `srcDoc` iframe. The pop-out guide renders the same HTML as a normal page. Embedded `/help/...` assets must resolve with the portal origin inside the iframe.

**Fix:** Edit `frontend/app.jsx`, rebuild `frontend/app.js`, and commit both files. Do not edit `frontend/app.js` directly as source.

---

### OTP not displaying in browser

1. Check that the iOS Shortcut is configured with the correct portal URL and `SMS_SECRET_TOKEN`.
2. Confirm the SMS was actually received by the iPhone.
3. Check Redis pending OTP key via Sentinel pod:
   ```bash
   SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
     -l app=otp-redis-sentinel -o jsonpath='{.items[0].metadata.name}')
   sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
     redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
   ```
4. Review audit log via `/admin/audit` or directly:
   ```bash
   tail -50 /app/data/audit.log
   ```

---

## 17. Development Guide

### Image builds

```bash
# App image
docker build -t otp-relay:latest -f k8s/Dockerfile .

# Monitor image
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

The app image contains:
- Python runtime + FastAPI/Uvicorn
- Python dependencies from `requirements.txt`
- Pre-built frontend (`frontend/app.js` compiled from `frontend/app.jsx`)
- Generated help pages (`frontend/help/` built from `docs/help/`)
- Static files from `frontend/`

The app starts via:
```
python -m uvicorn main:app
```

### Importing images into K3s (no registry)

```bash
docker save otp-relay:latest  -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

### Frontend build

The React source is at `frontend/app.jsx`. The installer compiles it to `frontend/app.js`.

> Do **not** use browser-side Babel (`text/babel`). The production model is a pre-built bundle.

> Do **not** edit `frontend/app.js` directly as source. Make changes in `frontend/app.jsx`, rebuild `frontend/app.js`, and commit both when the generated bundle changes.

### Help documentation build

```bash
# Source
docs/help/                  # Markdown files (00-overview.md … 11-notes-and-tips.md)
docs/help/assets/           # Screenshots

# Build
python scripts/build_help_docs.py

# Output
frontend/help/              # Generated HTML
```

Run this during deployment, not manually inside a running pod.

### Grafana dashboard build

```bash
# Source
k8s/observability/dashboards/otp-relay-live.json

# Build
python3 scripts/generate_grafana_dashboard_configmap.py

# Output
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

The generator converts Grafana `dashboard.grafana.app/v2` exports into classic Grafana dashboard JSON for sidecar provisioning. After generation, verify refresh and timepicker settings:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

### User management (`users.xlsx`)

Expected columns (row 1 = headers, case-insensitive):

| Column | Required | Notes |
|--------|----------|-------|
| `token` | Yes | 2–3 characters, letters and digits only |
| `name` | Yes | Display name |
| `email` | Yes | Must contain `@` |
| `test_env` | No | Test environment assignment |
| `prod_env` | No | Production environment assignment |

Tokens must be unique. Duplicate tokens and invalid rows are skipped and written to the audit log. Hot-reload without pod restart:

```bash
# Via API
curl -k -X POST \
  -H "X-Admin-Session: <SESSION>" \
  https://srvotptest26.init-db.lan/admin/reload-users
```

---

## 18. Validation Checklists

### Phase 3 baseline (all PASS)

| Check | Result |
|-------|--------|
| Health monitor | ✅ PASS |
| Portal 2 replicas running | ✅ PASS |
| Portal load balancing (traffic split) | ✅ PASS |
| Portal pod self-healing | ✅ PASS |
| Node-level portal failover | ✅ PASS |
| NFS `/app/data` shared write | ✅ PASS |
| Wizard progress endpoint | ✅ PASS |
| Redis StatefulSet 3/3 | ✅ PASS |
| Redis Sentinel 3/3 one-per-node | ✅ PASS |
| Redis HAProxy 2/2 spread across workers | ✅ PASS |

### Observability checklist

- [ ] `observability` namespace pods are Running/Ready
- [ ] `otp-relay-live-dashboard` ConfigMap exists
- [ ] Generated dashboard JSON contains `refresh: 15s`
- [ ] Generated dashboard JSON contains `timepicker.refresh_intervals`
- [ ] Portal, Monitor, Nodes, Prometheus, Queue, Active user, Delivered today, iPhone, and Last ARP panels render as Stat panels
- [ ] `otp_iphone_present` reports expected phone presence
- [ ] `otp_monitor_arp_last_success_timestamp_seconds` updates while phone is reachable
- [ ] Dashboard auto-refresh updates values without manual page refresh
- [ ] Grafana dashboard is provisioned from source and cannot be manually saved from UI

### OTP business-flow checklist

- [ ] Login page loads over HTTPS
- [ ] User token login works
- [ ] OTP claim flow works
- [ ] iPhone receives OTP by SMS
- [ ] iOS Shortcut posts SMS to `/sms-received`
- [ ] OTP appears on screen for the waiting user
- [ ] Audit log records the full flow
- [ ] Wizard progress endpoint returns 200 for authenticated users
- [ ] Pending OTP survives app pod restart while Redis is healthy
- [ ] Two-replica OTP flow works under load-balanced traffic
- [ ] Manager live OTP trigger test passes

### DNS/TLS client checklist

- [ ] `srvotptest26.init-db.lan` resolves from user machines
- [ ] HTTPS loads from user machines
- [ ] Certificate trust warning disappears after IT Group Policy rollout
- [ ] Portal works from the intended client network
- [ ] iPhone Shortcut target URL matches the final portal URL

### Worker-drain validation checklist (controlled window only)

Before drain, confirm:
```bash
sudo k3s kubectl get pods -n otp-relay -o wide
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

During drain, verify:
- [ ] App pod reschedules or remaining pod continues serving traffic
- [ ] Redis Sentinel remains healthy
- [ ] Redis HAProxy remains healthy
- [ ] Redis master remains available or fails over correctly
- [ ] NFS app storage remains mounted
- [ ] `/readyz` returns healthy after the cluster settles
- [ ] OTP flow still works after recovery

---

## 19. SCH Production Alignment

### Target architecture

```
Clients
  ──► Internal DNS
  ──► Approved LB/VIP layer
  ──► HTTPS ingress/controller
  ──► Kubernetes service
  ──► Multiple app pods across nodes
  ──► Shared Redis/Sentinel/HAProxy (or approved managed Redis)
  ──► Shared RWX/network persistent app storage

Monitor pod remains internal and unexposed.
```

### Current alignment status

| Area | SCH Target | Current Status |
|------|-----------|----------------|
| External access | DNS + approved ingress/LB | ✅ DNS and Traefik HTTPS ingress active |
| TLS | HTTPS trusted on user machines | ⏳ Self-signed; IT trust rollout pending |
| App replicas | Multiple pods | ✅ 2 replicas validated |
| App storage | Shared RWX/network storage | ✅ NFS RWX PVC validated |
| Redis | HA Redis/Sentinel/HAProxy or managed Redis | ✅ StatefulSet + Sentinel + HAProxy validated |
| Sentinel placement | Spread across nodes | ✅ One per node validated |
| HAProxy placement | Spread across nodes | ✅ 2 pods across workers validated |
| Failover | Pod and node-level validation | ✅ Both validated |
| Monitor | Internal only | ✅ No Service / no Ingress |
| Documentation | Clear active docs | ✅ README + observability source/generated workflow documented |

### Remaining production items

1. IT certificate trust rollout (Group Policy) for the self-signed/internal certificate.
2. Final SCH acceptance of Redis Sentinel/HAProxy vs a managed Redis service.
3. Redis backup/restore procedure definition.
4. Controlled Redis failover and worker-drain retest during a formal maintenance window.
5. Manager final business-flow OTP validation sign-off (if not already completed).

---

*This document was generated from the [psi1703/k8s](https://github.com/psi1703/k8s) repository — commit history, README, source files (`main.py`, `requirements.txt`), and inline code comments.*
