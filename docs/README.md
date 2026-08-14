# OTP Relay Kubernetes Documentation

This directory is the documentation home for the OTP Relay Kubernetes project.

The root `README.md` gives the short project overview. This file is the documentation index for maintainers, operators, and reviewers who need to understand the implementation in detail.

The documentation is organized in layers so the project can be reviewed the same way it is deployed: application first, then Kubernetes runtime, then resilience, observability, automation, and operations.

---

## Documentation layers

| Layer | Purpose | Primary document |
| --- | --- | --- |
| 1. Application model | Explains what OTP Relay does, how the browser, iPhone Shortcut, portal app, monitor, and Redis state interact. | [`architecture/current-architecture-and-sch-gap-analysis.md`](architecture/current-architecture-and-sch-gap-analysis.md) |
| 2. Kubernetes runtime | Explains namespaces, workloads, services, ingress, persistent storage, and node placement. | [`deployment/deployment-and-storage-guide.md`](deployment/deployment-and-storage-guide.md) |
| 3. Resilience extensions | Explains the production-resilience additions beyond the simple SCH baseline: Redis HA, Sentinel, HAProxy, NFS RWX, pod spreading, worker placement, and validation expectations. | [`architecture/current-architecture-and-sch-gap-analysis.md`](architecture/current-architecture-and-sch-gap-analysis.md) |
| 4. Observability | Explains Prometheus, Grafana, Loki, Alloy, ServiceMonitor resources, dashboards, and access/troubleshooting. | [`operations/observability-and-grafana.md`](operations/observability-and-grafana.md) |
| 5. Operations | Explains day-to-day health checks, validation, troubleshooting, OTP confirmation, and safe recovery commands. | [`operations/operations-and-validation-runbook.md`](operations/operations-and-validation-runbook.md) |
| 6. Build and generated files | Explains frontend build, help-doc generation, dashboard ConfigMap generation, Docker image build behavior, and generated artifact rules. | [`development/build-and-development-guide.md`](development/build-and-development-guide.md) |
| 7. Portal user help | Source Markdown and screenshots used to generate the portal help pages. | [`help/`](help/) |

---

## Recommended reading order

For SCH review, new maintainers, or IT handover, read in this order:

1. [`../README.md`](../README.md) — short project overview and access model.
2. [`architecture/current-architecture-and-sch-gap-analysis.md`](architecture/current-architecture-and-sch-gap-analysis.md) — architecture, SCH alignment, intentional improvements, and known divergences.
3. [`deployment/deployment-and-storage-guide.md`](deployment/deployment-and-storage-guide.md) — installation, `.env`, Kubernetes storage, NFS, Redis, and deployment behavior.
4. [`operations/operations-and-validation-runbook.md`](operations/operations-and-validation-runbook.md) — daily checks, post-install validation, OTP testing, and recovery procedures.
5. [`operations/observability-and-grafana.md`](operations/observability-and-grafana.md) — Grafana, Prometheus, Loki, Alloy, dashboards, metrics, and access troubleshooting.
6. [`development/build-and-development-guide.md`](development/build-and-development-guide.md) — source/generated file rules and development workflow.

Portal end-user help source is separate and lives under:

```text
/docs/help/
```

Generated portal help output lives under:

```text
/frontend/help/
```

Do not edit generated help output as source.

---

## Source-of-truth map

| Area | Source of truth | Generated or rendered output | Generation path |
| --- | --- | --- | --- |
| Operator configuration | `.env` | rendered manifests, Ansible handoff, install report, runtime configuration | `setup.sh` / installer libraries |
| Portal frontend | `frontend/app.jsx` | `frontend/app.js` | frontend build step |
| Portal help | `docs/help/*.md`, `docs/help/assets/*` | `frontend/help/*` | `python3 scripts/build_help_docs.py` |
| Grafana dashboard | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` | `python3 scripts/build_grafana_dashboard_configmap.py` |
| Kubernetes manifests | `k8s/`, `scripts/lib/*.sh`, `.env` | rendered/applied cluster resources | `setup.sh` / installer libraries |
| Repo sync service | `scripts/sync-repo.sh`, `scripts/install-repo-sync-timer.sh`, `systemd/` | optional local systemd timer and sync state | operator action |

Rule: update the source file first, then regenerate the expected output through the documented command or installer path. Do not hand-edit generated files as the long-term fix.

---

## Documentation ownership

Avoid duplicating long procedures across files. Put each topic in its owner document and cross-link from other documents.

| Topic | Owner document |
| --- | --- |
| Overall project concept and layered architecture | `README.md` and `docs/README.md` |
| SCH comparison, architecture, and production gaps | `docs/architecture/current-architecture-and-sch-gap-analysis.md` |
| Install/update behavior, `.env`, K3s, NFS, Redis storage, services, ingress | `docs/deployment/deployment-and-storage-guide.md` |
| Daily checks, troubleshooting, validation, OTP testing, worker drains, safe recovery | `docs/operations/operations-and-validation-runbook.md` |
| Prometheus, Grafana, Loki, Alloy, dashboard generation, metrics, Grafana access | `docs/operations/observability-and-grafana.md` |
| Python package layout, Dockerfiles, frontend build, help generation, generated artifacts | `docs/development/build-and-development-guide.md` |
| Portal user-facing help content | `docs/help/` |

---

## Runtime files that must not be committed

Do not commit runtime state, secrets, local inventory, generated reports, or local build artifacts unless a document explicitly says the artifact is versioned.

Do not commit:

```text
.env
secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
install-report.txt
*.tar
*.log
runtime tokens
Telegram credentials
SMS secrets
local kubeconfig files
local SSH keys
node_modules/
.venv/
venv/
dist/
release/
automation/libvirt/build/
automation/ansible/inventory.generated.ini
```

Generated files may be committed only when the repository model expects them to be versioned and they were regenerated from source:

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

---

## Current access naming

The expected current development/test hostnames are:

```text
Portal:  srvotptest26.init-db.lan
Grafana: grafana-srvotptest26.init-db.lan
```

Both normally route through Traefik and MetalLB. The preferred model is internal DNS pointing those names to the Traefik LoadBalancer IP.

Do not document `grafana-test.lan` as the active Grafana host. It is a placeholder/test value only and must not be treated as the current environment source of truth.

---

## Documentation maintenance rules

* Keep `README.md` short and conceptual.
* Keep this file as the documentation index.
* Move detailed procedures to the relevant owner document.
* Do not duplicate large command blocks across multiple documents.
* Keep active hostnames and access examples consistent with `.env.example`, installer summaries, and generated reports.
* Keep SCH alignment notes in architecture docs, not scattered through all files.
* Do not restore old planning directories as active documentation unless they are intentionally refreshed.
* Do not document WhatsApp as the active alerting path unless the feature is intentionally restored.
* Re-run validation after changes to OTP flow, Redis state handling, Kubernetes placement, generated manifests, repo-sync behavior, or observability exposure.

---

