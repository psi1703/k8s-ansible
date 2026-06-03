# OTP Relay Kubernetes Documentation

This directory is the documentation home for OTP Relay Kubernetes.

Kubernetes manifests, Dockerfiles, installer scripts, automation, and observability manifests stay in their functional repo locations such as `k8s/`, `scripts/`, `.github/`, and `automation/`.

Explanations, architecture notes, deployment guides, runbooks, validation notes, and portal help source stay under `docs/`.

---

## Current documentation status

Phase 3 resilience validation completed on **2026-06-03** with no detected blockers.

Validated:

* two app replicas
* real SMS/OTP portal confirmation
* Redis/Sentinel/HAProxy health and Redis master pod deletion recovery
* app, monitor, HAProxy, Sentinel, and Grafana pod restart recovery
* worker drain and uncordon recovery for `otp-worker1` and `otp-worker2`
* NFS/RWX app storage proof across app pods
* Prometheus/Grafana/Loki/Alloy observability recovery

Remaining production-alignment items are tracked in the architecture and operations docs.

---

## Active documents

| Area          | Document                                                                                               | Purpose                                                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture  | [Current Architecture and SCH Gap Analysis](architecture/current-architecture-and-sch-gap-analysis.md) | Current topology, SCH target architecture, production gaps, and safe design rules.                                                            |
| Deployment    | [Deployment and Storage Guide](deployment/deployment-and-storage-guide.md)                             | GitHub Actions deployment path, installer behavior, `.env` model, NFS/RWX storage, Redis deployment safety, and post-deployment verification. |
| Operations    | [Operations and Validation Runbook](operations/operations-and-validation-runbook.md)                   | Daily health checks, Redis/NFS/TLS/monitor validation, OTP checks, worker-drain validation, and SCH sign-off gates.                           |
| Observability | [Observability and Grafana Guide](operations/observability-and-grafana.md)                             | Prometheus, Grafana, Loki/Alloy, ServiceMonitor resources, dashboard source/generated workflow, PromQL guidance, and Grafana troubleshooting. |
| Development   | [Build and Development Guide](development/build-and-development-guide.md)                              | App/monitor image build model, package layout, dependency-change behavior, frontend/help/Grafana generation, and generated artifact rules.    |
| User help     | [Help Documentation Source](help/)                                                                     | Markdown and screenshots used by `scripts/build_help_docs.py` to generate portal help pages and wizard guide content.                         |

---

## Recommended reading order

For SCH review or a new maintainer, read in this order:

1. [Current Architecture and SCH Gap Analysis](architecture/current-architecture-and-sch-gap-analysis.md)
2. [Deployment and Storage Guide](deployment/deployment-and-storage-guide.md)
3. [Operations and Validation Runbook](operations/operations-and-validation-runbook.md)
4. [Observability and Grafana Guide](operations/observability-and-grafana.md)
5. [Build and Development Guide](development/build-and-development-guide.md)

Portal user-facing help source is maintained separately under:

```text id="l9xfgh"
docs/help/
```

---

## Source-of-truth map

| Area                  | Source                                             | Generated output                                               | Build/generation command                               |
| --------------------- | -------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------ |
| Runtime configuration | `.env`                                             | rendered manifests, runtime configuration, and Ansible handoff | installer                                              |
| Portal frontend       | `frontend/app.jsx`                                 | `frontend/app.js`                                              | installer / frontend build                             |
| Help docs             | `docs/help/*.md`, `docs/help/assets/*`             | `frontend/help/*`                                              | `python3 scripts/build_help_docs.py`                   |
| Grafana dashboard     | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml`      | `python3 scripts/build_grafana_dashboard_configmap.py` |

Do not edit generated files as source. Update the source file, run the matching build or generation command, then commit both source and generated output when required by the repository model.

---

## Documentation ownership rules

| Topic                                                                                | Owner document                                                   |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| Architecture and SCH gaps                                                            | `docs/architecture/current-architecture-and-sch-gap-analysis.md` |
| Fresh install, update behavior, `.env`, NFS, Redis deployment safety                 | `docs/deployment/deployment-and-storage-guide.md`                |
| Daily checks, validation commands, OTP testing, worker drain, troubleshooting triage | `docs/operations/operations-and-validation-runbook.md`           |
| Grafana, Prometheus, Loki, Alloy, ServiceMonitor, dashboard generation, PromQL       | `docs/operations/observability-and-grafana.md`                   |
| Python package layout, Docker images, frontend/help/Grafana build model              | `docs/development/build-and-development-guide.md`                |
| Portal user-facing guide content                                                     | `docs/help/`                                                     |

Avoid duplicating detailed procedures across documents. Cross-link to the owner document instead.

---

## Documentation rules

* Keep active docs compact and current.
* Avoid duplicate Phase 1/2/3 explanations across multiple files.
* Do not restore `docs/k8s-plan.md`, `docs/dev/`, `docs/diagrams/`, or `k8s/docs/`.
* Keep architecture diagrams under `docs/architecture/diagrams/`.
* Keep portal user-help source under `docs/help/`.
* Keep observability explanations under `docs/operations/`.
* Do not use archived or old planning notes as deployment source of truth.
* Do not document WhatsApp as the active alerting path unless the feature is intentionally restored.
* Treat the 2026-06-03 multi-replica OTP and worker-drain validation as complete for the current code/configuration baseline.
* Re-run validation after future changes to OTP flow, Redis state handling, frontend polling, Kubernetes placement, or deployment workflow behavior.

---

## Files not to commit

Do not commit runtime or secret-bearing files:

```text id="e2bkgb"
.env
secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
*.tar
*.log
runtime tokens
Telegram credentials
SMS secrets
local kubeconfig files
```

Generated files may be committed only when the repository expects generated artifacts to be versioned, and only after regenerating them from source:

```text id="pe9lpy"
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```
