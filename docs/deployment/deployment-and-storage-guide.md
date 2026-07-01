# Deployment and Storage Guide

## Scope

This document applies to the `k8s-ansible-DEVtoPROD` bundle-only branch.

This branch does not deploy OTP Relay.

It prepares a sealed production release bundle on the dev/build host. The production server receives only the finished bundle, checksum, and report.

## Bundle-only contract

The dev/build side may:

- validate local source files
- build frontend assets
- build Docker image archives
- render Kubernetes manifests into a staging directory
- package observability YAML/value files
- package release metadata
- create a sealed `.tar.gz` release bundle
- create a `.sha256` checksum
- create a handoff report

The dev/build side must not:

- install K3s
- configure K3s control-plane nodes
- configure K3s worker nodes
- provision VMs
- install GitHub Actions runners
- install Helm
- run Helm install or upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart deployments
- inspect live PVCs, pods, services, nodes, or ingresses
- validate a live production cluster

Production-side execution is outside this repository path and must be performed only by the approved production procedure.

## Correct build entrypoints

From the repository root:

```bash
bash setup.sh
```

or:

```bash
bash build-release-bundle.sh
```

`setup.sh` is a compatibility launcher. It forwards to `build-release-bundle.sh`.

It does not provision, install, deploy, or validate a live cluster.

## Artifact modes

The historical variable name `DEPLOY_MODE` is retained for compatibility.

In this branch, `DEPLOY_MODE` means artifact selector, not deployment mode.

Supported values:

| Mode | Meaning |
|---|---|
| `full` | Package app image, monitor image, rendered runtime manifests, observability files, metadata |
| `app` | Package app image and rendered runtime manifests |
| `monitor` | Package monitor image and rendered runtime manifests |
| `none` | Metadata-only bundle validation; no runtime manifests or image archives |

Examples:

```bash
bash setup.sh --mode full
bash setup.sh --mode app
bash setup.sh --mode monitor
bash setup.sh --mode none
```

## Environment file

Create a local `.env` from the example:

```bash
cp .env.example .env
```

Edit `.env` for the values that must be rendered into the release bundle.

Do not commit populated `.env` files.

The `.env` file controls:

- namespace
- image references
- service type
- ingress/TLS host values
- NFS/PVC values
- Redis values
- monitor runtime values
- observability metadata
- artifact selector
- bundle output directory

## Storage model

The bundle builder only renders storage intent into Kubernetes manifests and metadata.

It does not validate live storage.

It does not inspect live PVCs.

It does not mount NFS exports.

It does not create production directories.

It does not create or validate Kubernetes storage classes.

Storage configuration values are rendered from `.env`.

Important values:

```bash
NFS_ENABLED="1"
NFS_SERVER=""
NFS_PATH=""
NFS_STORAGE_CLASS="otp-relay-devprod-nfs"
NFS_PV_NAME="otp-relay-data-devprod-nfs-pv"
PVC_STORAGE_CLASS="otp-relay-devprod-nfs"
PVC_SIZE="1Gi"
```

Redis storage values:

```bash
REDIS_ENABLED="1"
REDIS_STORAGE_CLASS="otp-redis-devprod-nfs"
REDIS_SIZE="1Gi"
REDIS_NFS_PV_PREFIX="otp-redis-devprod"
REDIS_NFS_SERVER=""
REDIS_NFS_BASE_PATH="/redis"
```

When `NFS_ENABLED=1`, `NFS_SERVER` and `NFS_PATH` must be populated for runtime manifest rendering modes.

For metadata-only mode, storage values are not required.

## Ingress and TLS model

The bundle builder only renders ingress/TLS references into manifests and metadata.

It does not create TLS secrets.

It does not generate production certificates.

It does not install or configure Traefik.

It does not validate DNS.

Important values:

```bash
INGRESS_ENABLED="1"
TLS_ENABLED="0"
TLS_HOST="CHANGE_ME_TLS_HOST"
TLS_SECRET_NAME="otp-relay-tls"
TLS_SELF_SIGNED="1"
PORTAL_URL=""
```

When ingress or TLS rendering is enabled, `TLS_HOST` must be changed from the placeholder before building runtime manifests.

Production-side TLS secret creation is outside this build path.

## Redis model

The bundle builder renders Redis intent into manifests and metadata.

It does not deploy Redis.

It does not validate Redis health.

It does not inspect Redis pods.

Important values:

```bash
REDIS_ENABLED="1"
REDIS_URL="redis://otp-redis-haproxy:6379/0"
REDIS_REQUIRED="1"
REDIS_STORAGE_CLASS="otp-redis-devprod-nfs"
REDIS_SIZE="1Gi"
```

When Redis is enabled, the generated manifests and app configuration are packaged into the bundle.

Production-side Redis rollout and validation are outside this build path.

## Monitor model

The monitor image and monitor manifests are packaged when the selected artifact mode requires monitor artifacts.

Important values:

```bash
PHONE_IP=""
PHONE_INTERFACE=""
PHONE_PING_INTERVAL="10"
PHONE_OFFLINE_THRESHOLD="30"
PHONE_ARP_COUNT="2"
PHONE_ARP_TIMEOUT="2"
MONITOR_METRICS_PORT="9101"
```

If monitor runtime values are incomplete, the bundle builder warns instead of contacting a live cluster.

Production-side monitor validation is outside this build path.

## Observability model

The bundle builder may package observability YAML/value files and metadata.

It does not install Prometheus.

It does not install Grafana.

It does not install Loki.

It does not run Helm.

It does not validate dashboards.

Important values:

```bash
OBSERVABILITY_NAMESPACE="observability-devprod"
OBSERVABILITY_INSTALL_STACK="1"
OBSERVABILITY_STACK_CHART_VERSION="85.0.1"
GRAFANA_HOST="grafana-devprod.init-db.lan"
```

Production-side Helm execution, if required by the approved production procedure, is outside this repository path.

## Building the release bundle

Typical full bundle:

```bash
bash setup.sh --mode full
```

Non-interactive local or CI build:

```bash
bash setup.sh \
  --mode full \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

Metadata-only safety check:

```bash
bash setup.sh \
  --mode none \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

## Output artifacts

The default output directory is:

```text
dist/
```

Expected files:

```text
dist/*.tar.gz
dist/*.tar.gz.sha256
dist/*.tar.gz.report.txt
```

The tarball contains a release directory similar to:

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

Exact contents depend on the selected artifact mode.

## Handoff to production

The dev/build output handed to production is:

```text
release-bundle.tar.gz
release-bundle.tar.gz.sha256
release-bundle.tar.gz.report.txt
```

The production server receives only these finished artifacts.

Production-side installation is not performed by this branch.

## Production-side responsibilities

The approved production procedure is responsible for:

- verifying the release checksum
- unpacking the release bundle
- loading image archives into the production runtime
- creating or updating Kubernetes secrets
- applying manifests
- running Helm if required by the production procedure
- validating rollouts
- validating storage
- validating Redis
- validating monitor health
- validating portal health
- validating observability

These steps are intentionally outside the dev/build path.

## Legacy deployment automation

Legacy Ansible and libvirt paths are disabled.

These directories are retained only as safety boundaries:

```text
automation/ansible/
automation/libvirt/
```

Their playbooks, roles, and scripts must fail safely if invoked.

They must not provision, install, deploy, validate, or mutate a live environment.

## Safety rule

If any script in this branch installs K3s, runs Helm, runs `kubectl apply`, imports images into a live cluster, provisions VMs, installs runners, restarts deployments, or validates production, it is a bug.
