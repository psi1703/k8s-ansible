# Observability and Grafana Guide

## Scope

This guide applies to the `k8s-ansible-DEVtoPROD` bundle-only branch.

This branch does not install or operate the observability stack.

It may package observability-related YAML, values, dashboard ConfigMaps, and metadata into the sealed production release bundle.

The production server receives only the finished bundle, checksum, and report.

## Bundle-only boundary

The dev/build side may:

- package observability YAML/value files
- generate static dashboard ConfigMap YAML from repository dashboard JSON
- record observability namespace and Grafana host metadata
- include observability files in the release bundle
- include observability intent in the release report

The dev/build side must not:

- install Prometheus
- install Grafana
- install Loki
- install Alloy
- run Helm install or upgrade
- run Helm repository commands against production
- run `kubectl apply`
- inspect live ServiceMonitors
- inspect live Grafana dashboards
- inspect live Prometheus targets
- inspect live Loki or Alloy pods
- validate a live observability stack

Production-side observability installation and validation are outside this repository path.

## Relevant configuration

Observability intent is configured through `.env`.

Common values:

```bash
OBSERVABILITY_NAMESPACE="observability-devprod"
OBSERVABILITY_INSTALL_STACK="1"
OBSERVABILITY_STACK_CHART_VERSION="85.0.1"
GRAFANA_HOST="grafana-devprod.init-db.lan"
```

These values are recorded in release metadata and reports.

They do not cause the dev/build path to run Helm or mutate a cluster.

## Source files

Observability source files may exist under:

```text
k8s/observability/
```

Dashboard source JSON may exist under:

```text
k8s/observability/dashboards/
```

If the repository contains a dashboard source such as:

```text
k8s/observability/dashboards/otp-relay-live.json
```

the builder may generate a static ConfigMap YAML using the local generator script.

Expected generator path:

```text
scripts/build_grafana_dashboard_configmap.py
```

This generation is local file generation only.

It does not contact Grafana.

It does not apply the generated ConfigMap.

## Packaging behavior

During a bundle build, observability files may be staged under:

```text
observability/
```

inside the release bundle.

A full release bundle may look like:

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

Exact contents depend on the selected artifact mode and the files present in the repository.

## Artifact modes

The historical variable `DEPLOY_MODE` is an artifact selector only.

| Mode | Observability behavior |
|---|---|
| `full` | May package observability files and metadata |
| `app` | May package runtime manifests and app artifacts; observability packaging depends on staged source files |
| `monitor` | May package monitor artifacts; observability packaging depends on staged source files |
| `none` | Metadata-only validation; runtime observability files may be absent |

No mode deploys observability.

## Build examples

Full bundle:

```bash
bash setup.sh \
  --mode full \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

Metadata-only smoke test:

```bash
bash setup.sh \
  --mode none \
  --skip-repo-sync 1 \
  --git-clean 0 \
  --noninteractive \
  --dist-dir dist
```

## What a successful build means

A successful build means observability files, if present and selected, were packaged into the release bundle.

It does not mean:

- Grafana is installed
- Prometheus is installed
- Loki is installed
- Alloy is installed
- dashboards were imported into a live Grafana instance
- Prometheus targets are healthy
- Loki ingestion is working
- Grafana is reachable
- production observability is healthy

Those checks are production-side responsibilities.

## Production-side responsibility

The approved production procedure is responsible for:

- unpacking the release bundle
- reviewing packaged observability files
- installing or upgrading observability components if required
- applying observability manifests if required
- importing or applying Grafana dashboards if required
- validating Prometheus targets
- validating ServiceMonitors
- validating Grafana access
- validating Loki and Alloy health
- validating OTP Relay dashboards

These steps are intentionally outside the dev/build path.

## Legacy behavior

Older versions of this repository could install or validate observability through Helm or live Kubernetes commands.

That behavior is disabled in this branch.

Any script in this branch that runs Helm, applies observability manifests, or queries live observability resources from the dev/build path is wrong.

## Safety rule

If this branch runs Helm, runs `kubectl apply`, contacts Grafana, queries Prometheus, checks Loki pods, or validates a live observability stack, it is a bug.
