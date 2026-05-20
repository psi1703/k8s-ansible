# Current Architecture and SCH Gap Analysis

## Purpose

This document is the single architecture reference for the OTP Relay Kubernetes deployment. It combines the previous architecture plan and SCH target/current gap document into one compact source of truth.

## Current validated baseline

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
  -> phone presence and SMS-path checks
  -> exports Prometheus metrics
  -> reads shared audit log
  -> sends Telegram alerts
  -> no Service / no Ingress

Observability
  -> ServiceMonitor resources scrape portal and monitor
  -> Prometheus stores metrics
  -> Grafana dashboard is provisioned from ConfigMap
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
REPLICA_COUNT=2
strategy: RollingUpdate
```

## Current application model

The portal consists of:

- FastAPI backend served from the app pods.
- React frontend source/static assets served by the app.
- Generated production frontend bundle: `frontend/app.js`.
- Frontend source of truth: `frontend/app.jsx`.
- On-screen OTP delivery through browser polling.
- iPhone Shortcut posting received SMS content to `/sms-received`.
- Redis-backed OTP queue and pending OTP state.
- Redis-backed admin sessions and admin login-attempt tracking.
- PVC-backed runtime files under `/app/data`.
- Generated RTA wizard/help content under `frontend/help/`.
- Required monitor pod for phone presence, SMS-path, audit-log, Prometheus metrics, and alert checks.

Runtime app files under `/app/data`:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

## Redis shared-state model

Redis is required in the validated Phase 3 posture.

The app uses:

```text
REDIS_URL=redis://otp-redis-haproxy:6379/0
REDIS_REQUIRED=1
```

The app connects to `otp-redis-haproxy`. HAProxy routes Redis traffic to the current Redis master based on Sentinel state. Sentinel monitors Redis pods and performs master promotion when needed.

Redis currently supports:

- OTP claim queue.
- Pending OTP display state.
- OTP TTL behavior.
- Admin sessions.
- Admin login-attempt and lockout state.

This Redis foundation is why multiple app replicas can operate without the old in-memory split-brain OTP problem.

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

## Frontend and help-doc model

The portal frontend follows a source/generated model:

```text
Source:    frontend/app.jsx
Generated: frontend/app.js
Served by: frontend/index.html
```

Rules:

- Make frontend behavior changes in `frontend/app.jsx`.
- Rebuild `frontend/app.js`.
- Commit both files when the generated bundle changes.
- Do not restore browser Babel or `text/babel`.

Help documentation also follows a source/generated model:

```text
Source:    docs/help/*.md
Assets:    docs/help/assets/*
Generated: frontend/help/*
Builder:   scripts/build_help_docs.py
```

The RTA wizard overlay and pop-out guide consume generated help JSON/HTML from `frontend/help/`.

## Observability model

Observability assets live under `k8s/observability/`.

```text
k8s/observability/
├── dashboards/
│   └── otp-relay-live.json
├── grafana-dashboard-otp-relay-live.yaml
├── grafana-ingressroute.yaml
├── prometheus-stack-values.yaml
├── loki-values.yaml
├── alloy-values.yaml
├── servicemonitor-otp-relay.yaml
└── servicemonitor-otp-monitor.yaml
```

Dashboard source/generated model:

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
ConfigMap: otp-relay-live-dashboard
UID:       otp-relay-live
```

The Grafana dashboard source may be a Grafana `dashboard.grafana.app/v2` export. The generator converts it into classic Grafana dashboard JSON for sidecar provisioning.

The generator must preserve:

- `id: null`
- `uid: otp-relay-live`
- `refresh: 15s`
- `timepicker.refresh_intervals`
- Stat panel type from `vizConfig.group`
- Grid layout and panel sizing

Dashboard metrics include:

```text
up{job="otp-relay"}
up{job="otp-monitor"}
otp_iphone_present
otp_monitor_arp_last_success_timestamp_seconds
otp_queue_depth
otp_active_user
otp_delivered_total
otp_claims_total
otp_iphone_absence_events_total
```

## Kubernetes deployment assets

The active Kubernetes assets live under `k8s/`:

```text
k8s/
├── Dockerfile
├── Dockerfile.monitor
├── manifests/
│   ├── configmap.yaml
│   ├── deployment-monitor.yaml
│   ├── deployment.yaml
│   ├── ingress.yaml
│   ├── namespace.yaml
│   ├── pv-nfs.yaml
│   ├── pvc.yaml
│   ├── redis-configmap.yaml
│   ├── redis-haproxy-configmap.yaml
│   ├── redis-haproxy-deployment.yaml
│   ├── redis-haproxy-service.yaml
│   ├── redis-pdb.yaml
│   ├── redis-sentinel-configmap.yaml
│   ├── redis-sentinel-deployment.yaml
│   ├── redis-sentinel-service.yaml
│   ├── redis-service.yaml
│   ├── redis-statefulset.yaml
│   ├── secret-example.env
│   └── service.yaml
└── observability/
    ├── dashboards/
    ├── grafana-dashboard-otp-relay-live.yaml
    ├── grafana-ingressroute.yaml
    ├── prometheus-stack-values.yaml
    ├── loki-values.yaml
    ├── alloy-values.yaml
    ├── servicemonitor-otp-relay.yaml
    └── servicemonitor-otp-monitor.yaml
```

Do not restore `k8s/docs/`. Documentation belongs under `docs/` only.

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

## Current vs target gap table

| Area | SCH target | Current repo status / remaining work |
|---|---|---|
| External access | DNS plus approved ingress/LB/VIP path | Traefik HTTPS ingress active through internal DNS; final production VIP/LB model still needs SCH confirmation. |
| TLS | HTTPS trusted on user machines | Self-signed TLS enabled; IT Group Policy trust rollout pending. |
| App replicas | Multiple FastAPI app pods | Redis and NFS foundations are in place; current validation posture uses 2 app replicas, with final business-flow sign-off still required. |
| App storage | Shared RWX/network persistent storage | Implemented and validated as static NFS PV/PVC for `/app/data`. |
| Redis | HA Redis/Sentinel/Cluster or approved managed Redis | Redis Sentinel/HAProxy topology implemented and failover validated; production acceptance/backups pending. |
| Failover | Pod kill, node drain, and app movement tests with state survival | Redis failover validated; full worker-drain and final app-level OTP validation still pending. |
| Monitor | Isolated monitor workload on phone-network-capable node | Current no-Service/no-Ingress model is aligned. |
| Observability | Dashboard, metrics, and logs for production visibility | Prometheus/Grafana/Loki/Alloy assets added; OTP Relay dashboard is provisioned from ConfigMap. |
| Documentation | Clear active docs with no conflicting legacy guidance | README and docs now describe source/generated workflows for frontend, help docs, and Grafana. |

## Why app replica validation is still treated carefully

Redis and NFS remove the main architectural blockers for multi-replica validation, but the business-critical flow is OTP delivery. Multiple app pods can be used only when the live OTP flow remains correct under load-balanced traffic.

Do not treat the architecture as production-signed until all of these pass:

- Manager live OTP trigger test.
- Pending OTP restart-survival test.
- Two-replica OTP claim/SMS/display flow validation.
- DNS/TLS client validation from user machines.
- Controlled worker-drain validation.
- Grafana/Prometheus visibility confirms queue, active user, iPhone presence, and Last ARP behavior.

## Remaining production-alignment gaps

1. Confirm final production LB/VIP model with SCH.
2. Complete TLS trust rollout through IT Group Policy.
3. Validate app-level OTP behavior through restart and two-replica scenarios after the latest frontend/dashboard changes.
4. Document Redis backup/restore expectations.
5. Complete worker-drain validation.
6. Decide whether Redis Sentinel/HAProxy is accepted for production or replaced by an approved managed Redis service.
7. Confirm observability retention and access expectations for Grafana, Prometheus, Loki, and Alloy.

## Implementation rule

Do not loosen safeguards just to make the architecture look complete.

The correct current position is:

```text
Redis and NFS foundations are validated.
Redis HA/Sentinel/HAProxy failover is validated.
The app can run with multiple replicas only after final OTP and node-drain validations pass.
Observability is source-driven: dashboard source JSON -> generated ConfigMap -> Grafana sidecar.
Frontend is source-driven: app.jsx -> generated app.js -> portal.
```
