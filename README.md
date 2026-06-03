# OTP Relay Kubernetes

**Repository:** [psi1703/k8s-ansible](https://github.com/psi1703/k8s-ansible)
**License:** MIT
**Status:** Phase 3 observability, workflow, and SCH-alignment hardening baseline

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
  -> FastAPI app pod
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

For detailed deployment, storage, Redis, and observability deployment guidance, see:

```text
docs/deployment/deployment-and-storage-guide.md
```

---

## Quick health check

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

For the full runbook, see:

```text
docs/operations/operations-and-validation-runbook.md
```

---

## Important operational rules

* `.env` is the source of operator-provided deployment values.
* Normal updates must not overwrite `.env` silently.
* Redis is required in the current Kubernetes validation posture.
* Normal updates must not destructively recreate Redis StatefulSet or Redis PVC resources.
* OTP values must not be written to disk or logs.
* The monitor must remain internal only: no Service and no Ingress.
* Telegram is the active monitor alerting path.
* `frontend/app.jsx` is the frontend source; `frontend/app.js` is generated.
* Grafana dashboard source is JSON; the ConfigMap YAML is generated.
* Multi-replica OTP and worker-drain status should remain conservative until validation is complete.

---

## Files not to commit

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

## Current production-alignment items

Remaining items are tracked in the architecture and operations docs, including:

* final manager OTP business-flow validation
* two-replica OTP validation after latest workflow/observability hardening
* controlled worker-drain validation
* TLS trust rollout or approved certificate installation
* Redis backup/restore expectations
* SCH decision on Redis Sentinel/HAProxy versus managed Redis
* final check that normal updates preserve Redis StatefulSet and PVC resources
