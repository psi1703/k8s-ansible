# Build and Development Guide

## Purpose

This guide explains how source files become runnable OTP Relay Kubernetes artifacts.

It is for developers and maintainers who need to understand what to edit, what to generate, and what not to commit.

It does not own production deployment, operations, or observability troubleshooting. Those topics live in:

```text
docs/deployment/deployment-and-storage-guide.md
docs/operations/operations-and-validation-runbook.md
docs/operations/observability-and-grafana.md
```

---

## Development layers

The build model is easier to understand as layers.

```text
Source code layer
  otp_relay/
  otp_monitor/
  main.py
  monitor.py

Frontend layer
  frontend/app.jsx
  frontend/app.js
  frontend/index.html
  frontend/guide.html

Help-doc layer
  docs/help/
  scripts/build_help_docs.py
  frontend/help/

Container layer
  requirements.txt
  k8s/Dockerfile
  k8s/Dockerfile.monitor

Kubernetes manifest layer
  k8s/manifests/
  k8s/observability/

Observability-generation layer
  k8s/observability/dashboards/otp-relay-live.json
  scripts/build_grafana_dashboard_configmap.py
  k8s/observability/grafana-dashboard-otp-relay-live.yaml

Runtime data layer
  /app/data on the Kubernetes PVC
```

The core rule is simple: edit source files, regenerate generated files through the intended build path, and never treat generated or runtime files as primary source.

---

## Application source layer

The portal application package is:

```text
otp_relay/
```

Important modules:

| Module | Purpose |
|---|---|
| `otp_relay/routes.py` | App assembly and router registration |
| `otp_relay/config.py` | Runtime configuration |
| `otp_relay/state.py` | Shared in-memory fallback state |
| `otp_relay/storage.py` | JSON/PVC-backed admin and wizard files |
| `otp_relay/users.py` | `users.xlsx` import and validation |
| `otp_relay/redis_state.py` | Redis queue, pending OTP, and admin session state |
| `otp_relay/otp_flow.py` | OTP claim, status, cancel, and SMS receive flow |
| `otp_relay/admin.py` | Admin auth, users, queue, wizard, and diagnostics |
| `otp_relay/audit.py` | Audit log write/read behavior |
| `otp_relay/metrics.py` | Prometheus metrics |
| `otp_relay/frontend.py` | Static frontend mounting and `guide.html` handling |

The top-level app entry remains:

```text
main.py
```

`main.py` should stay thin. App construction and behavior should live in `otp_relay/`.

---

## Monitor source layer

The monitor package is:

```text
otp_monitor/
```

Important modules:

| Module | Purpose |
|---|---|
| `otp_monitor/runner.py` | Monitor launcher and runtime loop |
| `otp_monitor/config.py` | Monitor runtime configuration |
| `otp_monitor/phone.py` | iPhone presence and ARP detection |
| `otp_monitor/alerts.py` | Telegram alert delivery |
| `otp_monitor/audit_tail.py` | Audit-log tailing |
| `otp_monitor/metrics.py` | Prometheus metrics |

The top-level monitor entry remains:

```text
monitor.py
```

`monitor.py` should stay thin. Runtime behavior should live in `otp_monitor/`.

The monitor is a required internal workload. It should not be exposed through a Service or Ingress.

---

## Frontend layer

The React source file is:

```text
frontend/app.jsx
```

The generated production bundle is:

```text
frontend/app.js
```

The portal serves `frontend/app.js` in production.

Rules:

- Edit `frontend/app.jsx` for frontend behavior changes.
- Rebuild `frontend/app.js` after editing `frontend/app.jsx`.
- Do not edit `frontend/app.js` as source.
- Do not restore browser Babel or `text/babel` as the production model.
- If generated frontend artifacts are versioned in the repo, commit source and generated output together.

This matters for:

- OTP user screen
- admin UI
- RTA wizard overlay
- guide iframe rendering
- login flow
- upload/import UI

---

## Help-doc layer

Help source lives under:

```text
docs/help/
docs/help/assets/
```

The build script is:

```text
scripts/build_help_docs.py
```

The generated portal help output is:

```text
frontend/help/
```

Expected generated output includes:

```text
frontend/help/manifest.json
frontend/help/wizard-guide.json
frontend/help/rendered/
frontend/help/assets/
```

Build command:

```bash
python3 scripts/build_help_docs.py
```

Rules:

- `docs/help/` is source.
- `frontend/help/` is generated output.
- Do not hand-edit generated help output as source.
- If the repository versions generated help output, regenerate it from source before committing.
- Repo sync should preserve generated help output; it should not delete it unless the operator intentionally rebuilds it.

---

## App image layer

The app image is built from:

```text
k8s/Dockerfile
```

The app image must include:

- Python runtime
- Python dependencies from `requirements.txt`
- `main.py`
- `otp_relay/`
- frontend static files
- generated production `frontend/app.js`
- generated help output when expected by the deployment path

The app starts Uvicorn through Python:

```text
python -m uvicorn main:app
```

Runtime files must not be baked into the image. They belong on `/app/data`.

---

## Monitor image layer

The monitor image is built from:

```text
k8s/Dockerfile.monitor
```

The monitor image must include:

- Python runtime
- Python dependencies from `requirements.txt`
- `monitor.py`
- `otp_monitor/`

Kubernetes requirements for the monitor:

- `hostNetwork: true`
- `dnsPolicy: ClusterFirstWithHostNet`
- `NET_RAW` capability
- no Service
- no Ingress

The monitor performs:

- iPhone presence checks
- audit-log checks
- Prometheus metric export
- Telegram alert checks

---

## Dependency-change behavior

`requirements.txt` affects both the app and the monitor images.

A change to `requirements.txt` should trigger:

- app image rebuild
- monitor image rebuild
- app rollout
- monitor rollout

Do not classify a `requirements.txt` change as observability-only, documentation-only, or manifest-only.

---

## Kubernetes manifest layer

Application Kubernetes manifests live under:

```text
k8s/manifests/
```

Observability manifests live under:

```text
k8s/observability/
```

Keep this separation:

```text
k8s/manifests/       application runtime
k8s/observability/   Prometheus, Grafana, Loki, Alloy, dashboards
```

Do not recreate a second documentation tree under `k8s/docs/`. Documentation belongs under:

```text
docs/
```

---

## Grafana dashboard generation layer

Grafana dashboard source lives at:

```text
k8s/observability/dashboards/otp-relay-live.json
```

The generator script is:

```text
scripts/build_grafana_dashboard_configmap.py
```

The generated ConfigMap is:

```text
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Build command:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Rules:

- Edit the dashboard JSON as source.
- Do not hand-edit the generated ConfigMap as source.
- Regenerate the ConfigMap after dashboard source changes.
- Commit both source JSON and generated YAML when dashboard changes are versioned.
- The Grafana UI is not the permanent source of truth.
- Provisioned dashboards may not be saveable from the Grafana UI; this is expected.

Grafana access, PromQL, dashboard behavior, and troubleshooting belong in:

```text
docs/operations/observability-and-grafana.md
```

---

## Runtime data layer

Runtime data belongs on the Kubernetes PVC at:

```text
/app/data
```

Expected runtime files include:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

Rules:

- Do not bake runtime data into images.
- Do not commit runtime data.
- Do not commit OTP values.
- Do not write OTP values to image layers, committed files, or generated documentation.
- Keep `/app/data` as a mounted persistent path.

---

## Local build commands

From the repository root:

```bash
docker build -t otp-relay:latest -f k8s/Dockerfile .
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

For K3s without a registry:

```bash
docker save otp-relay:latest -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

Deployment and rollout checks belong in:

```text
docs/deployment/deployment-and-storage-guide.md
docs/operations/operations-and-validation-runbook.md
```

---

## Local generation commands

Run only the generator relevant to the source change.

Help docs:

```bash
python3 scripts/build_help_docs.py
```

Grafana dashboard ConfigMap:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Frontend bundle generation is handled by the frontend build path used by the installer. When frontend source changes, ensure `frontend/app.js` reflects `frontend/app.jsx` before releasing.

---

## Repo-sync and generated files

`scripts/sync-repo.sh` is a repository synchronization tool. It must not deploy, apply manifests, run Helm, restart pods, import images, or mutate Kubernetes.

Repo sync should preserve local runtime and generated artifacts such as:

```text
.env
node_modules/
frontend/help/
frontend/app.js
.sync-state/
dist/
release/
install-report.txt
```

Repo sync may mark that generated help needs rebuilding when help sources change, but it should not delete the generated help output during normal sync.

---

## Files not to commit

Do not commit secrets, runtime data, logs, or image archives.

```text
.env
secret.env
data/
k8s/manifests/secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
*.log
*.tar
```

Generated files may be committed only when the repository's deployment model expects generated artifacts to be versioned:

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

When committed, regenerate them from source instead of editing them directly.

---

## Development rules

- Keep changes focused and small.
- Keep application code in `otp_relay/` and monitor code in `otp_monitor/`.
- Keep `main.py` and `monitor.py` thin.
- Keep Kubernetes manifests as deployment source.
- Keep observability manifests under `k8s/observability/`.
- Keep docs under `docs/`.
- Keep `.env` as the source of operator/site-specific values.
- Do not hardcode phone IP, interface, Telegram token, NFS server, TLS host, Redis URL, storage class, portal host, or Grafana host in application code.
- Keep the monitor internal only.
- Keep Redis required in the validated Kubernetes posture.
- Keep normal Redis updates non-destructive unless an explicit reset path is used.

---

## Build sign-off checklist

Use this checklist before declaring a build/development change complete.

- [ ] App image includes `main.py`.
- [ ] App image includes `otp_relay/`.
- [ ] Monitor image includes `monitor.py`.
- [ ] Monitor image includes `otp_monitor/`.
- [ ] `requirements.txt` changes rebuild both app and monitor images.
- [ ] `frontend/app.js` reflects `frontend/app.jsx`.
- [ ] Help output is generated from `docs/help/`.
- [ ] Grafana dashboard ConfigMap is generated by `scripts/build_grafana_dashboard_configmap.py`.
- [ ] Runtime data is not baked into images.
- [ ] Secrets are not committed.
- [ ] Generated artifacts are either regenerated and committed intentionally, or preserved locally and ignored.
- [ ] Docker images build cleanly when image build is part of the change.
- [ ] K3s image import is tested when manual import is part of the release path.
