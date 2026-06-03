# OTP Relay Kubernetes — Project Documentation

**Repository:** [psi1703/k8s-ansible](https://github.com/psi1703/k8s-ansible)
**License:** MIT
**Status:** Phase 3 observability, workflow, and SCH-alignment hardening baseline

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Runtime Configuration Source of Truth](#4-runtime-configuration-source-of-truth)
5. [Technology Stack](#5-technology-stack)
6. [How OTP Relay Works](#6-how-otp-relay-works)
7. [Cluster Configuration](#7-cluster-configuration)
8. [Deployment Guide](#8-deployment-guide)
9. [Environment Variables and Secrets](#9-environment-variables-and-secrets)
10. [API Reference](#10-api-reference)
11. [Redis HA Model](#11-redis-ha-model)
12. [NFS Shared Storage](#12-nfs-shared-storage)
13. [TLS and DNS](#13-tls-and-dns)
14. [Monitor Service](#14-monitor-service)
15. [Observability and Grafana Dashboard](#15-observability-and-grafana-dashboard)
16. [Operations Runbook](#16-operations-runbook)
17. [Troubleshooting](#17-troubleshooting)
18. [Development Guide](#18-development-guide)
19. [Validation Checklists](#19-validation-checklists)
20. [SCH Production Alignment](#20-sch-production-alignment)

---

## 1. Project Overview

**OTP Relay** is an internal, LAN-only One-Time Password relay portal deployed on Kubernetes using K3s.

It bridges an iPhone SMS workflow and a browser-based portal so that OTP values received by the company iPhone can be displayed to the waiting authenticated user in the portal. The system avoids exposing an SMS gateway and avoids routing OTPs through email.

### Key characteristics

* Runs on the internal company network.
* Uses Kubernetes/K3s for app, monitor, Redis, and observability workloads.
* Uses Traefik ingress for browser access.
* Uses Redis for runtime OTP queue, pending OTP, and session state.
* Uses NFS-backed shared storage for persistent app files.
* Uses Telegram for monitor alerts.
* Uses Prometheus, Grafana, Loki, and Alloy for observability.
* Uses GitHub Actions with a self-hosted runner for deployment automation.
* Keeps site-specific runtime values in `.env`.
* Does not store OTP values on disk.

### Important security rule

OTP values must remain runtime-only.

They may be held in Redis with TTL expiry, but they must not be written to:

* `audit.log`
* application logs
* monitor logs
* Kubernetes manifests
* GitHub Actions logs
* documentation examples
* committed files

---

## 2. Architecture

### High-level traffic flow

```text
Client browser
  -> Internal DNS: ${TLS_HOST}
  -> Traefik HTTPS ingress
  -> Kubernetes Service: otp-relay
  -> FastAPI portal pod
  -> Redis HAProxy service
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS /app/data for persistent non-OTP files

iPhone
  -> Receives OTP SMS
  -> iOS Shortcut posts SMS body to /sms-received
  -> Portal extracts OTP
  -> Portal stores pending OTP in Redis with TTL
  -> Waiting browser polls /otp-status
  -> OTP appears for the active user

Monitor pod
  -> hostNetwork + NET_RAW
  -> Phone presence checks
  -> Audit-log health checks
  -> Prometheus metrics
  -> Telegram alerts
  -> No Service
  -> No Ingress
```

### Current topology

```text
                 Internal client network
                          |
                          v
                  https://${TLS_HOST}
                          |
                          v
                  Traefik HTTPS Ingress
                          |
                          v
                Service: otp-relay
                    Type: ClusterIP
                          |
             +------------+------------+
             |                         |
             v                         v
       otp-relay pod             otp-relay pod
       FastAPI app               FastAPI app
             |                         |
             +------------+------------+
                          |
                          v
              Service: otp-redis-haproxy
                          |
             +------------+------------+
             |                         |
             v                         v
       HAProxy pod               HAProxy pod
       worker placement          worker placement
             |                         |
             +------------+------------+
                          |
                          v
             Redis StatefulSet + Sentinel
                          |
                          v
                 NFS-backed /app/data
```

### Monitor isolation

The monitor pod is intentionally internal only.

It must not have:

* a Kubernetes Service
* an Ingress
* public exposure

It requires:

* `hostNetwork: true`
* `dnsPolicy: ClusterFirstWithHostNet`
* `NET_RAW`
* access to the shared audit log
* Telegram configuration when alerting is enabled

---

## 3. Repository Structure

```text
.
├── README.md
├── LICENSE
├── requirements.txt
├── package.json
├── package-lock.json
├── install-otp-relay-k8s.sh
├── monitor.py
│
├── otp_relay/
│   ├── routes.py
│   ├── config.py
│   ├── state.py
│   ├── storage.py
│   ├── users.py
│   ├── redis_state.py
│   ├── otp_flow.py
│   ├── admin.py
│   ├── audit.py
│   ├── metrics.py
│   └── frontend.py
│
├── otp_monitor/
│   ├── runner.py
│   ├── config.py
│   ├── phone.py
│   ├── alerts.py
│   ├── audit_tail.py
│   └── metrics.py
│
├── frontend/
│   ├── app.jsx
│   ├── app.js
│   ├── index.html
│   ├── style.css
│   ├── guide.html
│   └── help/
│
├── docs/
│   ├── README.md
│   ├── architecture/
│   ├── deployment/
│   ├── development/
│   ├── operations/
│   └── help/
│
├── scripts/
│   ├── build_help_docs.py
│   ├── build_grafana_dashboard_configmap.py
│   └── generate_sample_users.py
│
├── scripts/lib/
│   ├── env.sh
│   ├── preflight.sh
│   ├── repo-sync.sh
│   ├── build-stage.sh
│   ├── manifests.sh
│   ├── apply-deploy.sh
│   ├── summary.sh
│   ├── tls.sh
│   ├── metallb.sh
│   ├── docker.sh
│   ├── os.sh
│   └── github-runner.sh
│
├── k8s/
│   ├── Dockerfile
│   ├── Dockerfile.monitor
│   ├── manifests/
│   └── observability/
│       ├── dashboards/
│       │   └── otp-relay-live.json
│       ├── grafana-dashboard-otp-relay-live.yaml
│       ├── grafana-ingressroute.yaml
│       ├── prometheus-stack-values.yaml
│       ├── loki-values.yaml
│       ├── alloy-values.yaml
│       ├── servicemonitor-otp-relay.yaml
│       └── servicemonitor-otp-monitor.yaml
│
├── automation/
│   ├── ansible/
│   └── libvirt/
│
└── .github/
    └── workflows/
```

### Source-of-truth rules

| Area                       | Edit this                                          | Generated output                                          | Command or owner                                       |
| -------------------------- | -------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------ |
| Runtime/site configuration | `.env`                                             | rendered manifests and Ansible handoff                    | installer                                              |
| Frontend                   | `frontend/app.jsx`                                 | `frontend/app.js`                                         | installer/frontend build                               |
| Help docs                  | `docs/help/*.md`, `docs/help/assets/*`             | `frontend/help/*`                                         | `python3 scripts/build_help_docs.py`                   |
| Grafana dashboard          | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` | `python3 scripts/build_grafana_dashboard_configmap.py` |
| Kubernetes manifests       | `k8s/manifests/` plus rendered values from `.env`  | applied cluster resources                                 | installer                                              |
| Observability manifests    | `k8s/observability/`                               | applied observability resources                           | installer                                              |

### Files that must not be edited as source

Do not edit these as primary source unless the generated output itself is being committed after a proper build step:

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

### Files that must not be committed

```text
.env
secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
*.tar
*.log
runtime tokens
Telegram credentials
SMS secrets
local kubeconfig files
```

---

## 4. Runtime Configuration Source of Truth

The repository root `.env` file is the single source of operator-provided deployment values.

Fresh installs create `.env` interactively unless non-interactive mode is explicitly used. Updates load the existing `.env` automatically and must not overwrite it silently.

Site-specific values belong in `.env`, not hardcoded in Python, shell scripts, Kubernetes YAML, Ansible tasks, or documentation examples.

### Values that belong in `.env`

Examples include:

* portal host
* TLS host
* service type
* ingress enabled flag
* TLS enabled flag
* NFS server
* NFS export path
* storage class
* Redis URL
* Redis required flag
* replica count
* phone IP
* phone interface
* Telegram bot token
* Telegram chat ID
* SMS secret token
* MetalLB range
* node selectors
* observability toggles

### Change map

| Change needed                                                      | Edit here                                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Installer prompts, saved values, required variable validation      | `scripts/lib/env.sh`                                                           |
| Installer launcher flow                                            | `install-otp-relay-k8s.sh`                                                     |
| Host preflight, package install, K3s readiness                     | `scripts/lib/preflight.sh`                                                     |
| Repository sync and source-tree validation                         | `scripts/lib/repo-sync.sh`                                                     |
| Help docs, frontend build, and staging validation                  | `scripts/lib/build-stage.sh`                                                   |
| Kubernetes rendered ConfigMap, Service, Ingress, PVC, Redis values | `scripts/lib/manifests.sh`                                                     |
| Secret apply, image build/import, resource apply                   | `scripts/lib/apply-deploy.sh`                                                  |
| Final installer output                                             | `scripts/lib/summary.sh`                                                       |
| Portal app assembly and router registration                        | `otp_relay/routes.py`                                                          |
| Portal runtime configuration                                       | `otp_relay/config.py`                                                          |
| Shared in-memory fallback state                                    | `otp_relay/state.py`                                                           |
| JSON/PVC-backed admin and wizard files                             | `otp_relay/storage.py`                                                         |
| `users.xlsx` import and validation                                 | `otp_relay/users.py`                                                           |
| Redis queue, pending OTP, admin session store                      | `otp_relay/redis_state.py`                                                     |
| OTP claim, status, cancel, SMS receive flow                        | `otp_relay/otp_flow.py`                                                        |
| Admin auth, users, queue, wizard, diagnostics                      | `otp_relay/admin.py`                                                           |
| Audit log write/read behavior                                      | `otp_relay/audit.py`                                                           |
| Prometheus metrics                                                 | `otp_relay/metrics.py`                                                         |
| Static frontend mounting and `guide.html`                          | `otp_relay/frontend.py`                                                        |
| Monitor launcher flow                                              | `monitor.py`, `otp_monitor/runner.py`                                          |
| Monitor runtime configuration                                      | `otp_monitor/config.py`                                                        |
| iPhone ARP detection                                               | `otp_monitor/phone.py`                                                         |
| Telegram alerts                                                    | `otp_monitor/alerts.py`                                                        |
| Monitor audit-log tailing                                          | `otp_monitor/audit_tail.py`                                                    |
| Monitor Prometheus metrics                                         | `otp_monitor/metrics.py`                                                       |
| Ansible deployment handoff                                         | `.env`, consumed by `automation/ansible/roles/otp_relay_deploy/tasks/main.yml` |

---

## 5. Technology Stack

### Backend

| Component          | Technology                                |
| ------------------ | ----------------------------------------- |
| Portal API         | FastAPI + Python                          |
| ASGI server        | Uvicorn                                   |
| User store         | `openpyxl` reads `users.xlsx`             |
| Runtime state      | Redis                                     |
| Admin/auth hashing | `bcrypt`                                  |
| Configuration      | `.env` and runtime config module          |
| Help doc build     | `markdown`, `pyyaml`                      |
| Metrics            | Prometheus-compatible `/metrics` endpoint |

### Frontend

| Component     | Technology                                   |
| ------------- | -------------------------------------------- |
| UI            | React                                        |
| Source        | `frontend/app.jsx`                           |
| Served bundle | `frontend/app.js`                            |
| Styling       | `frontend/style.css`                         |
| Help pages    | generated static HTML under `frontend/help/` |

Browser-side Babel must not be used in production. The production model is a pre-built JavaScript bundle.

### Infrastructure

| Component       | Technology                                     |
| --------------- | ---------------------------------------------- |
| Kubernetes      | K3s                                            |
| Ingress         | Traefik                                        |
| Runtime images  | Built locally and imported into K3s/containerd |
| Storage         | NFS RWX PVC                                    |
| Redis HA        | Redis StatefulSet + Sentinel + HAProxy         |
| CI/CD           | GitHub Actions with self-hosted runner         |
| VM provisioning | Ansible/libvirt for worker VMs                 |

### Observability

| Component                     | Technology                                                |
| ----------------------------- | --------------------------------------------------------- |
| Metrics                       | Prometheus via kube-prometheus-stack                      |
| Dashboards                    | Grafana provisioned from ConfigMap                        |
| Logs                          | Loki                                                      |
| Log collector                 | Alloy                                                     |
| Scrape discovery              | ServiceMonitor resources                                  |
| Dashboard source              | `k8s/observability/dashboards/otp-relay-live.json`        |
| Dashboard generated ConfigMap | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` |

---

## 6. How OTP Relay Works

### OTP flow

1. A user opens the portal at `https://${TLS_HOST}`.
2. The user logs in with their assigned 2-3 character token.
3. The portal validates the token against `users.xlsx`.
4. The user claims the next OTP slot.
5. The claim is stored in Redis.
6. The company iPhone receives an OTP SMS.
7. An iOS Shortcut forwards the SMS body to `POST /sms-received`.
8. The request must include the configured `SMS_SECRET_TOKEN`.
9. The portal extracts the OTP using the configured OTP parsing logic.
10. The pending OTP is stored in Redis with TTL.
11. The waiting browser polls `/otp-status`.
12. The OTP is displayed to the active user.
13. The OTP expires automatically.

### Claim queue mechanics

* Queue state is stored in Redis.
* Claims expire after `CLAIM_EXPIRY_SEC`.
* Pending OTP display expires after `OTP_DISPLAY_SEC`.
* Concurrent claim risk is flagged when claims occur close together.
* Redis locking is used to prevent claim race conditions.
* Redis is required in the validated Kubernetes deployment posture.

### Admin sessions

* Admin session state is Redis-backed.
* Login attempt tracking is Redis-backed.
* Admin tokens are configurable through persisted config and/or environment.
* Admin actions are audited without storing OTP values.

---

## 7. Cluster Configuration

### Node model

| Role          | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| Control-plane | Real server / localhost K3s control-plane and Ansible runner |
| Worker 1      | VM worker node                                               |
| Worker 2      | VM worker node                                               |
| NFS server    | External storage server, not joined as a Kubernetes node     |

The real server is the K3s control-plane. VM provisioning should create worker VMs only. The external NFS server should not be joined to the Kubernetes cluster.

### Current intended posture

```text
Namespace:         otp-relay
Portal URL:        https://${TLS_HOST}
SERVICE_TYPE:      ClusterIP
INGRESS_ENABLED:   1
TLS_ENABLED:       1
TLS_HOST:          ${TLS_HOST}
REDIS_REQUIRED:    1
REDIS_URL:         redis://otp-redis-haproxy:6379/0
NFS_ENABLED:       1
PVC_STORAGE_CLASS: otp-relay-nfs
```

`REPLICA_COUNT` is controlled by `.env`. Two app replicas are the target HA posture, but live OTP business-flow validation must remain the acceptance gate before treating multi-replica as fully signed off.

### Kubernetes services

| Service              | Type      | Purpose                                |
| -------------------- | --------- | -------------------------------------- |
| `otp-relay`          | ClusterIP | Portal app service and ingress backend |
| `otp-redis`          | ClusterIP | Redis service name                     |
| `otp-redis-headless` | Headless  | Redis StatefulSet pod discovery        |
| `otp-redis-sentinel` | ClusterIP | Redis Sentinel service                 |
| `otp-redis-haproxy`  | ClusterIP | Redis HAProxy frontend                 |

### Workloads

| Workload             | Kind        | Purpose                                |
| -------------------- | ----------- | -------------------------------------- |
| `otp-relay`          | Deployment  | FastAPI portal                         |
| `otp-monitor`        | Deployment  | Phone/audit/alert monitor              |
| `otp-redis`          | StatefulSet | Redis data nodes                       |
| `otp-redis-sentinel` | Deployment  | Redis Sentinel quorum/failover         |
| `otp-redis-haproxy`  | Deployment  | Routes Redis traffic to current master |

---

## 8. Deployment Guide

### Recommended path: GitHub Actions

The normal deployment path is GitHub Actions using the self-hosted runner.

```text
GitHub change
  -> GitHub Actions workflow
  -> self-hosted runner
  -> repo checkout
  -> installer execution
  -> build/generate assets
  -> build/import images
  -> render/apply manifests
  -> wait for rollouts
  -> validation output
```

Deployment logic should remain in the installer and repository scripts. Workflow YAML should orchestrate the process, not duplicate installer behavior.

### Manual runner-host path

Use this only when intentionally running from the control-plane/runner host.

```bash
cd /opt/k8s-ansible
sudo ./install-otp-relay-k8s.sh
```

### Fresh install behavior

Fresh install should:

1. Check prerequisites.
2. Create `.env` interactively if missing.
3. Validate required `.env` values.
4. Install or verify K3s.
5. Build frontend/help/Grafana generated assets.
6. Build/import app and monitor images.
7. Render manifests from `.env`.
8. Apply Kubernetes resources.
9. Apply observability resources when enabled.
10. Wait for rollout status.
11. Print final summary and access URLs.

### Update behavior

Update should:

1. Reuse the existing `.env`.
2. Not overwrite `.env` silently.
3. Rebuild generated assets when needed.
4. Rebuild/import images when app, monitor, frontend, requirements, or Docker context changes require it.
5. Apply manifest changes safely.
6. Avoid destructive Redis/NFS changes unless explicitly requested.
7. Wait for relevant rollouts.

### Workflow change classification

General rule:

| Change type                      | Expected deployment behavior                                                      |
| -------------------------------- | --------------------------------------------------------------------------------- |
| `requirements.txt`               | Full app and monitor rebuild, because dependencies affect both runtime components |
| `otp_relay/**`                   | App image rebuild and app rollout                                                 |
| `otp_monitor/**` or `monitor.py` | Monitor image rebuild and monitor rollout                                         |
| `frontend/app.jsx`               | Frontend build, app image rebuild, app rollout                                    |
| `docs/help/**`                   | Help build, app image rebuild, app rollout                                        |
| `k8s/observability/**` only      | Observability manifest/dashboard apply where possible                             |
| `k8s/manifests/**`               | Manifest apply and relevant rollout                                               |
| `.github/workflows/**`           | Workflow behavior only unless paired with runtime changes                         |
| `scripts/lib/**`                 | Installer behavior; deployment impact depends on changed script                   |

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
curl -k https://${TLS_HOST}/healthz
curl -k https://${TLS_HOST}/readyz
```

Expected health result:

```text
OK: OTP Relay K3s deployment is healthy.
```

---

## 9. Environment Variables and Secrets

The exact `.env` keys may evolve with the installer. The following categories must remain operator-controlled and not hardcoded.

### Core portal

| Variable              | Purpose                               |
| --------------------- | ------------------------------------- |
| `TLS_HOST`            | Internal portal hostname              |
| `PORTAL_URL`          | Full portal URL                       |
| `SERVICE_TYPE`        | Kubernetes service type               |
| `INGRESS_ENABLED`     | Enables/disables ingress              |
| `TLS_ENABLED`         | Enables/disables TLS ingress behavior |
| `SMS_SECRET_TOKEN`    | Bearer token for `/sms-received`      |
| `REPLICA_COUNT`       | Portal replica count                  |
| `OTP_DISPLAY_SEC`     | OTP display TTL                       |
| `CLAIM_EXPIRY_SEC`    | Claim expiry TTL                      |
| `CONCURRENT_RISK_SEC` | Concurrent claim warning window       |

### Redis

| Variable         | Purpose                                          |
| ---------------- | ------------------------------------------------ |
| `REDIS_URL`      | Redis connection URL                             |
| `REDIS_REQUIRED` | Whether Redis is mandatory for readiness/runtime |

Current validated Redis URL:

```text
redis://otp-redis-haproxy:6379/0
```

### Storage

| Variable            | Purpose                          |
| ------------------- | -------------------------------- |
| `NFS_ENABLED`       | Enables NFS-backed storage       |
| `NFS_SERVER`        | NFS server IP/host               |
| `NFS_EXPORT_PATH`   | NFS export path                  |
| `PVC_STORAGE_CLASS` | StorageClass used by the app PVC |

### Monitor and alerting

| Variable             | Purpose                                      |
| -------------------- | -------------------------------------------- |
| `PHONE_IP`           | Company iPhone IP address                    |
| `PHONE_INTERFACE`    | Interface used for phone reachability checks |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token                           |
| `TELEGRAM_CHAT_ID`   | Telegram chat ID                             |

Telegram is the supported alerting path. Do not reintroduce WhatsApp alert configuration in new documentation or workflows unless the codebase intentionally restores that feature.

### SMTP diagnostics

SMTP settings may exist for diagnostics/admin testing. They are not part of the OTP delivery path.

---

## 10. API Reference

### Health endpoints

| Endpoint   | Method | Description                                           |
| ---------- | ------ | ----------------------------------------------------- |
| `/healthz` | GET    | Liveness check                                        |
| `/readyz`  | GET    | Readiness check, including Redis status when required |
| `/metrics` | GET    | Prometheus metrics                                    |

### User endpoints

| Endpoint        | Method | Description                           |
| --------------- | ------ | ------------------------------------- |
| `/user/login`   | POST   | Validate user token                   |
| `/claim`        | POST   | Claim the next OTP slot               |
| `/otp-status`   | GET    | Poll for pending OTP and queue status |
| `/sms-received` | POST   | Receive SMS body from iOS Shortcut    |
| `/cancel`       | POST   | Cancel current claim when supported   |

### Admin endpoints

Admin endpoints require an authenticated admin session.

| Endpoint              | Method   | Description                     |
| --------------------- | -------- | ------------------------------- |
| `/admin/login`        | POST     | Create admin session            |
| `/admin/logout`       | POST     | End admin session               |
| `/admin/queue`        | GET      | View current OTP queue          |
| `/admin/users`        | GET      | View loaded users               |
| `/admin/reload-users` | POST     | Reload `users.xlsx`             |
| `/admin/upload-users` | POST     | Upload replacement `users.xlsx` |
| `/admin/audit`        | GET      | Read audit events               |
| `/admin/config`       | GET/POST | Read/update admin configuration |
| `/admin/smtp-test`    | POST     | SMTP diagnostic test            |
| `/admin/wizard/*`     | GET/POST | Wizard state endpoints          |

---

## 11. Redis HA Model

Redis is required in the current Kubernetes HA posture.

```text
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

### Components

| Component            | Kind        | Purpose                                    |
| -------------------- | ----------- | ------------------------------------------ |
| `otp-redis`          | StatefulSet | Redis data nodes                           |
| `otp-redis-sentinel` | Deployment  | Sentinel quorum and failover               |
| `otp-redis-haproxy`  | Deployment  | Routes app traffic to current Redis master |
| `otp-redis-headless` | Service     | StatefulSet DNS discovery                  |

The app connects to Redis through HAProxy. HAProxy uses Sentinel to determine the active master.

### Redis key categories

| Key pattern             | Purpose                   |
| ----------------------- | ------------------------- |
| `otp:queue`             | Waiting claim queue       |
| `otp:lock:*`            | Redis locks               |
| `otp:claim:*`           | Active claim metadata     |
| `otp:pending:*`         | Pending OTP data with TTL |
| `admin:session:*`       | Admin sessions            |
| `admin:login_attempt:*` | Admin login protection    |

### StatefulSet immutability rule

Kubernetes StatefulSet fields are partly immutable after creation.

Normal installer or workflow updates must not blindly patch immutable fields of the existing Redis StatefulSet. If Redis StatefulSet immutable fields differ from the desired manifest, the safe behavior is one of:

1. preserve the existing StatefulSet and continue with a clear warning,
2. fail with a clear message explaining that an explicit Redis reset is required, or
3. perform deletion/recreation only in a documented destructive reset path.

Do not silently delete Redis StatefulSet or Redis PVCs during a normal update.

### Useful Redis checks

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis -o wide
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis-sentinel -o wide
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis-haproxy -o wide
```

Check Sentinel-reported master:

```bash
SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
  -l app=otp-redis-sentinel \
  -o jsonpath='{.items[0].metadata.name}')

sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

Tail logs:

```bash
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-haproxy --tail=100
```

---

## 12. NFS Shared Storage

Persistent non-OTP application files are stored on an NFS-backed RWX volume.

### PVC model

| Property        | Value                   |
| --------------- | ----------------------- |
| PVC name        | `otp-relay-data`        |
| PV name         | `otp-relay-data-nfs-pv` |
| Access mode     | `ReadWriteMany`         |
| StorageClass    | controlled by `.env`    |
| Container mount | `/app/data`             |

### Files on `/app/data`

```text
/app/data/
  users.xlsx
  admin_auth.json
  admin_config.json
  wizard_progress.json
  audit.log
```

OTP values must not be stored in these files.

### Permission requirement

The NFS export must allow the app container user to read and write the shared files.

Example server-side permission model:

```bash
sudo chown -R 999:999 /export/otp-relay-data
sudo chmod -R u+rwX,g+rwX /export/otp-relay-data
```

### Validate write access

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

Expected result:

```text
WRITE_OK
```

from each app pod.

---

## 13. TLS and DNS

The portal is intended to be accessed through an internal DNS name over HTTPS.

```text
https://${TLS_HOST}
```

### Current TLS model

The deployment may use an internal/self-signed certificate until IT distributes trust through the approved mechanism.

CLI checks should use `curl -k` when the certificate is not trusted by the client host:

```bash
curl -k https://${TLS_HOST}/healthz
curl -k https://${TLS_HOST}/readyz
```

### Production requirement

For production user access, the certificate must be trusted on client machines. This can be done by:

* installing a CA-signed certificate, or
* distributing the internal CA certificate through IT Group Policy or equivalent endpoint management.

---

## 14. Monitor Service

The monitor is a required internal workload.

### Properties

| Property      | Value                                  |
| ------------- | -------------------------------------- |
| Image source  | `k8s/Dockerfile.monitor`               |
| Entrypoint    | `monitor.py` / `otp_monitor/runner.py` |
| `hostNetwork` | `true`                                 |
| `dnsPolicy`   | `ClusterFirstWithHostNet`              |
| Capability    | `NET_RAW`                              |
| Service       | none                                   |
| Ingress       | none                                   |
| Alerting      | Telegram                               |
| Metrics       | `/metrics`                             |

### Checks performed

* phone presence checks
* ARP/ping-style network reachability checks
* audit log health checks
* monitor metrics export
* Telegram phone state alerts when configured

### Health check

```bash
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected:

```text
OK: OTP Relay K3s deployment is healthy.
```

### Alerting configuration

Telegram values are controlled through `.env` and rendered into the runtime configuration by the installer.

Do not store Telegram credentials in committed files.

---

## 15. Observability and Grafana Dashboard

The observability stack runs in the `observability` namespace.

### Components

| Component                          | Purpose                        |
| ---------------------------------- | ------------------------------ |
| Prometheus / kube-prometheus-stack | Metrics collection             |
| Grafana                            | Dashboard UI                   |
| ServiceMonitor `otp-relay`         | Scrapes portal metrics         |
| ServiceMonitor `otp-monitor`       | Scrapes monitor metrics        |
| Loki                               | Log storage                    |
| Alloy                              | Log collection                 |
| Grafana dashboard ConfigMap        | Provisions OTP Relay dashboard |

### Grafana access

Grafana should be accessed through Traefik/IngressRoute, not routine `kubectl port-forward`.

Current access pattern:

```text
https://grafana.init-db.lan
```

Port-forwarding may still be used for temporary debugging, but it should not be the documented normal access model.

### Dashboard source and generated output

| Item                | Path / value                                              |
| ------------------- | --------------------------------------------------------- |
| Dashboard source    | `k8s/observability/dashboards/otp-relay-live.json`        |
| Generated ConfigMap | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` |
| Generator script    | `scripts/build_grafana_dashboard_configmap.py`            |
| ConfigMap name      | `otp-relay-live-dashboard`                                |
| ConfigMap namespace | `observability`                                           |
| ConfigMap data key  | `otp-relay-live.json`                                     |
| Dashboard UID       | `otp-relay-live`                                          |

### Regenerate dashboard ConfigMap

After editing the dashboard source:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Commit both files:

```bash
git add k8s/observability/dashboards/otp-relay-live.json \
        k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

### Apply dashboard manually

```bash
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
sudo k3s kubectl -n observability rollout status deployment/kube-prometheus-stack-grafana
```

### Validate dashboard provisioning

```bash
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard
sudo k3s kubectl -n observability get configmap otp-relay-live-dashboard \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

### Dashboard metrics

| Metric                                           | Meaning                                   |
| ------------------------------------------------ | ----------------------------------------- |
| `up{job="otp-relay"}`                            | Portal scrape status                      |
| `up{job="otp-monitor"}`                          | Monitor scrape status                     |
| `otp_iphone_present`                             | iPhone presence signal                    |
| `otp_monitor_arp_last_success_timestamp_seconds` | Last successful phone probe timestamp     |
| `otp_queue_depth`                                | OTP waiting queue depth                   |
| `otp_active_user`                                | Whether an OTP user holds the active slot |
| `otp_delivered_total`                            | Delivered OTP counter                     |
| `otp_claims_total`                               | Claim counter                             |
| `otp_iphone_absence_events_total`                | iPhone absence event counter              |

### Replica-aware PromQL guidance

For counters in a multi-replica environment, prefer aggregate expressions.

Examples:

```promql
sum(increase(otp_delivered_total[$__range]))
```

```promql
sum(increase(otp_claims_total[$__range]))
```

For current-state gauges, use aggregate expressions that match the panel intent.

Examples:

```promql
max(otp_queue_depth)
```

```promql
max(otp_active_user)
```

```promql
max(otp_iphone_present)
```

---

## 16. Operations Runbook

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
curl -k https://${TLS_HOST}/healthz
curl -k https://${TLS_HOST}/readyz
```

Expected state:

* Kubernetes nodes are Ready.
* Required `otp-relay` pods are Running/Ready.
* Redis, Sentinel, and HAProxy are healthy.
* PVCs are Bound.
* Monitor reports OK.
* Health endpoints return HTTP 200.
* Grafana dashboard is provisioned.
* ServiceMonitor resources exist.

### Useful kubectl commands

```bash
sudo k3s kubectl get all -n otp-relay
sudo k3s kubectl get events -n otp-relay --sort-by=.lastTimestamp
sudo k3s kubectl get pv
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

### Rollout status

```bash
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout status deployment/otp-monitor
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-sentinel
sudo k3s kubectl -n otp-relay rollout status deployment/otp-redis-haproxy
```

### Restart app or monitor

```bash
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
```

```bash
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-monitor
sudo k3s kubectl -n otp-relay rollout status deployment/otp-monitor
```

### Pod self-healing test

```bash
sudo k3s kubectl -n otp-relay get pods -l app=otp-relay -o wide
sudo k3s kubectl -n otp-relay delete pod <POD_NAME>
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
curl -k https://${TLS_HOST}/readyz
```

### Controlled node cordon test

Use only during a maintenance/testing window.

```bash
sudo k3s kubectl cordon <NODE_NAME>
sudo k3s kubectl -n otp-relay get pods -o wide
```

After testing:

```bash
sudo k3s kubectl uncordon <NODE_NAME>
sudo k3s kubectl get nodes -o wide
```

Do not drain worker nodes running Redis components without a controlled validation plan.

---

## 17. Troubleshooting

### Redis StatefulSet immutable field error

Symptom:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

Cause:

Kubernetes does not allow normal patch/apply updates to certain StatefulSet fields after creation.

Correct response:

* Do not treat this as a normal rollout failure.
* Do not delete Redis PVCs during a normal update.
* Preserve the existing StatefulSet or fail clearly.
* Use an explicit destructive Redis reset path only when data loss/recreation is accepted.

Check live StatefulSet:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
```

### Portal readyz fails because Redis is unavailable

Check readiness:

```bash
curl -k https://${TLS_HOST}/readyz
```

Check Redis components:

```bash
sudo k3s kubectl -n otp-relay get pods -o wide | grep -E 'redis|haproxy'
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-haproxy --tail=100
```

When `REDIS_REQUIRED=1`, `/readyz` should fail if Redis is unavailable.

### Portal readyz fails due to certificate trust

Symptom:

```text
curl: (60) SSL certificate problem: self-signed certificate
```

Temporary CLI validation:

```bash
curl -k https://${TLS_HOST}/readyz
```

Permanent fix:

Install a trusted certificate or distribute the internal CA certificate to client machines.

### Wizard progress permission error

Symptom:

```text
PermissionError: [Errno 13] Permission denied: '/app/data/wizard_progress.json.tmp'
```

Cause:

NFS export permissions do not allow the app container user to write.

Fix on NFS server:

```bash
sudo chown -R 999:999 /export/otp-relay-data
sudo chmod -R u+rwX,g+rwX /export/otp-relay-data
```

Then validate pod write access.

### Grafana dashboard panels show as graphs instead of Stat tiles

Cause:

Dashboard conversion did not preserve the intended panel visualization.

Fix:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
sudo k3s kubectl -n observability rollout status deployment/kube-prometheus-stack-grafana
```

### Grafana dashboard auto-refresh is missing

Check generated dashboard:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Regenerate if needed:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

### Grafana tile text is cut off

Fix the source dashboard:

```text
k8s/observability/dashboards/otp-relay-live.json
```

Then regenerate:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

### OTP does not display in browser

Check:

1. User successfully logged in.
2. User claimed the OTP slot.
3. iPhone received the SMS.
4. iOS Shortcut posted to the correct portal URL.
5. `SMS_SECRET_TOKEN` matches `.env`.
6. Redis is healthy.
7. `/readyz` returns healthy.
8. Audit events show claim/SMS flow without exposing OTP value.

Useful commands:

```bash
curl -k https://${TLS_HOST}/readyz
sudo k3s kubectl -n otp-relay logs deployment/otp-relay --tail=200
sudo k3s kubectl -n otp-relay get pods -o wide
```

### OTP Log UI blanks or fails

Audit log reading must tolerate malformed, corrupt, or NUL-containing lines. A bad audit line should not blank the OTP Log UI.

Check app logs:

```bash
sudo k3s kubectl -n otp-relay logs deployment/otp-relay --tail=200
```

Check audit file health from the NFS-backed data path if direct server access is available.

---

## 18. Development Guide

### App image build

```bash
docker build -t otp-relay:latest -f k8s/Dockerfile .
```

### Monitor image build

```bash
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

### Import images into K3s

```bash
docker save otp-relay:latest -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

### Frontend build

Source:

```text
frontend/app.jsx
```

Generated served bundle:

```text
frontend/app.js
```

Rules:

* Edit `frontend/app.jsx`.
* Rebuild `frontend/app.js`.
* Commit both when frontend behavior changes.
* Do not use browser-side Babel.
* Do not treat `frontend/app.js` as the source of truth.

### Help documentation build

Source:

```text
docs/help/
docs/help/assets/
```

Build:

```bash
python3 scripts/build_help_docs.py
```

Output:

```text
frontend/help/
```

### Grafana dashboard build

Source:

```text
k8s/observability/dashboards/otp-relay-live.json
```

Build:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Output:

```text
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Verify:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

### User file format

`users.xlsx` must include row-1 headers.

Expected columns:

| Column     | Required | Notes                             |
| ---------- | -------- | --------------------------------- |
| `token`    | yes      | 2-3 character token               |
| `name`     | yes      | display name                      |
| `email`    | yes      | must contain `@`                  |
| `test_env` | no       | test environment assignment       |
| `prod_env` | no       | production environment assignment |

Duplicate or invalid rows should be skipped and audited without breaking the full import.

### Dependency changes

Changes to `requirements.txt` should be treated as affecting both app and monitor runtime images unless proven otherwise. The workflow should avoid classifying dependency changes as a manifest-only update.

---

## 19. Validation Checklists

### Core cluster checklist

* [ ] K3s node list is healthy.
* [ ] Control-plane is Ready.
* [ ] Worker nodes are Ready.
* [ ] `otp-relay` namespace exists.
* [ ] `observability` namespace exists when observability is enabled.
* [ ] App PVC is Bound.
* [ ] NFS write test passes from app pod.
* [ ] Portal `/healthz` returns 200.
* [ ] Portal `/readyz` returns 200 when Redis is healthy.
* [ ] Monitor health script reports OK.

### Redis checklist

* [ ] Redis StatefulSet pods are Running/Ready.
* [ ] Sentinel pods are Running/Ready.
* [ ] HAProxy pods are Running/Ready.
* [ ] App connects through `otp-redis-haproxy`.
* [ ] Sentinel reports a current master.
* [ ] Redis failure behavior is tested only in a controlled maintenance window.
* [ ] Normal installer update does not destructively recreate Redis.

### Observability checklist

* [ ] `observability` namespace pods are Running/Ready.
* [ ] Grafana loads at `https://grafana.init-db.lan`.
* [ ] `otp-relay-live-dashboard` ConfigMap exists.
* [ ] Dashboard source JSON exists.
* [ ] Generated dashboard ConfigMap exists.
* [ ] Generated dashboard contains `refresh: 15s`.
* [ ] Generated dashboard contains `timepicker.refresh_intervals`.
* [ ] ServiceMonitor resources exist for portal and monitor.
* [ ] Portal scrape status works.
* [ ] Monitor scrape status works.
* [ ] Queue depth panel works.
* [ ] Active user panel works.
* [ ] Delivered today panel uses replica-aware counter aggregation.
* [ ] iPhone presence panel works.
* [ ] Last ARP panel shows a sensible recent value when phone is reachable.
* [ ] Dashboard survives Grafana pod restart.

### OTP business-flow checklist

* [ ] Login page loads over HTTPS.
* [ ] User token login works.
* [ ] User can claim OTP slot.
* [ ] iPhone receives OTP SMS.
* [ ] iOS Shortcut posts SMS to `/sms-received`.
* [ ] OTP appears for waiting user.
* [ ] OTP expires after TTL.
* [ ] OTP value is not written to disk.
* [ ] Audit log records non-sensitive flow events.
* [ ] Pending OTP survives app pod restart while Redis is healthy.
* [ ] Two-replica OTP flow works under load-balanced traffic.
* [ ] Manager live OTP trigger test passes.

### DNS/TLS checklist

* [ ] `${TLS_HOST}` resolves from intended client machines.
* [ ] HTTPS loads from intended client machines.
* [ ] Certificate trust warning is resolved after IT certificate rollout.
* [ ] iPhone Shortcut target URL matches the final portal URL.

### Worker-drain checklist

Use only during a controlled maintenance/testing window.

Before drain:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide
curl -k https://${TLS_HOST}/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Validate:

* [ ] App remains available or recovers correctly.
* [ ] Redis Sentinel quorum remains healthy.
* [ ] Redis HAProxy remains healthy.
* [ ] Redis master remains available or fails over correctly.
* [ ] NFS app storage remains mounted.
* [ ] `/readyz` returns healthy after recovery.
* [ ] OTP business flow works after recovery.

---

## 20. SCH Production Alignment

### Target architecture

```text
Clients
  -> Internal DNS
  -> Approved ingress/LB layer
  -> HTTPS ingress/controller
  -> Kubernetes service
  -> Multiple app pods across nodes
  -> Redis HA or approved managed Redis
  -> Shared RWX/network persistent app storage

Monitor remains internal and unexposed.
```

### Current alignment status

| Area            | SCH target                         | Current status                                                                     |
| --------------- | ---------------------------------- | ---------------------------------------------------------------------------------- |
| External access | DNS + approved ingress/LB          | Traefik HTTPS ingress model active                                                 |
| TLS             | Trusted HTTPS on user machines     | Internal/self-signed trust rollout may still be required                           |
| App replicas    | Multiple app pods                  | Target model supported; final OTP business-flow validation remains acceptance gate |
| App storage     | Shared RWX/network storage         | NFS RWX PVC model                                                                  |
| Redis           | HA Redis or approved managed Redis | Redis StatefulSet + Sentinel + HAProxy                                             |
| Monitor         | Internal only                      | No Service / no Ingress                                                            |
| Alerting        | Operational notifications          | Telegram-based monitor alerts                                                      |
| Observability   | Metrics/logs/dashboard             | Prometheus, Grafana, Loki, Alloy                                                   |
| Documentation   | Clear active docs                  | Root README plus `docs/` structure                                                 |
| Workflow        | Repeatable deployment              | GitHub Actions + self-hosted runner + installer                                    |

### Remaining production items

1. Final manager OTP business-flow validation.
2. Two-replica OTP flow validation after the latest workflow/observability hardening.
3. Controlled Redis failover validation.
4. Controlled worker-drain validation.
5. IT certificate trust rollout or approved trusted certificate.
6. SCH acceptance of Redis Sentinel/HAProxy versus managed Redis.
7. Redis backup/restore procedure definition.
8. Final review that no WhatsApp-era alerting references remain in active docs/workflows unless intentionally retained for history.
9. Final verification that normal updates do not destructively recreate Redis StatefulSet or PVC resources.

---

## Active Documentation

Additional detailed documentation lives under `docs/`.

Recommended reading order:

```text
docs/README.md
docs/architecture/current-architecture-and-sch-gap-analysis.md
docs/deployment/deployment-and-storage-guide.md
docs/operations/operations-and-validation-runbook.md
docs/operations/observability-and-grafana.md
docs/development/build-and-development-guide.md
```

Portal user-help source lives under:

```text
docs/help/
```

Generated portal help output lives under:

```text
frontend/help/
```

Do not restore legacy documentation paths unless the project intentionally reintroduces them.
