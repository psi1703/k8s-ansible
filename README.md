# OTP Relay Kubernetes

**Repository:** `psi1703/k8s-ansible`  
**Purpose:** deploy and operate OTP Relay on a local K3s Kubernetes cluster with Redis-backed runtime state, NFS-backed persistent files, Traefik ingress, MetalLB, and observability.

---

## 1. What this project does

OTP Relay is an internal LAN-only portal for controlled on-screen OTP delivery.

```text
iPhone receives OTP SMS
  -> iOS Shortcut posts SMS body to /sms-received
  -> FastAPI app receives the SMS
  -> Redis stores pending OTP state with TTL
  -> active browser claimant polls the portal
  -> OTP appears on screen
```

Only one user should be active for a given OTP flow. OTP SMS content does not identify the user, so the system uses a claim queue and active-user window to avoid misdelivery.

OTP values are runtime-only. They must not be written to disk, logs, manifests, automation output, or committed files.

---

## 2. Layered architecture

This repository is easier to understand as layers.

| Layer | Purpose | Main components |
|---|---|---|
| Layer 1: Application | OTP Relay portal and monitor | FastAPI app, React frontend, monitor pod |
| Layer 2: Kubernetes runtime | Run the app safely on K3s | namespace, deployments, services, ingress, PVCs |
| Layer 3: Shared state and storage | Allow multiple app pods and persistent non-OTP files | Redis, Redis Sentinel, Redis HAProxy, NFS RWX storage |
| Layer 4: Network access | Expose portal and observability inside the LAN | Traefik, MetalLB, internal DNS, TLS settings |
| Layer 5: Observability | Monitor health, metrics, logs, and dashboard state | Prometheus, Grafana, Loki, Alloy, ServiceMonitors |
| Layer 6: Automation | Install, update, validate, and synchronize repo state | setup scripts, Ansible roles, libvirt helpers, repo sync |
| Layer 7: Operations | Day-2 checks and recovery | health checks, install report, runbooks, validation scripts |

---

## 3. High-level flow

```text
User browser
  -> internal DNS / Traefik ingress
  -> otp-relay service
  -> FastAPI app pods
  -> Redis HAProxy
  -> Redis Sentinel-managed Redis master/replicas

Company iPhone
  -> receives OTP SMS
  -> iOS Shortcut posts to /sms-received
  -> app places pending OTP in Redis
  -> browser polling displays OTP to the active user

Monitor pod
  -> runs internally only
  -> uses hostNetwork and NET_RAW for phone presence checks
  -> reads audit events
  -> exposes Prometheus metrics
  -> sends Telegram alerts

Persistent non-OTP data
  -> /app/data
  -> NFS-backed RWX PVC
  -> users.xlsx, admin config, wizard state, audit log
```

---

## 4. Current expected production-style layout

A healthy current install should normally have:

```text
Kubernetes nodes:
  debian       control-plane
  otp-worker1 worker
  otp-worker2 worker

otp-relay namespace:
  otp-relay              2 app replicas on worker nodes
  otp-monitor            1 monitor pod on control-plane
  otp-redis              3 Redis pods spread across all nodes
  otp-redis-sentinel     3 Sentinel pods spread across nodes
  otp-redis-haproxy      2 HAProxy pods

observability namespace:
  kube-prometheus-stack
  Grafana
  Prometheus
  Alertmanager
  Loki
  Alloy
```

Redis is required for the current multi-replica app posture. The app should not be scaled beyond one replica without shared OTP state.

---

## 5. Access model

Portal access is controlled by `.env`:

```bash
TLS_HOST="srvotptest26.init-db.lan"
```

Expected portal URL when TLS is enabled:

```text
https://srvotptest26.init-db.lan
```

Grafana access is controlled by `.env`:

```bash
GRAFANA_HOST="grafana-srvotptest26.init-db.lan"
```

Expected Grafana URL:

```text
http://grafana-srvotptest26.init-db.lan
```

Normal production model:

```text
portal hostname  -> Traefik/MetalLB IP -> OTP Relay ingress
grafana hostname -> Traefik/MetalLB IP -> Grafana ingress
```

Production DNS for both OTP Relay and Grafana is provided externally and should remain the production access path.

Current DEV exception:

```text
OTP Relay -> normal hostname/Traefik path
Grafana   -> http://172.31.11.122 through a DEV-only grafana-direct LoadBalancer Service
```

The direct Grafana IP exists only because the DEV Windows client cannot use the test Grafana DNS name or a temporary hosts-file entry. It is a local testing workaround, not production architecture. Do not copy `172.31.11.122` or the DEV-only `grafana-direct` Service into production configuration.

Bare Traefik IP access may hit the default portal ingress instead of Grafana because Grafana production routing is hostname-based. See `docs/deployment/deployment-and-storage-guide.md` for the detailed DEV-versus-PROD access model.

---

## 6. Source-of-truth rules

| Area | Source | Generated output |
|---|---|---|
| Runtime configuration | `.env` | rendered manifests and runtime configuration |
| Frontend | `frontend/app.jsx` | `frontend/app.js` |
| Help docs | `docs/help/*.md`, `docs/help/assets/*` | `frontend/help/*` |
| Grafana dashboard | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` |

Do not edit generated files as source.

Common generation commands:

```bash
python3 scripts/build_help_docs.py
python3 scripts/build_grafana_dashboard_configmap.py
```

---

## 7. Repository structure

```text
k8s-ansible/
├── README.md
├── setup.sh                         # Main operator entry point
├── install-otp-relay-k8s.sh          # Installer/orchestration logic
├── main.py                           # FastAPI portal application
├── monitor.py                        # Phone monitor and alerting process
├── requirements.txt
├── frontend/
│   ├── index.html
│   ├── app.jsx                       # React source
│   ├── app.js                        # Generated production bundle
│   ├── guide.html
│   └── style.css
├── docs/
│   ├── README.md                     # Documentation index
│   ├── architecture/                 # System design and SCH alignment
│   ├── deployment/                   # Deployment and storage guides
│   ├── development/                  # Build and development guide
│   ├── operations/                   # Runbooks and validation
│   └── help/                         # Portal help source markdown
├── k8s/
│   ├── Dockerfile
│   ├── Dockerfile.monitor
│   ├── manifests/                    # App, Redis, storage, ingress manifests
│   └── observability/                # Prometheus, Grafana, Loki, Alloy assets
├── automation/
│   ├── ansible/                      # Cluster and app deployment roles
│   ├── libvirt/                      # Worker VM provisioning helpers
│   └── validation/                   # Optional validation scripts
├── scripts/
│   ├── lib/                          # Installer libraries
│   ├── sync-repo.sh                  # Local repo sync only; no deployment
│   ├── cluster-health-check.sh
│   ├── build_help_docs.py
│   └── build_grafana_dashboard_configmap.py
└── systemd/                          # Optional repo-sync timer units/docs
```

---

## 8. Normal operator workflow

### Sync repository only

```bash
cd /opt/k8s-ansible
bash scripts/sync-repo.sh
```

Repository sync may fetch GitHub and hard reset the local checkout to the configured branch while preserving runtime/generated files. It must not deploy the app, run Helm, apply Kubernetes manifests, install K3s, import images, or call the installer.

### Post-install or troubleshooting health check

```bash
cd /opt/k8s-ansible
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/cluster-health-check.sh
```

The health check validates the live Kubernetes stack, workload readiness, shared PVC/NFS state, Redis/Sentinel/HAProxy behavior, portal readiness, observability components, and repository syntax/rendering checks. It also compares `.env` `NFS_SERVER` with the live NFS-backed PV server values so configuration drift is reported explicitly.

### Normal install or update

```bash
cd /opt/k8s-ansible
bash setup.sh
```

Run as the operator user, not as `sudo bash setup.sh`. Scripts use `sudo` internally where required.

After install, read the handover report:

```bash
cat /opt/k8s-ansible/install-report.txt
```

---

## 9. Environment file model

`.env` is the single source of operator-provided deployment values.

Rules:

- A valid existing `.env` is reused.
- Normal update runs must not silently overwrite `.env`.
- Incomplete, cancelled, or syntactically broken `.env` files are rejected safely.
- Rejected files are backed up as `.env.rejected.<timestamp>` before recovery.
- Secrets must stay in `.env` or Kubernetes Secrets, not committed files.

Core examples:

```bash
NAMESPACE="otp-relay"

INGRESS_ENABLED="1"
TLS_ENABLED="1"
TLS_HOST="srvotptest26.init-db.lan"
TLS_SECRET_NAME="otp-relay-tls"
TLS_SELF_SIGNED="1"
TLS_ROTATE_SELF_SIGNED="0"

PVC_STORAGE_CLASS="otp-relay-nfs"
NFS_ENABLED="1"
NFS_SERVER="172.31.11.131"
NFS_PATH="/export/otp-relay-data"
NFS_STORAGE_CLASS="otp-relay-nfs"

REDIS_ENABLED="1"
REDIS_URL="redis://otp-redis-haproxy:6379/0"
REDIS_REQUIRED="1"
REDIS_STORAGE_CLASS="otp-redis-nfs"
REDIS_SIZE="1Gi"

OBSERVABILITY_NAMESPACE="observability"
OBSERVABILITY_INSTALL_STACK="1"
GRAFANA_HOST="grafana-srvotptest26.init-db.lan"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD=""
GRAFANA_ADMIN_SECRET_NAME="kube-prometheus-stack-grafana"
```

---

## 10. Documentation map

Read in this order:

| Need | Document |
|---|---|
| Documentation index | `docs/README.md` |
| Architecture overview | `docs/architecture/current-architecture-and-sch-gap-analysis.md` |
| Deployment and storage | `docs/deployment/deployment-and-storage-guide.md` |
| Operations and validation | `docs/operations/operations-and-validation-runbook.md` |
| Observability and Grafana | `docs/operations/observability-and-grafana.md` |
| Build and development | `docs/development/build-and-development-guide.md` |
| Portal help source | `docs/help/` |

Recommended documentation cleanup direction:

```text
README.md
  -> project overview, layers, normal workflow, doc map only

docs/README.md
  -> documentation index by audience and task

docs/architecture/
  -> architecture, SCH alignment, design decisions

docs/deployment/
  -> install, update, storage, network, TLS, Redis placement

docs/operations/
  -> runbooks, health checks, observability, resilience validation

docs/development/
  -> frontend build, help-doc generation, image build, generated files
```

---

## 11. Quick validation commands

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl -n kube-system get svc traefik -o wide
sudo k3s kubectl -n otp-relay get ingress -o wide
sudo k3s kubectl -n observability get ingress -o wide
```

Portal checks:

```bash
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Grafana Host-header check:

```bash
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Expected Grafana result:

```text
HTTP/1.1 302 Found
Location: /login
```

Cluster health check:

```bash
cd /opt/k8s-ansible
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/cluster-health-check.sh
```

---

## 12. Important operational rules

- OTP values must not be written to disk or logs.
- `.env` is the source of operator-provided deployment values.
- Normal updates must not silently overwrite `.env`.
- Repository sync must not directly deploy to the cluster.
- Redis is required for the current multi-replica app design.
- Redis requires three Redis-eligible nodes when three replicas and hard spreading are enabled.
- Normal updates must not destructively recreate Redis StatefulSet or Redis PVC resources.
- NFS must use a stable endpoint; the current environment uses static address `172.31.11.131`.
- Do not point NFS-backed PVs at a changing DHCP address.
- Changing `NFS_SERVER` in `.env` does not rewrite already-bound Kubernetes PVs; verify live PV `spec.nfs.server` values before changing the NFS endpoint.
- The monitor must remain internal only: no Service and no Ingress.
- Telegram is the active monitor alerting path.
- `frontend/app.jsx` is the frontend source; `frontend/app.js` is generated.
- Grafana dashboard source is JSON; the ConfigMap YAML is generated.
- Grafana admin credentials should be managed through `.env` and Kubernetes Secret, not committed files.
- The DEV-only `grafana-direct` LoadBalancer and `172.31.11.122` address must not be treated as production configuration; production Grafana access uses the IT-provided DNS name through Traefik Ingress.
- Self-signed TLS secrets are not rotated on normal installer reruns.
- Set `TLS_ROTATE_SELF_SIGNED=1` only when certificate replacement is intentional.

---

## 13. Files not to commit

```text
.env
.env.rejected.*
secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
install-report.txt
*.tar
*.tar.gz
*.tgz
*.zip
*.log
runtime tokens
Telegram credentials
SMS secrets
Grafana admin passwords
local kubeconfig files
private keys
```

---

## 14. Current alignment with SCH baseline

This repository keeps the same core OTP Relay behavior as the SCH Kubernetes baseline:

- FastAPI portal application.
- React frontend.
- iPhone Shortcut posting received SMS to `/sms-received`.
- Browser polling for OTP delivery.
- Persistent non-OTP runtime files under `/app/data`.
- Monitor pod for phone/audit alerting.
- Kubernetes deployment with ingress and service objects.

This repository intentionally extends the baseline with production-resilience layers:

- Redis-backed OTP queue and pending OTP state.
- Multiple app replicas.
- Redis Sentinel and HAProxy.
- NFS-backed RWX storage.
- MetalLB and Traefik ingress automation.
- Observability stack with Prometheus, Grafana, Loki, and Alloy.
- Local repository sync separated from deployment.

These extensions should remain clearly documented as layers so the project stays understandable and reviewable.
