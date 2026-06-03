# OTP Relay Kubernetes Documentation

This directory is the single source for project documentation.

Kubernetes manifests, Dockerfiles, and observability manifests stay under `k8s/`.

Explanations, architecture notes, deployment guides, runbooks, validation notes, and portal help source stay under `docs/`.

---

## Active documents

| Area          | Document                                                                                               | Purpose                                                                                                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture  | [Current Architecture and SCH Gap Analysis](architecture/current-architecture-and-sch-gap-analysis.md) | Current topology, SCH target, current gaps, Redis/NFS/observability model, and safe design rules.                                                                                                        |
| Deployment    | [Deployment and Storage Guide](deployment/deployment-and-storage-guide.md)                             | GitHub Actions deployment path, `.env` configuration model, storage settings, NFS/RWX migration, Redis update safety, observability deployment notes, and manual fallback.                               |
| Operations    | [Operations and Validation Runbook](operations/operations-and-validation-runbook.md)                   | Health checks, Redis/NFS/TLS/monitor validation, Grafana/Prometheus validation, OTP checks, worker-drain checklist, and useful commands.                                                                 |
| Observability | [Observability and Grafana Guide](operations/observability-and-grafana.md)                             | Prometheus, Grafana, Loki/Alloy, ServiceMonitor resources, dashboard source/generated ConfigMap workflow, Grafana access, PromQL guidance, and validation commands.                                      |
| Development   | [Build and Development Guide](development/build-and-development-guide.md)                              | App/monitor image build model, modular package layout, dependency-change behavior, frontend source/bundle model, help-doc build model, Grafana dashboard ConfigMap generation, and local build commands. |
| User help     | [Help Documentation Source](help/)                                                                     | Markdown and screenshots used by `scripts/build_help_docs.py` to generate portal help pages and wizard guide content.                                                                                    |

---

## Source-of-truth rules

| Area                  | Source                                             | Generated output                                               | Build/generation command                               |
| --------------------- | -------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------ |
| Runtime configuration | `.env`                                             | rendered manifests, runtime configuration, and Ansible handoff | installer                                              |
| Portal frontend       | `frontend/app.jsx`                                 | `frontend/app.js`                                              | installer / frontend build                             |
| Help docs             | `docs/help/*.md`, `docs/help/assets/*`             | `frontend/help/*`                                              | `python3 scripts/build_help_docs.py`                   |
| Grafana dashboard     | `k8s/observability/dashboards/otp-relay-live.json` | `k8s/observability/grafana-dashboard-otp-relay-live.yaml`      | `python3 scripts/build_grafana_dashboard_configmap.py` |

---

## Runtime configuration rule

The repository root `.env` file is the source of operator-provided deployment values.

Site-specific values such as TLS host, portal URL, phone IP, phone interface, Telegram credentials, SMS secret, Redis URL, NFS server, storage class, service type, ingress settings, MetalLB settings, replica count, and node placement settings belong in `.env`.

Do not hardcode site-specific values in:

```text
Python files
shell scripts
Kubernetes YAML
Ansible tasks
documentation examples
```

Fresh installs may create `.env` interactively.

Normal updates must load the existing `.env` and must not overwrite it silently.

---

## Active access paths

Current portal access pattern:

```text
https://srvotptest26.init-db.lan
```

Current Grafana access pattern:

```text
https://grafana.init-db.lan
```

Grafana should normally be accessed through Traefik/IngressRoute. Port-forwarding is only for temporary debugging.

---

## Redis safety rule

Redis is required in the current Kubernetes validation posture.

Current app Redis URL:

```text
redis://otp-redis-haproxy:6379/0
```

Redis runs through:

```text
Redis StatefulSet
Redis Sentinel
Redis HAProxy
```

Normal updates must not destructively recreate Redis StatefulSet or Redis PVC resources.

If Kubernetes reports a Redis StatefulSet immutable-field error, treat it as a controlled maintenance issue, not a normal rollout restart issue.

Normal update behavior should be one of:

1. preserve the existing StatefulSet and continue with a clear warning,
2. fail clearly and require explicit maintenance action, or
3. run a documented destructive Redis reset path only when intentionally requested.

---

## Documentation rules

* Keep active docs compact and current.
* Avoid duplicate Phase 1/2/3 explanations across multiple files.
* Do not restore `docs/k8s-plan.md`, `docs/dev/`, `docs/diagrams/`, or `k8s/docs/`.
* Keep architecture diagrams under `docs/architecture/diagrams/`.
* Keep portal user-help source under `docs/help/`.
* Keep observability explanations under `docs/operations/`.
* Do not use archived or old planning notes as deployment source of truth.
* Do not edit generated files as source.
* Update the source file, run the matching build/generation command, then commit both source and generated output when required.
* Do not document WhatsApp as the active alerting path unless the feature is intentionally restored. Telegram is the current monitor alerting path.
* Keep multi-replica OTP and worker-drain status conservative until validation is complete.

---

## Files not to commit

Do not commit runtime or secret-bearing files:

```text
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

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

---

## Recommended reading order

For a new reviewer or SCH review, read in this order:

1. [Current Architecture and SCH Gap Analysis](architecture/current-architecture-and-sch-gap-analysis.md)
2. [Deployment and Storage Guide](deployment/deployment-and-storage-guide.md)
3. [Operations and Validation Runbook](operations/operations-and-validation-runbook.md)
4. [Observability and Grafana Guide](operations/observability-and-grafana.md)
5. [Build and Development Guide](development/build-and-development-guide.md)

Portal user-facing help source is maintained separately under:

```text
docs/help/
```
