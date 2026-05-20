# OTP Relay Kubernetes Documentation

This directory is the single source for project documentation. Kubernetes manifests, Dockerfiles, and observability manifests stay under `k8s/`; explanations, guides, runbooks, validation notes, and help source stay under `docs/`.

## Active documents

| Area | Document | Purpose |
|---|---|---|
| Architecture | [Current Architecture and SCH Gap Analysis](architecture/current-architecture-and-sch-gap-analysis.md) | Current validated topology, SCH target, current gaps, and safe design rules. |
| Deployment | [Deployment and Storage Guide](deployment/deployment-and-storage-guide.md) | GitHub Actions deployment path, storage settings, NFS/RWX migration, observability deployment notes, and manual fallback. |
| Operations | [Operations and Validation Runbook](operations/operations-and-validation-runbook.md) | Health checks, Redis/NFS/TLS/monitor validation, Grafana/Prometheus validation, OTP checks, and useful commands. |
| Observability | [Observability and Grafana Guide](operations/observability-and-grafana.md) | Prometheus, Grafana, Loki/Alloy, ServiceMonitor resources, dashboard source/generated ConfigMap workflow, and validation commands. |
| Development | [Build and Development Guide](development/build-and-development-guide.md) | App/monitor image build model, frontend source/bundle model, help-doc build model, Grafana dashboard ConfigMap generation, and local build commands. |
| User help | [Help Documentation Source](help/) | Markdown and screenshots used by `scripts/build_help_docs.py` to generate portal help pages and wizard guide content. |

## Source-of-truth rules

| Area | Source | Generated output | Build command |
|---|---|---|---|
| Portal frontend | `frontend/app.jsx` | `frontend/app.js` | Installer / frontend build |
| Help docs | `docs/help/*.md`, `docs/help/assets/*` | `frontend/help/*` | `python3 scripts/build_help_docs.py` |
| Grafana dashboard | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml` | `python3 scripts/build_grafana_dashboard_configmap.py` |

## Documentation rules

- Keep active docs compact and current.
- Avoid duplicate Phase 1/2/3 explanations across multiple files.
- Do not restore `docs/k8s-plan.md`, `docs/dev/`, `docs/diagrams/`, or `k8s/docs/`.
- Keep architecture diagrams under `docs/architecture/diagrams/`.
- Keep portal user-help source under `docs/help/`.
- Keep observability explanations under `docs/operations/`.
- Do not use archived or old planning notes as deployment source of truth.
- Do not edit generated files as source. Update the source file, run the matching build/generation command, then commit both source and generated output when required.
