# Current Architecture and SCH Gap Analysis

## Purpose

This document is the architecture reference for the OTP Relay Kubernetes deployment.

It owns:

* current architecture baseline
* node and infrastructure model
* runtime configuration model
* app, monitor, Redis, NFS, and observability architecture
* SCH target architecture
* current production-alignment gaps
* architectural sign-off gates

Detailed deployment and storage procedures belong in:

```text
docs/deployment/deployment-and-storage-guide.md
```

Detailed operations and validation commands belong in:

```text
docs/operations/operations-and-validation-runbook.md
```

Detailed Grafana, Prometheus, Loki, Alloy, dashboard generation, and PromQL guidance belongs in:

```text
docs/operations/observability-and-grafana.md
```

Detailed build, module layout, and source/generated artifact guidance belongs in:

```text
docs/development/build-and-development-guide.md
```

---

## Current architecture baseline

The current implementation is a Phase 3 SCH-alignment validation baseline.

```text
Clients / browsers / iPhone Shortcut
  -> DNS: srvotptest26.init-db.lan
  -> Traefik Ingress with HTTPS
  -> Kubernetes Service otp-relay
  -> FastAPI app pods
  -> Redis HAProxy service
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data storage
  -> Portal UI displays OTP

iPhone / fake-iPhone test source
  -> receives or simulates OTP/SMS path
  -> iOS Shortcut or test signal posts to the portal
  -> portal stores OTP state in Redis with TTL
  -> browser polling displays OTP to the active user

Monitor pod
  -> hostNetwork + NET_RAW
  -> phone presence checks
  -> exports Prometheus metrics
  -> reads shared audit log
  -> sends Telegram alerts
  -> no Service / no Ingress

Observability
  -> ServiceMonitor resources scrape portal and monitor
  -> Prometheus stores metrics
  -> Grafana dashboard is provisioned from ConfigMap
  -> Grafana is accessed through Traefik/IngressRoute
  -> Loki/Alloy handle log collection where deployed
```

Current validation posture:

```text
SERVICE_TYPE=ClusterIP
INGRESS_ENABLED=1
TLS_ENABLED=1
TLS_SELF_SIGNED=1
REDIS_ENABLED=1
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
NFS_ENABLED=1
PVC_STORAGE_CLASS=otp-relay-nfs
strategy: RollingUpdate
```

`REPLICA_COUNT` is controlled by `.env`.

Two app replicas are the intended HA posture, but final approval still depends on live OTP business-flow validation after the latest source/build/workflow changes.

---

## Node and infrastructure model

The current `k8s-ansible` deployment model uses:

| Role          | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| Control-plane | Real server / localhost K3s control-plane and Ansible runner |
| Worker 1      | VM worker node                                               |
| Worker 2      | VM worker node                                               |
| NFS server    | External storage server, not joined to Kubernetes            |

Important placement rules:

* VM provisioning creates worker VMs only.
* The real server is the K3s control-plane and Ansible runner.
* The NFS server remains external storage and should not be joined to Kubernetes.
* The monitor must run on a node with phone-network visibility.
* Redis-capable nodes are labelled for storage placement.

Known labels:

```text
otp-relay/storage-node=true
otp-relay/monitor-node=true
```

---

## Runtime configuration model

The repository root `.env` file is the single source of operator-provided deployment values.

Site-specific values should not be hardcoded in Python, shell scripts, Kubernetes YAML, Ansible tasks, or documentation examples.

Examples of `.env`-owned values:

```text
TLS_HOST
PORTAL_URL
SERVICE_TYPE
INGRESS_ENABLED
TLS_ENABLED
TLS_SECRET_NAME
TLS_SELF_SIGNED
PHONE_IP
PHONE_INTERFACE
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
SMS_SECRET_TOKEN
REDIS_ENABLED
REDIS_REQUIRED
REDIS_URL
NFS_ENABLED
NFS_SERVER
NFS_PATH
NFS_STORAGE_CLASS
PVC_STORAGE_CLASS
REPLICA_COUNT
```

Fresh installs should create `.env` interactively unless non-interactive mode is explicitly selected.

Updates should load the existing `.env` and must not overwrite it silently.

---

## Application model

The portal consists of:

* FastAPI backend served from app pods
* modular Python package under `otp_relay/`
* React frontend source/static assets served by the app
* generated production frontend bundle: `frontend/app.js`
* frontend source of truth: `frontend/app.jsx`
* on-screen OTP delivery through browser polling
* iPhone Shortcut posting received SMS content to `/sms-received`
* Redis-backed OTP queue and pending OTP state
* Redis-backed admin sessions and admin login-attempt tracking
* PVC-backed runtime files under `/app/data`
* generated RTA wizard/help content under `frontend/help/`
* required monitor pod for phone presence, audit-log, Prometheus metrics, and alert checks

Runtime app files under `/app/data`:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

OTP values must not be written to disk, audit logs, app logs, monitor logs, committed files, or documentation examples.

---

## Monitor model

The monitor is required and remains internal only.

Required Kubernetes posture:

```text
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
NET_RAW capability
no Service
no Ingress
```

The monitor provides:

* phone presence checks
* audit-log checks
* Prometheus metrics
* Telegram alerts

Telegram is the supported alerting path.

---

## Redis shared-state model

Redis is required in the validated Phase 3 posture.

The app uses:

```text
REDIS_URL=redis://otp-redis-haproxy:6379/0
REDIS_REQUIRED=1
```

The app connects to `otp-redis-haproxy`.

HAProxy routes Redis traffic to the current Redis master based on Sentinel state. Sentinel monitors Redis pods and performs master promotion when needed.

Redis currently supports:

* OTP claim queue
* pending OTP display state
* OTP TTL behavior
* admin sessions
* admin login-attempt and lockout state

This Redis foundation is why multiple app replicas can operate without the old in-memory split-brain OTP problem.

---

## Redis StatefulSet update safety

Redis is deployed as a StatefulSet, and Kubernetes makes some StatefulSet fields immutable after creation.

If a normal update attempts to change an immutable Redis StatefulSet field, Kubernetes may return:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

This must be handled safely.

Normal application, documentation, workflow, frontend, or observability updates must not:

* silently delete the Redis StatefulSet
* delete Redis PVCs
* recreate Redis as a side effect
* treat Redis data loss as acceptable

Safe architectural options are:

1. preserve the existing StatefulSet and continue with a clear warning,
2. fail clearly and require an explicit maintenance action, or
3. run a documented destructive Redis reset path only when intentionally requested.

Redis topology changes require controlled maintenance handling.

---

## Storage model

Application data uses NFS/RWX shared storage.

Validated storage path:

```text
PVC:           otp-relay-data
PV:            otp-relay-data-nfs-pv
Access mode:   ReadWriteMany
StorageClass:  otp-relay-nfs
NFS server:    172.31.11.108
NFS path:      /export/otp-relay-data
Mount path:    /app/data
```

Redis PVCs are separate from the app NFS storage. That is acceptable for validation, but Redis backup/restore expectations still need SCH production sign-off.

NFS stores non-OTP runtime files only.

---

## Observability model

Observability assets live under:

```text
k8s/observability/
```

Normal Grafana browser access:

```text
https://grafana.init-db.lan
```

Observability architecture:

```text
Portal /metrics
Monitor /metrics
  -> ServiceMonitor resources
  -> Prometheus
  -> Grafana dashboard provisioned from ConfigMap

Pod/application logs
  -> Alloy
  -> Loki
  -> Grafana log views where configured
```

The Grafana dashboard follows a source-generated model:

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
ConfigMap: otp-relay-live-dashboard
UID:       otp-relay-live
```

Dashboard implementation details and PromQL guidance belong in:

```text
docs/operations/observability-and-grafana.md
```

---

## Deployment workflow model

The normal deployment path is GitHub Actions with a self-hosted runner.

```text
GitHub workflow
  -> self-hosted runner
  -> installer script
  -> .env load/validation
  -> generated assets
  -> image build/import
  -> manifest render/apply
  -> rollout validation
```

Deployment logic should remain in:

```text
install-otp-relay-k8s.sh
scripts/lib/
k8s/manifests/
k8s/observability/
```

GitHub Actions workflow YAML should orchestrate deployment, not duplicate installer logic.

Dependency rule:

```text
requirements.txt affects both app and monitor images.
```

A `requirements.txt` change should trigger app and monitor rebuilds.

---

## SCH target architecture

SCH's production direction is:

```text
Clients
  -> internal DNS
  -> approved LB/VIP layer
  -> HTTPS ingress/controller
  -> Kubernetes service
  -> multiple app pods across worker/control-plane eligible nodes according to placement rules
  -> shared Redis/Sentinel/HAProxy or approved managed Redis
  -> shared RWX/network persistent app storage
  -> observability for health, metrics, logs, and dashboard visibility

Monitor pod remains internal and unexposed.
```

---

## Current vs target gap table

| Area            | SCH target                                                       | Current repo status / remaining work                                                                                               |
| --------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| External access | DNS plus approved ingress/LB/VIP path                            | Traefik HTTPS ingress active through internal DNS; final production VIP/LB model still needs SCH confirmation                      |
| TLS             | HTTPS trusted on user machines                                   | Self-signed TLS enabled; IT Group Policy trust rollout or approved certificate installation pending                                |
| App replicas    | Multiple FastAPI app pods                                        | Redis and NFS foundations are in place; final OTP business-flow sign-off still required after latest source/build/workflow changes |
| App storage     | Shared RWX/network persistent storage                            | Implemented and validated as static NFS PV/PVC for `/app/data`                                                                     |
| Redis           | HA Redis/Sentinel/Cluster or approved managed Redis              | Redis Sentinel/HAProxy topology implemented and failover validated; production acceptance/backups pending                          |
| Redis updates   | Safe update behavior for StatefulSet/PVC resources               | Must preserve existing StatefulSet/PVC during normal updates; immutable-field changes require explicit maintenance handling        |
| Failover        | Pod kill, node drain, and app movement tests with state survival | Redis failover validated; full worker-drain and final app-level OTP validation still pending                                       |
| Monitor         | Isolated monitor workload on phone-network-capable node          | Current no-Service/no-Ingress model is aligned                                                                                     |
| Alerting        | Operational notifications                                        | Telegram alerting is the active documented path                                                                                    |
| Observability   | Dashboard, metrics, and logs for production visibility           | Prometheus/Grafana/Loki/Alloy assets added; OTP Relay dashboard is provisioned from ConfigMap                                      |
| Grafana access  | Stable internal access path                                      | `https://grafana.init-db.lan` through Traefik/IngressRoute                                                                         |
| Documentation   | Clear active docs with no conflicting legacy guidance            | README and docs describe source/generated workflows for frontend, help docs, and Grafana                                           |
| Workflow        | Repeatable CI/CD deployment                                      | GitHub Actions with self-hosted runner; installer remains deployment source of truth                                               |

---

## Why app replica validation is still treated carefully

Redis and NFS remove the main architectural blockers for multi-replica validation, but the business-critical flow is OTP delivery.

Multiple app pods can be used only when the live OTP flow remains correct under load-balanced traffic.

Do not treat the architecture as production-signed until all of these pass:

* Manager live OTP trigger test
* Pending OTP restart-survival test
* Two-replica OTP claim/SMS/display flow validation
* DNS/TLS client validation from user machines
* Controlled worker-drain validation
* Grafana/Prometheus visibility confirms queue, active user, iPhone presence, and Last ARP behavior

---

## Remaining production-alignment gaps

1. Confirm final production LB/VIP model with SCH.
2. Complete TLS trust rollout through IT Group Policy or approved certificate trust process.
3. Validate app-level OTP behavior through restart and two-replica scenarios after the latest frontend/dashboard/workflow changes.
4. Document Redis backup/restore expectations.
5. Complete controlled worker-drain validation.
6. Decide whether Redis Sentinel/HAProxy is accepted for production or replaced by an approved managed Redis service.
7. Confirm observability retention and access expectations for Grafana, Prometheus, Loki, and Alloy.
8. Confirm normal update behavior preserves Redis StatefulSet/PVC resources.
9. Confirm Telegram alerting path is fully aligned across monitor, installer, workflow, and docs.
10. Remove or intentionally archive any remaining WhatsApp-era alert references.

---

## Implementation rule

Do not loosen safeguards just to make the architecture look complete.

The correct current position is:

```text
Redis and NFS foundations are validated.
Redis HA/Sentinel/HAProxy failover is validated.
Normal Redis updates must not be destructive.
The app can run with multiple replicas only after final OTP and node-drain validations pass.
Observability is source-driven: dashboard source JSON -> generated ConfigMap -> Grafana sidecar.
Frontend is source-driven: app.jsx -> generated app.js -> portal.
Runtime configuration is source-driven: .env -> rendered manifests/runtime configuration.
Monitor remains internal only: no Service, no Ingress.
Telegram is the supported monitor alerting path.
```

---

## Architecture sign-off checklist

* [ ] `.env` is the only source of site/operator values.
* [ ] Portal access works through `https://srvotptest26.init-db.lan`.
* [ ] Grafana access works through `https://grafana.init-db.lan`.
* [ ] Redis is required and healthy.
* [ ] Redis HAProxy routes to the Sentinel-selected master.
* [ ] Redis StatefulSet/PVC resources are not destructively recreated during normal updates.
* [ ] App data is on NFS/RWX storage.
* [ ] Monitor is internal only with no Service/Ingress.
* [ ] Telegram alerting works when configured.
* [ ] Prometheus scrapes portal and monitor.
* [ ] Grafana dashboard is provisioned from generated ConfigMap.
* [ ] OTP business-flow validation passes.
* [ ] Two-replica OTP validation passes.
* [ ] Controlled worker-drain validation passes or is explicitly tracked as pending.
* [ ] TLS client trust is completed or explicitly tracked as pending.
