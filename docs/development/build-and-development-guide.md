# Build and Development Guide

## Scope

This guide applies to the `k8s-ansible-DEVtoPROD` bundle-only branch.

This branch is used to prepare OTP Relay Kubernetes release artifacts on the dev/build host.

It does not deploy.

It does not install or configure a Kubernetes cluster.

It does not mutate production.

The production server receives only the sealed release bundle, checksum, and report.

## Development model

The development side is responsible for producing a complete handoff artifact.

The bundle builder may:

- validate repository source files
- build frontend assets
- build local Docker images
- export Docker image archives
- render Kubernetes manifests into staging
- package observability YAML/value files
- write release metadata
- write checksums
- create a sealed release tarball

The bundle builder must not:

- install K3s
- install Helm
- run Helm install or upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart deployments
- provision worker VMs
- install GitHub Actions runners
- label live Kubernetes nodes
- inspect live Kubernetes resources
- validate a live production cluster

Production-side execution is outside this repository path.

## Main entrypoints

From the repository root, use:

```bash
bash setup.sh
```

or:

```bash
bash build-release-bundle.sh
```

`setup.sh` is only a compatibility launcher. It forwards to `build-release-bundle.sh`.

It must not contain standalone deployment logic.

## Artifact selector

The historical variable name `DEPLOY_MODE` is retained only for compatibility.

In this branch, it means artifact selector.

Supported values:

| Mode | Purpose |
|---|---|
| `full` | Build/package app image, monitor image, rendered manifests, observability files, metadata |
| `app` | Build/package app image and rendered runtime manifests |
| `monitor` | Build/package monitor image and rendered runtime manifests |
| `none` | Metadata-only bundle validation |

Examples:

```bash
bash setup.sh --mode full
bash setup.sh --mode app
bash setup.sh --mode monitor
bash setup.sh --mode none
```

## Required local build tools

The builder expects required tools to already exist on the dev/build host.

It does not install packages automatically.

Typical tools:

- `bash`
- `git`
- `python3`
- `npm`
- `docker`
- `tar`
- `gzip`
- `sha256sum`
- standard POSIX tools such as `find`, `grep`, `sed`, `awk`, and `sort`

`npm` is required only when app artifacts are selected.

Docker is required only when image artifacts are selected.

For `DEPLOY_MODE=none`, the builder should not require runtime manifests, frontend build output, or image builds.

## Environment file

Create `.env` from the example:

```bash
cp .env.example .env
```

Do not commit populated `.env` files.

The `.env` file provides render-time and package-time values.

Important groups:

- release branch/source values
- namespace
- image references
- service/ingress/TLS values
- NFS/PVC values
- Redis values
- monitor values
- observability metadata
- artifact selector
- output directory

The builder forces bundle-only safety flags even if `.env` contains older deployment values.

Forced disabled values include:

```bash
SKIP_CLUSTER_DEPLOY="1"
SKIP_K3S_INSTALL="1"
SKIP_HELM_INSTALL="1"
SKIP_KUBECTL_APPLY="1"
SKIP_IMAGE_IMPORT="1"
SKIP_ROLLOUT_RESTART="1"
SKIP_LIVE_CLUSTER_VALIDATE="1"
SKIP_GITHUB_RUNNER_INSTALL="1"
SKIP_VM_PROVISIONING="1"
DEPLOY_OTP_RELAY="0"
VALIDATE_OTP_RELAY="0"
INSTALL_GITHUB_RUNNER="0"
RUNNER_ONLY="0"
DISTRIBUTE_IMAGES_TO_NODES="0"
```

## Frontend build

When app artifacts are selected, the builder validates and builds the frontend.

Expected source files:

```text
frontend/app.jsx
frontend/index.html
frontend/style.css
package.json
package-lock.json
```

Expected generated output:

```text
frontend/app.js
```

The root-level file `app.js` is forbidden.

The browser bundle must be generated into `frontend/app.js`.

## Python source validation

When app artifacts are selected, the builder validates app Python sources.

Expected app files include:

```text
main.py
otp_relay/
requirements.txt
```

When monitor artifacts are selected, the builder validates monitor Python sources.

Expected monitor files include:

```text
monitor.py
otp_monitor/
requirements.txt
```

The builder may run Python syntax checks locally.

It must not contact Kubernetes.

## Docker image build/export

When image artifacts are selected, Docker may be used only on the dev/build host.

Allowed Docker actions:

- build local image
- inspect local image
- save local image to archive

Forbidden Docker/Kubernetes image actions:

- importing into K3s/containerd
- distributing images to live nodes
- creating importer DaemonSets
- starting temporary image distribution servers for cluster nodes
- querying Kubernetes nodes

Image archives are packaged under the release bundle `images/` directory.

## Manifest rendering

When runtime manifests are selected, the builder stages and renders files from:

```text
k8s/manifests/
```

The builder validates rendered files locally for basic manifest structure.

It must not run Kubernetes dry-run against a live cluster.

It must not run `kubectl apply`.

It must not create namespaces.

It must not inspect PVCs, storage classes, pods, services, or ingresses.

## Observability files

The builder may package observability YAML/value files from:

```text
k8s/observability/
```

It may generate static dashboard ConfigMap YAML from repository JSON source.

It must not run Helm.

It must not install Prometheus, Grafana, Loki, or Alloy.

It must not validate dashboards against a live Grafana instance.

## Release bundle creation

The builder creates a sealed tarball and checksum under `dist/` by default.

Typical output:

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

## Local smoke test

The safest smoke test is metadata-only mode:

```bash
bash setup.sh \
  --mode none \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

This validates the bundle path without requiring runtime manifest values or image builds.

## Full local release build

After `.env` is configured:

```bash
bash setup.sh \
  --mode full \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

This should produce a sealed release bundle and checksum.

## GitHub Actions build

The GitHub Actions workflow must build and upload only release bundle artifacts.

It must not sync the repository as the production handoff product.

It must not run deployment commands.

It must not install K3s, run Helm, run `kubectl apply`, import images, provision VMs, or install runners.

The uploaded artifact is the production handoff product.

## Legacy automation

Legacy automation paths are retained only as disabled safety boundaries.

Examples:

```text
automation/ansible/
automation/libvirt/
```

These paths must fail safely if invoked.

They must not provision, install, deploy, validate, or mutate a live environment.

## Development rule

When adding or editing scripts in this branch, keep the boundary strict:

- build/package locally
- render files locally
- create bundle locally
- do not deploy
- do not call live cluster tools
- do not mutate production

If a development change reintroduces live deployment behavior into the dev/build path, it is a bug.
