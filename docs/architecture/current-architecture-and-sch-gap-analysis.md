# Current Architecture and SCH Gap Analysis

## Scope

This document applies to the `k8s-ansible-DEVtoPROD` bundle-only branch.

It describes the intended OTP Relay Kubernetes runtime architecture and the DEVtoPROD handoff boundary.

This branch does not deploy OTP Relay.

It builds a sealed production release bundle on the dev/build host. The production server receives only the finished bundle, checksum, and report.

## Architecture boundary

The architecture has two separate sides:

```text
DEV/build side
  -> validate source locally
  -> build frontend assets locally
  -> build/export image archives locally
  -> render Kubernetes manifests locally
  -> package observability files locally
  -> create sealed release bundle
  -> create checksum and report

PROD side
  -> receive finished bundle
  -> verify checksum
  -> load image archives
  -> create/update secrets
  -> apply manifests
  -> perform approved production rollout
  -> perform approved production validation
```

The DEV/build side must not perform production actions.

The PROD side must not receive an unfinished source checkout as the handoff product.

## Bundle-only contract

The DEV/build path may:

- prepare the source tree
- validate local source files
- build frontend assets
- build local Docker images
- export Docker image archives
- render Kubernetes manifests into staging
- package observability YAML/value files
- package release metadata
- create checksums
- create a sealed release tarball
- create a release report

The DEV/build path must not:

- install K3s
- install Helm
- run Helm install or upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart deployments
- provision VMs
- configure control-plane nodes
- configure worker nodes
- label live Kubernetes nodes
- inspect live Kubernetes resources
- install GitHub Actions runners
- validate a live production cluster
- deploy directly to production

Production-side installation, image loading, Helm execution, manifest application, rollout validation, secret handling, and operational checks are outside this repository path.

## Target runtime architecture

The target runtime architecture remains OTP Relay on Kubernetes.

The bundle contains the inputs required by the approved production procedure to create or update that runtime.

```text
Clients / browsers / iPhone Shortcut
  -> DNS / ingress host
  -> Kubernetes ingress controller
  -> Kubernetes Service
  -> FastAPI app pods
  -> Redis HAProxy service
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data storage
  -> Portal UI displays OTP

iPhone / test SMS source
  -> receives or simulates OTP/SMS path
  -> iOS Shortcut or test signal posts to the portal
  -> portal stores OTP state in Redis with TTL
  -> browser polling displays OTP to the active user

Monitor pod
  -> phone presence checks
  -> Prometheus metrics
  -> audit-log observation
  -> optional Telegram alerts

Observability
  -> ServiceMonitor resources, when used by the production procedure
  -> Prometheus metrics
  -> Grafana dashboards
  -> optional Loki/Alloy log collection
```

The dev/build branch packages the runtime intent.

It does not verify the live runtime state.

## Node and infrastructure model

The intended production runtime may include:

| Runtime role | Purpose |
|---|---|
| Control-plane | Kubernetes API/control-plane managed by production procedure |
| Worker nodes | Runtime app, monitor, Redis, and observability placement |
| NFS server | External persistent storage for app and Redis data |
| Ingress controller | Production ingress/TLS entrypoint |
| Observability stack | Metrics, dashboards, and optional logs |

The bundle builder does not create or manage these nodes.

The bundle builder does not provision VMs.

The bundle builder does not join workers to a cluster.

The bundle builder does not label nodes.

Placement intent is rendered as manifest values or metadata only.

## Runtime configuration model

The local `.env` file is the input source for render-time and package-time values.

Examples:

```text
NAMESPACE
APP_IMAGE
MONITOR_IMAGE
SERVICE_TYPE
INGRESS_ENABLED
TLS_ENABLED
TLS_HOST
TLS_SECRET_NAME
NFS_ENABLED
NFS_SERVER
NFS_PATH
NFS_STORAGE_CLASS
PVC_STORAGE_CLASS
REDIS_ENABLED
REDIS_REQUIRED
REDIS_URL
PHONE_IP
PHONE_INTERFACE
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
SMS_SECRET_TOKEN
REPLICA_COUNT
OBSERVABILITY_NAMESPACE
GRAFANA_HOST
```

`.env` is consumed on the DEV/build side only.

Do not commit populated `.env` files.

Secrets must be created or updated only through the approved production-side secret procedure.

The bundle builder records whether secret-backed values were set, but it does not create Kubernetes secrets.

## Application model

The app runtime consists of:

- FastAPI backend
- `otp_relay/` Python package
- generated frontend bundle
- browser-delivered OTP UI
- Redis-backed OTP state
- Redis-backed admin/session state
- PVC-backed runtime files under `/app/data`
- rendered ConfigMap and Deployment manifests
- local image archive packaged in the release bundle when selected

Important source paths:

```text
main.py
otp_relay/
frontend/app.jsx
frontend/index.html
frontend/style.css
frontend/app.js
k8s/Dockerfile
```

The source of truth for the frontend is:

```text
frontend/app.jsx
```

The generated browser bundle is:

```text
frontend/app.js
```

A root-level `app.js` file is not allowed.

## Monitor model

The monitor runtime consists of:

- monitor Python entrypoint
- `otp_monitor/` Python package
- phone presence checks
- Prometheus metrics endpoint
- optional Telegram alerting
- rendered monitor Deployment and Service manifests
- local monitor image archive packaged in the release bundle when selected

Important source paths:

```text
monitor.py
otp_monitor/
k8s/Dockerfile.monitor
```

Monitor runtime values are rendered from `.env`.

If values such as `PHONE_IP` or `PHONE_INTERFACE` are incomplete, the build path must not try to validate the production network. It should warn and leave final runtime validation to the production procedure.

## Redis model

The intended runtime may include Redis, Redis Sentinel, and HAProxy.

The bundle may package Redis manifests and Redis metadata.

Important values:

```text
REDIS_ENABLED
REDIS_REQUIRED
REDIS_URL
REDIS_STORAGE_CLASS
REDIS_SIZE
REDIS_NFS_SERVER
REDIS_NFS_BASE_PATH
```

The bundle builder does not deploy Redis.

The bundle builder does not inspect Redis pods.

The bundle builder does not validate Redis failover.

Those checks belong to the approved production procedure.

## Storage model

The intended runtime uses persistent storage for app data and Redis data.

NFS-backed storage intent is rendered from `.env`.

Important values:

```text
NFS_ENABLED
NFS_SERVER
NFS_PATH
NFS_STORAGE_CLASS
NFS_PV_NAME
PVC_STORAGE_CLASS
PVC_SIZE
```

The bundle builder does not validate live NFS mounts.

The bundle builder does not create production directories.

The bundle builder does not inspect live PVCs or storage classes.

Storage validation belongs to the approved production procedure.

## Ingress and TLS model

Ingress/TLS intent is rendered from `.env`.

Important values:

```text
INGRESS_ENABLED
TLS_ENABLED
TLS_HOST
TLS_SECRET_NAME
TLS_SELF_SIGNED
PORTAL_URL
```

The bundle builder does not create TLS secrets.

The bundle builder does not validate DNS.

The bundle builder does not inspect ingress controller state.

TLS secret creation and ingress validation belong to the approved production procedure.

## Observability model

The intended production runtime may include:

- Prometheus
- Grafana
- ServiceMonitor resources
- Grafana dashboards
- optional Loki/Alloy log collection

The bundle builder may package static observability YAML/value files and generated dashboard ConfigMap YAML.

Important paths:

```text
k8s/observability/
k8s/observability/dashboards/
scripts/build_grafana_dashboard_configmap.py
```

The bundle builder does not run Helm.

The bundle builder does not install observability components.

The bundle builder does not query Grafana, Prometheus, Loki, or Alloy.

Observability rollout and validation belong to the approved production procedure.

## Release bundle architecture

The release bundle is the DEVtoPROD handoff product.

A full bundle may contain:

```text
otp-relay-k8s-<namespace>-<timestamp>-<gitsha>/
├── PROD-HANDOFF.md
├── manifests/
├── observability/
├── images/
└── metadata/
    ├── release.env
    ├── secret-handoff.txt
    ├── file-index.txt
    └── SHA256SUMS
```

The exact bundle contents depend on the selected artifact mode.

For `DEPLOY_MODE=none`, runtime directories such as `manifests/` and `images/` may be absent.

## Artifact selector

The historical variable `DEPLOY_MODE` is retained only for compatibility.

In this branch it means artifact selector, not deployment.

| Mode | Meaning |
|---|---|
| `full` | App image, monitor image, rendered manifests, observability files, metadata |
| `app` | App image and rendered runtime manifests |
| `monitor` | Monitor image and rendered runtime manifests |
| `none` | Metadata-only bundle validation |

No mode deploys.

## SCH alignment target

The SCH-aligned target is a clean separation between build and production operation.

Required alignment points:

- DEV/build produces a sealed release bundle only
- PROD receives only the finished bundle artifacts
- production secrets are not committed
- production secrets are not generated by the build path
- image archives are packaged, not imported into a live cluster by the build path
- manifests are rendered, not applied by the build path
- observability files are packaged, not installed by the build path
- validation reports describe build output, not live production health
- legacy deploy automation fails safely

## Current gap status

The branch is aligned only when all of the following are true:

- `setup.sh` launches the bundle builder only
- `build-release-bundle.sh` does not call live deployment actions
- `scripts/lib/` functions do not deploy or validate production
- GitHub Actions uploads bundle artifacts only
- Ansible playbooks and roles are disabled stubs
- libvirt provisioning is disabled
- documentation describes bundle-only behavior
- no build-side path installs K3s, runs Helm, runs `kubectl apply`, imports images, provisions VMs, installs runners, restarts deployments, or validates production

Any remaining live-deploy behavior in this branch is a gap.

## Architectural sign-off gates

A change is acceptable only if it preserves these gates:

1. Build path creates local artifacts only.
2. Production receives only the sealed bundle, checksum, and report.
3. No build-side script mutates a live Kubernetes cluster.
4. No build-side script provisions infrastructure.
5. No build-side script installs runners.
6. No build-side script validates production.
7. Legacy automation fails safely.
8. Documentation does not instruct direct deployment from this branch.

## Safety rule

If a script or document in this branch tells the dev/build path to install K3s, run Helm, run `kubectl apply`, import images into a live cluster, provision VMs, install runners, restart deployments, or validate production, it is wrong and must be corrected.
