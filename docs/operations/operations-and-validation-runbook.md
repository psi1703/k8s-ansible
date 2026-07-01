# Operations and Validation Runbook

## Scope

This runbook applies to the `k8s-ansible-DEVtoPROD` bundle-only branch.

This repository path does not perform production operations or production validation.

It prepares a sealed release bundle on the dev/build host. The production server receives only the finished bundle, checksum, and report.

## Boundary

The dev/build side may:

- validate local source files
- build frontend assets
- build and export local Docker image archives
- render Kubernetes manifests into staging
- package observability YAML/value files
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
- inspect live Kubernetes resources
- validate a live production cluster

Production-side operations are outside this repository path and must be performed only by the approved production procedure.

## Build-side runbook

### 1. Prepare local environment

Create the local environment file:

```bash
cp .env.example .env
```

Edit `.env` for the values that must be rendered into the bundle.

Do not commit populated `.env` files.

### 2. Run metadata-only smoke test

Use metadata-only mode to verify the local bundle path without runtime manifest values or image builds:

```bash
bash setup.sh \
  --mode none \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

Expected result:

```text
dist/*.tar.gz
dist/*.tar.gz.sha256
dist/*.tar.gz.report.txt
```

This smoke test must not contact a Kubernetes cluster.

### 3. Build the selected release bundle

For the full bundle:

```bash
bash setup.sh \
  --mode full \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

For app-only artifacts:

```bash
bash setup.sh \
  --mode app \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

For monitor-only artifacts:

```bash
bash setup.sh \
  --mode monitor \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

### 4. Verify build-side output

The dev/build result should include:

```text
dist/*.tar.gz
dist/*.tar.gz.sha256
dist/*.tar.gz.report.txt
```

The build-side validation is limited to the generated local files and checksums.

The build side must not perform production rollout checks.

## Release bundle contents

A full release bundle typically contains:

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

For `DEPLOY_MODE=none`, runtime directories such as `manifests/` and `images/` may be absent.

## Handoff package

The production handoff consists of:

```text
release-bundle.tar.gz
release-bundle.tar.gz.sha256
release-bundle.tar.gz.report.txt
```

The production server receives only these finished artifacts.

## Production-side responsibility

The approved production procedure is responsible for all live operations, including:

- verifying the release checksum
- unpacking the release bundle
- loading image archives into the production runtime
- creating or updating Kubernetes secrets
- applying manifests
- running Helm if required by the production procedure
- validating rollouts
- checking pods, services, ingress, storage, Redis, monitor, portal, and observability

Those actions are intentionally outside this repository path.

## Build-side non-goals

This branch must not be used to:

- run production readiness checks
- check live pod status
- check live service status
- check live ingress status
- check live PVC status
- check live Redis status
- check live Grafana status
- check live Prometheus status
- restart deployments
- label nodes
- patch Kubernetes resources
- install cluster software

If those actions are needed, use the approved production-side procedure.

## Interpreting build output

A successful build means:

- the selected local source files passed validation
- requested local assets were built
- requested local image archives were exported
- requested manifests were rendered and staged
- release metadata was written
- the release tarball was created
- the release checksum was created

A successful build does not mean:

- production was deployed
- production is healthy
- Kubernetes accepted the manifests
- images were loaded into production
- Redis is running in production
- Grafana is running in production
- the portal is reachable in production
- rollout validation passed in production

## Troubleshooting build-side failures

### Missing tool

If the builder reports a missing tool, install the tool on the dev/build host before rerunning.

The builder does not install packages automatically.

### Missing `.env` values

For runtime manifest modes, populate required render-time values in `.env`.

For metadata-only mode, runtime values are intentionally not required.

### Docker unavailable

If image artifacts are selected, Docker must be available and the Docker daemon must be running on the dev/build host.

The builder does not install Docker.

### Frontend build failure

For app artifacts, check:

```text
package.json
package-lock.json
frontend/app.jsx
frontend/index.html
frontend/style.css
```

The generated bundle must be:

```text
frontend/app.js
```

A root-level `app.js` file is forbidden.

### Manifest validation failure

Manifest validation is local file validation only.

It checks rendered YAML structure and required files.

It does not contact a live cluster.

### Checksum failure

Regenerate the release bundle and checksum from the dev/build host.

Do not edit files inside the tarball after creation.

## Legacy validation scripts

Legacy validation paths are disabled.

For example:

```text
scripts/cluster-health-check.sh
automation/ansible/roles/validation/
automation/ansible/playbooks/70-validate-production.yml
```

These paths must fail safely if invoked from this branch.

They must not query production.

## Safety rule

If a command in this branch installs K3s, runs Helm, runs `kubectl apply`, imports images into a live cluster, provisions VMs, installs runners, restarts deployments, or validates production, it is a bug.
