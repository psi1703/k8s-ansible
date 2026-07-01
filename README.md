# k8s-ansible DEVtoPROD Release Bundle Builder

This branch is the DEVtoPROD bundle-only path for OTP Relay Kubernetes release preparation.

It does not deploy anything.

The dev/build side creates a sealed production release bundle. The production server receives only that finished bundle, its checksum, and the handoff report.

## Bundle-only contract

This repository path may:

- prepare the release source tree
- validate local source files
- build frontend/app assets
- render Kubernetes manifests into a staging directory
- build local Docker image archives
- package observability YAML/value files
- write release metadata
- create a sealed `.tar.gz` release bundle
- create a `.sha256` checksum
- create a release report

This repository path must not:

- install K3s
- install Helm
- run Helm install/upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart Kubernetes deployments
- provision VMs
- configure K3s control-plane nodes
- configure K3s worker nodes
- label live Kubernetes nodes
- inspect live Kubernetes PVCs, pods, services, or ingresses
- install GitHub Actions runners
- validate a live cluster
- deploy directly to production

Production-side installation, image loading, Helm execution, Kubernetes manifest application, rollout validation, secret handling, and operational checks are intentionally outside this build path.

## Correct entrypoints

Use either entrypoint from the repository root:

```bash
bash setup.sh
```

or:

```bash
bash build-release-bundle.sh
```

`setup.sh` is now only a compatibility launcher for `build-release-bundle.sh`.

It no longer provisions or deploys infrastructure.

## Artifact selector

The historical variable name `DEPLOY_MODE` is retained for compatibility, but it now means which artifacts to build/package, not deployment.

Supported values:

| Mode | Meaning |
|---|---|
| `full` | Build/package app image, monitor image, rendered manifests, observability metadata |
| `app` | Build/package app image and rendered app/runtime manifests |
| `monitor` | Build/package monitor image and rendered monitor/runtime manifests |
| `none` | Metadata-only bundle validation; no runtime manifests or images |

Examples:

```bash
bash setup.sh --mode full
bash setup.sh --mode app
bash setup.sh --mode monitor
bash setup.sh --mode none
```

## Typical local build

From the dev/build host:

```bash
cp .env.example .env
```

Edit `.env` for the runtime values that must be rendered into the bundle.

Then run:

```bash
bash setup.sh --mode full
```

The final artifacts are written to `dist/` by default.

Expected output includes:

```text
dist/*.tar.gz
dist/*.tar.gz.sha256
dist/*.tar.gz.report.txt
```

## Non-interactive build

For GitHub Actions or local automation:

```bash
bash setup.sh \
  --mode full \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

## Metadata-only validation

For a safe smoke test that does not require runtime manifest values or image builds:

```bash
bash setup.sh \
  --mode none \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

This still produces a sealed metadata-only bundle and checksum.

## Output structure

The sealed release tarball contains a directory similar to:

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

The exact contents depend on the selected artifact mode.

For `DEPLOY_MODE=none`, runtime directories such as `manifests/` and `images/` may be absent.

## Environment file

`.env` is the local build input file.

It controls:

- namespace
- image references
- service type
- ingress/TLS host values
- NFS/PVC values
- Redis values
- monitor runtime values
- observability metadata
- artifact selector
- output directory behavior

Do not commit populated `.env` files.

Secrets must be handled through the approved production-side secret procedure. The bundle builder records only whether secret-backed values were set; it does not create Kubernetes secrets.

## GitHub Actions workflow

The workflow builds a sealed release bundle and uploads bundle artifacts.

It does not:

- sync the repository to production
- run deployment commands
- install K3s
- run Helm
- run `kubectl apply`
- import images
- provision VMs
- install runners

The uploaded workflow artifact is the handoff product.

## Legacy automation

Legacy Ansible and libvirt automation is intentionally disabled.

The following areas are retained only as safety boundaries:

```text
automation/ansible/
automation/libvirt/
```

Old playbooks and roles must fail safely if invoked.

They must not install, provision, deploy, validate, or mutate a live environment.

## Production handoff

The production server receives only:

```text
release-bundle.tar.gz
release-bundle.tar.gz.sha256
release-bundle.tar.gz.report.txt
```

The production-side operator or approved production procedure is responsible for:

- verifying checksums
- loading image archives
- creating/updating Kubernetes secrets
- applying manifests
- running Helm if required by the production procedure
- validating rollout state
- checking portal, Redis, monitor, storage, and observability health

Those steps are outside this repository’s dev/build path.

## Safety rule

If a script in this branch tries to deploy, install K3s, run Helm, run `kubectl apply`, import images into a live cluster, provision VMs, install runners, or validate production, it is a bug.
