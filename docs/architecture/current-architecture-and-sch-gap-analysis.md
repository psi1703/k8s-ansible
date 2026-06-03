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

As of **2026-06-03**, Phase 3 resilience validation has completed with no detected blockers in the automated validation run.

Validated on 2026-06-03:

* two app replicas
* real SMS/OTP portal confirmation
* Redis/Sentinel/HAProxy health
* Redis master pod deletion recovery
* app pod restart recovery
* monitor pod restart recovery
* Redis HAProxy pod restart recovery
* Redis Sentinel pod restart recovery
* Grafana pod restart and dashboard persistence
* worker drain and uncordon recovery for `otp-worker1`
* worker drain and uncordon recovery for `otp-worker2`
* NFS/RWX app storage proof across app pods
* Prometheus/Grafana/Loki/Alloy observability recovery
* PDB presence
* CPU/memory requests and limits
* Kubernetes YAML and Helm template validation

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

During worker-drain maintenance, one Redis pod may temporarily remain `Pending` because of one-per-node Redis placement. This is acceptable only during the maintenance window when `/readyz`, Redis/Sentinel/HAProxy checks, and post-uncordon strict health checks pass.

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

Redis HA/Sentinel/HAProxy behavior was validated on **2026-06-03**, including Redis master pod deletion recovery and post-recovery strict health validation.

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

NFS/RWX app storage was validated on **2026-06-03** by writing a proof file from one app pod and reading it from another app pod.

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

Observability was validated on **2026-06-03**, including Prometheus API values, Grafana pod restart recovery, dashboard ConfigMap persistence, Loki recovery, Alloy presence, and final observability namespace readiness.

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

| Area            | SCH target                                                       | Current repo status / remaining work                                                                                                                        |
| --------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| External access | DNS plus approved ingress/LB/VIP path                            | Traefik HTTPS ingress active through internal DNS; final production VIP/LB model still needs SCH confirmation                                               |
| TLS             | HTTPS trusted on user machines                                   | Self-signed TLS enabled; IT Group Policy trust rollout or approved certificate installation pending                                                         |
| App replicas    | Multiple FastAPI app pods                                        | Two app replicas validated with real SMS/OTP portal confirmation on 2026-06-03                                                                              |
| App storage     | Shared RWX/network persistent storage                            | Implemented and validated as static NFS PV/PVC for `/app/data`                                                                                              |
| Redis           | HA Redis/Sentinel/Cluster or approved managed Redis              | Redis Sentinel/HAProxy topology implemented; failover and Redis master pod deletion recovery validated on 2026-06-03; production acceptance/backups pending |
| Redis updates   | Safe update behavior for StatefulSet/PVC resources               | Must preserve existing StatefulSet/PVC during normal updates; immutable-field changes require explicit maintenance handling                                 |
| Failover        | Pod kill, node drain, and app movement tests with state survival | App/monitor/HAProxy/Sentinel/Grafana pod restarts, Redis master deletion, and worker drain/uncordon recovery validated on 2026-06-03                        |
| Monitor         | Isolated monitor workload on phone-network-capable node          | Current no-Service/no-Ingress model is aligned                                                                                                              |
| Alerting        | Operational notifications                                        | Telegram alerting is the active documented path                                                                                                             |
| Observability   | Dashboard, metrics, and logs for production visibility           | Prometheus/Grafana/Loki/Alloy assets deployed and recovered after restart/drain validation                                                                  |
| Grafana access  | Stable internal access path                                      | `https://grafana.init-db.lan` through Traefik/IngressRoute                                                                                                  |
| Documentation   | Clear active docs with no conflicting legacy guidance            | README and docs describe source/generated workflows for frontend, help docs, and Grafana                                                                    |
| Workflow        | Repeatable CI/CD deployment                                      | GitHub Actions with self-hosted runner; installer remains deployment source of truth                                                                        |

---

## Validation position after 2026-06-03

The previous major uncertainty was whether the Redis/NFS/observability design could support real OTP flow, app replica recovery, Redis recovery, and worker drain recovery.

That uncertainty is now reduced by the **2026-06-03 automated validation run**.

Validated:

* real SMS/OTP evidence in audit log
* human confirmation that OTP was visible in the portal
* two app replicas
* Redis required and healthy
* Redis Sentinel and HAProxy functional checks
* Redis master pod deletion recovery
* app pod restart recovery
* monitor pod restart recovery
* Redis HAProxy pod restart recovery
* Redis Sentinel pod restart recovery
* Grafana pod restart recovery
* dashboard ConfigMap persistence
* worker drain and uncordon recovery for both workers
* final strict health pass
* final portal `/readyz` success
* final observability recovery
* final NFS/PVC proof across app pods

During active worker drains, temporary `Pending` pods were observed and accepted only inside the maintenance window. The post-uncordon strict health checks returned the cluster to full readiness.

---

## Remaining production-alignment gaps

1. Confirm final production LB/VIP model with SCH.
2. Complete TLS trust rollout through IT Group Policy or approved certificate trust process.
3. Document Redis backup/restore expectations.
4. Decide whether Redis Sentinel/HAProxy is accepted for production or replaced by an approved managed Redis service.
5. Confirm observability retention and access expectations for Grafana, Prometheus, Loki, and Alloy.
6. Confirm Telegram alerting path is fully aligned across monitor, installer, workflow, and docs.
7. Remove or intentionally archive any remaining WhatsApp-era alert references.
8. Optionally repeat the 2026-06-03 validation in a formal SCH-witnessed maintenance window.

---

## Implementation rule

Do not loosen safeguards just to make the architecture look complete.

The correct current position is:

```text
Phase 3 resilience validation completed on 2026-06-03 with no detected blockers.
Redis and NFS foundations are validated.
Redis HA/Sentinel/HAProxy failover is validated.
Normal Redis updates must not be destructive.
Two app replicas are validated with real SMS/OTP portal confirmation.
Worker drain and uncordon recovery are validated for otp-worker1 and otp-worker2.
Observability is source-driven: dashboard source JSON -> generated ConfigMap -> Grafana sidecar.
Frontend is source-driven: app.jsx -> generated app.js -> portal.
Runtime configuration is source-driven: .env -> rendered manifests/runtime configuration.
Monitor remains internal only: no Service, no Ingress.
Telegram is the supported monitor alerting path.
```

---

## Architecture sign-off checklist

* [x] `.env` is the only source of site/operator values.
* [x] Portal access works through `https://srvotptest26.init-db.lan`.
* [x] Grafana access works through `https://grafana.init-db.lan`.
* [x] Redis is required and healthy.
* [x] Redis HAProxy routes to the Sentinel-selected master.
* [x] Redis StatefulSet/PVC resources are not destructively recreated during normal updates.
* [x] App data is on NFS/RWX storage.
* [x] Monitor is internal only with no Service/Ingress.
* [x] Telegram alerting is the supported path.
* [x] Prometheus scrapes portal and monitor.
* [x] Grafana dashboard is provisioned from generated ConfigMap.
* [x] OTP business-flow validation passed on 2026-06-03.
* [x] Two-replica OTP validation passed on 2026-06-03.
* [x] Controlled worker-drain validation passed for both workers on 2026-06-03.
* [ ] TLS client trust is completed or explicitly tracked as pending.
* [ ] Redis backup/restore procedure is documented.
* [ ] SCH accepts Redis Sentinel/HAProxy or selects managed Redis.
* [ ] Final production LB/VIP model is confirmed with SCH if required.
