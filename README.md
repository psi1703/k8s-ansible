# OTP Relay Kubernetes

**Repository:** [psi1703/k8s-ansible](https://github.com/psi1703/k8s-ansible)  
**License:** MIT  
**Status:** Phase 3 resilience validation completed on 2026-06-03 with no detected blockers

---

## Overview

OTP Relay is an internal LAN-only One-Time Password relay portal deployed on Kubernetes using K3s.

It allows OTP values received on the company iPhone to be relayed to an authenticated browser user through the portal. OTP values are runtime-only and must not be written to disk, logs, manifests, GitHub Actions output, or committed files.

The deployment uses:

* K3s
* Traefik ingress
* FastAPI portal app
* React frontend
* Redis Sentinel and HAProxy
* NFS-backed RWX application storage
* monitor pod for phone presence and alerting
* Telegram alerts
* Prometheus, Grafana, Loki, and Alloy for observability
* GitHub Actions with a self-hosted runner

---

## Current access paths

Portal:

```text
https://srvotptest26.init-db.lan
```

Grafana:

```text
https://grafana.init-db.lan
```

Grafana should normally be accessed through Traefik/IngressRoute. Port-forwarding is only for temporary debugging.

---

## Current architecture summary

```text
Client browser
  -> internal DNS
  -> Traefik HTTPS ingress
  -> otp-relay Kubernetes service
  -> FastAPI app pods
  -> Redis HAProxy
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data for persistent non-OTP files

iPhone
  -> receives OTP SMS
  -> iOS Shortcut posts SMS body to /sms-received
  -> portal stores pending OTP state in Redis with TTL
  -> browser polling displays OTP to the active user

Monitor pod
  -> hostNetwork + NET_RAW
  -> phone presence checks
  -> audit-log checks
  -> Prometheus metrics
  -> Telegram alerts
  -> no Service
  -> no Ingress
```

For the full architecture and SCH gap analysis, see:

```text
docs/architecture/current-architecture-and-sch-gap-analysis.md
```

---

## Documentation

Detailed documentation lives under `docs/`.

Recommended reading order:

| Area                              | Document                                                                                                                           |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Documentation index               | [`docs/README.md`](docs/README.md)                                                                                                 |
| Architecture and SCH gap analysis | [`docs/architecture/current-architecture-and-sch-gap-analysis.md`](docs/architecture/current-architecture-and-sch-gap-analysis.md) |
| Deployment and storage            | [`docs/deployment/deployment-and-storage-guide.md`](docs/deployment/deployment-and-storage-guide.md)                               |
| Operations and validation         | [`docs/operations/operations-and-validation-runbook.md`](docs/operations/operations-and-validation-runbook.md)                     |
| Observability and Grafana         | [`docs/operations/observability-and-grafana.md`](docs/operations/observability-and-grafana.md)                                     |
| Build and development             | [`docs/development/build-and-development-guide.md`](docs/development/build-and-development-guide.md)                               |
| Portal help source                | [`docs/help/`](docs/help/)                                                                                                         |

---

## Source-of-truth rules

| Area                  | Source                                             | Generated output                                          |
| --------------------- | -------------------------------------------------- | --------------------------------------------------------- |
| Runtime configuration | `.env`                                             | rendered manifests and runtime configuration              |
| Frontend              | `frontend/app.jsx`                                 | `frontend/app.js`                                         |
| Help docs             | `docs/help/*.md`, `docs/help/assets/*`             | `frontend/help/*`                                         |
| Grafana dashboard     | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` |

Build/generation commands:

```bash
python3 scripts/build_help_docs.py
python3 scripts/build_grafana_dashboard_configmap.py
```

Do not edit generated files as source.

---

## First install flow

Before running a real install, run the non-mutating health check:

```bash
cd /opt/k8s-ansible
bash setup.sh --doctor
```

`--doctor` checks the repository layout, key script syntax, `.env` syntax and consistency, local K3s status, generated Ansible inventory, worker SSH reachability when inventory exists, NFS/TLS/Ingress placeholders, and required host commands.

It does **not** create `.env`, provision worker VMs, install K3s, run Ansible, apply manifests, or change system state.

Normal first install:

```bash
cd /opt/k8s-ansible
bash setup.sh
```

After a successful install, the installer writes an operator handover report:

```text
/opt/k8s-ansible/install-report.txt
```

Use that report for a concise view of the portal URL, Grafana URL, namespace, service/ingress/TLS state, NFS state, Redis state, pods, services, PVCs, and useful validation commands.

---

## Environment file behavior

`.env` is the single source of operator-provided deployment values.

Normal behavior:

* A valid existing `.env` is reused.
* Normal update runs must not silently overwrite `.env`.
* Incomplete, cancelled, or syntactically broken `.env` files are rejected safely.
* Rejected files are backed up as `.env.rejected.<timestamp>` before a clean `.env` is recreated.

Recommended pre-install check:

```bash
bash setup.sh --doctor
```

Useful recovery artifacts:

```text
.env.rejected.<timestamp>
install-report.txt
/var/backups/otp-relay-k8s/
```

---

## TLS and internal HTTPS behavior

The preferred internal access model is Traefik ingress with DNS pointing to the server/load-balancer address.

Important TLS settings:

```bash
TLS_ENABLED="1"
TLS_HOST="srvotptest26.init-db.lan"
TLS_SECRET_NAME="otp-relay-tls"
TLS_SELF_SIGNED="1"
TLS_ROTATE_SELF_SIGNED="0"
```

Behavior:

* `TLS_ENABLED=0` leaves the portal on HTTP ingress/service behavior.
* `TLS_ENABLED=1` enables HTTPS ingress configuration.
* `TLS_SELF_SIGNED=1` lets the installer create the Kubernetes TLS secret only when the secret is missing.
* Existing self-signed TLS secrets are preserved by default.
* `TLS_ROTATE_SELF_SIGNED=1` intentionally replaces the existing self-signed certificate.
* `TLS_SELF_SIGNED=0` requires the Kubernetes TLS secret to exist before the installer runs.

To export the self-signed certificate for IT Group Policy distribution:

```bash
sudo k3s kubectl get secret otp-relay-tls -n otp-relay -o jsonpath='{.data.tls\.crt}' | base64 -d > otp-relay.crt
```

Do not rotate the certificate after IT has trusted/distributed it unless the rotation is intentional.

---

## Deployment

Normal deployment is through GitHub Actions using the self-hosted runner.

The workflow should call:

```text
install-otp-relay-k8s.sh
```

Deployment logic belongs in the installer and repository scripts, not duplicated in workflow YAML.

Manual runner-host fallback:

```bash
cd /opt/k8s-ansible
sudo ./install-otp-relay-k8s.sh
```

For full first-install orchestration, including worker VM provisioning and Ansible cluster setup, use:

```bash
cd /opt/k8s-ansible
bash setup.sh
```

For detailed deployment, storage, Redis, and observability deployment guidance, see:

```text
docs/deployment/deployment-and-storage-guide.md
```

---

## Quick health check

Pre-install or troubleshooting health check:

```bash
cd /opt/k8s-ansible
bash setup.sh --doctor
```

Cluster and application health check:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get pods -n observability -o wide
sudo /usr/local/bin/otp-relayk3s-monitor.sh
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

```text
OK: OTP Relay K3s deployment is healthy.
```

Install report:

```bash
cat /opt/k8s-ansible/install-report.txt
```

For the full runbook, see:

```text
docs/operations/operations-and-validation-runbook.md
```

---

## Important operational rules

* `.env` is the source of operator-provided deployment values.
* Normal updates must not overwrite `.env` silently.
* Broken or incomplete `.env` files are backed up as `.env.rejected.<timestamp>` before recovery.
* Run `bash setup.sh --doctor` before first install or when troubleshooting setup state.
* Redis is required in the current Kubernetes validation posture.
* Normal updates must not destructively recreate Redis StatefulSet or Redis PVC resources.
* OTP values must not be written to disk or logs.
* The monitor must remain internal only: no Service and no Ingress.
* Telegram is the active monitor alerting path.
* `frontend/app.jsx` is the frontend source; `frontend/app.js` is generated.
* Grafana dashboard source is JSON; the ConfigMap YAML is generated.
* Self-signed TLS secrets are not rotated on normal installer reruns.
* Set `TLS_ROTATE_SELF_SIGNED=1` only when certificate replacement is intentional.
* Re-run validation after future changes to OTP flow, Redis state handling, frontend polling, Kubernetes placement, or deployment workflow behavior.

---

## Files not to commit

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
*.log
runtime tokens
Telegram credentials
SMS secrets
local kubeconfig files
```

---

## Current production-alignment items

Phase 3 resilience validation completed on **2026-06-03** with no detected blockers.

Validated:

* two app replicas
* real SMS/OTP portal confirmation
* Redis/Sentinel/HAProxy health
* Redis master pod deletion recovery
* app, monitor, HAProxy, Sentinel, and Grafana pod restart recovery
* worker drain and uncordon recovery for `otp-worker1` and `otp-worker2`
* NFS/RWX app storage proof across app pods
* Prometheus/Grafana/Loki/Alloy observability recovery

Remaining:

* IT certificate trust rollout or approved certificate installation
* SCH decision on Redis Sentinel/HAProxy versus managed Redis
* Redis backup/restore procedure
* final production LB/VIP decision if SCH requires more than current Traefik/internal DNS
