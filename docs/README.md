# Documentation Index

This documentation set belongs to the `k8s-ansible-DEVtoPROD` bundle-only branch.

This branch does not deploy OTP Relay.

It builds a sealed production release bundle on the dev/build host. The production server receives only the finished bundle, checksum, and report.

## Bundle-only documentation rule

Documentation in this branch must describe the dev/build path as bundle-only.

The dev/build side may:

- validate local source files
- build frontend assets
- build and export local Docker image archives
- render Kubernetes manifests into staging
- package observability files
- write release metadata
- create checksums
- create a sealed release tarball
- create a release report

The dev/build side must not:

- install K3s
- install Helm
- run Helm install or upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart deployments
- provision VMs
- install GitHub Actions runners
- label live Kubernetes nodes
- inspect live Kubernetes resources
- validate a live production cluster
- deploy directly to production

Production-side installation, image loading, Helm execution, Kubernetes manifest application, rollout validation, secret handling, and operational checks are outside this repository path.

## Start here

| Topic | File | Purpose |
|---|---|---|
| Repository overview | `../README.md` | Main bundle-only project overview and entrypoints |
| Deployment/storage handoff | `deployment/deployment-and-storage-guide.md` | Storage, ingress, Redis, and handoff values rendered into the bundle |
| Build/development | `development/build-and-development-guide.md` | Local build rules, source validation, image archive export, and bundle creation |
| Operations boundary | `operations/operations-and-validation-runbook.md` | Explains what the build side does and what production-side validation must handle |
| Observability packaging | `operations/observability-and-grafana.md` | Observability metadata and file packaging without Helm or live validation |

## Current source of truth

For this branch, the source of truth is:

```text
build-release-bundle.sh
setup.sh
scripts/lib/
.env.example
.github/workflows/sync.yml
```

The build path creates release artifacts only.

Legacy Ansible and libvirt automation is intentionally disabled.

## Correct build command

From the repository root:

```bash
bash setup.sh
```

or:

```bash
bash build-release-bundle.sh
```

Examples:

```bash
bash setup.sh --mode full
bash setup.sh --mode app
bash setup.sh --mode monitor
bash setup.sh --mode none
```

## Artifact selector

The historical variable `DEPLOY_MODE` is now an artifact selector only.

| Mode | Meaning |
|---|---|
| `full` | App image, monitor image, rendered manifests, observability files, metadata |
| `app` | App image and rendered runtime manifests |
| `monitor` | Monitor image and rendered runtime manifests |
| `none` | Metadata-only bundle validation |

No mode deploys.

## Expected output

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

The production handoff product is the sealed bundle plus checksum and report.

## Help documentation

The files under `docs/help/` are application help content used by the OTP Relay portal.

They are not deployment instructions.

They may be processed by the local help-doc build step when app artifacts are selected.

## Architecture notes

Architecture documents should describe the target runtime design and the bundle-only handoff boundary.

They must not instruct the dev/build path to install, deploy, apply, import, or validate against production.

## Legacy notes

Archived or historical deployment notes must not be used as current operational instructions for this branch.

Any stale documentation that says this branch deploys directly should be replaced or marked obsolete.

## Safety rule

If documentation in this branch tells the dev/build path to install K3s, run Helm, run `kubectl apply`, import images into a live cluster, provision VMs, install runners, restart deployments, or validate production, the documentation is wrong and must be corrected.
