# Build and Development Guide

## Purpose

This guide is the single development/build reference for OTP Relay Kubernetes. It combines the previous Docker image build guide, Dockerfile design notes, frontend source/generated bundle rules, help-doc generation, and Grafana dashboard ConfigMap generation.

## App image

The app image is built from:

```text
k8s/Dockerfile
```

The app image includes:

- Python runtime for FastAPI/Uvicorn.
- Python dependencies from `requirements.txt`.
- Frontend static files.
- Generated production `frontend/app.js` from `frontend/app.jsx`.
- Generated help pages from `docs/help/`.
- Generated Grafana dashboard ConfigMap when the installer/build path runs dashboard generation.

The app runs as a non-root user and starts Uvicorn through Python:

```text
python -m uvicorn main:app
```

This avoids relying on shell PATH details for the `uvicorn` executable.

## Monitor image

The monitor image is built from:

```text
k8s/Dockerfile.monitor
```

The monitor is a required service. It performs phone presence, SMS-path, audit-log, Prometheus metric, and Telegram-alert checks.

Kubernetes deployment requirements:

- `hostNetwork: true`.
- `dnsPolicy: ClusterFirstWithHostNet`.
- `NET_RAW` capability.
- No Service.
- No Ingress.

## Frontend build model

The React source is:

```text
frontend/app.jsx
```

The production build output is:

```text
frontend/app.js
```

The portal serves `frontend/app.js` in production.

Rules:

- Edit `frontend/app.jsx` for frontend behavior changes.
- Rebuild `frontend/app.js` after editing `frontend/app.jsx`.
- Commit both `frontend/app.jsx` and `frontend/app.js` when the generated bundle changes.
- Do not edit `frontend/app.js` directly as source.
- Do not restore browser Babel or `text/babel` as the production model.

This matters for portal behavior such as the RTA wizard overlay, guide iframe rendering, admin UI, OTP screen, and user login flow.

## Help-doc build model

Help source lives under:

```text
docs/help/
docs/help/assets/
```

The build script is:

```text
scripts/build_help_docs.py
```

The generated portal help output is under:

```text
frontend/help/
```

Generated help output includes:

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

`docs/help/` is source material and should stay in the repo. Generated help output should be handled by the build/deploy process according to `.gitignore` and installer behavior.

### Help overlay validation

If an image works in the pop-out guide but not in the portal overlay, check the generated guide assets and the React overlay source:

```bash
find frontend/help -type f | sort | grep -Ei 'png|jpg|jpeg|webp|svg'
grep -R 'new-user-onboarding-sequence.png' -n docs/help frontend/help frontend/app.jsx frontend/guide.html scripts/build_help_docs.py
curl -I http://127.0.0.1:8000/help/assets/new-user-onboarding-sequence.png
curl -I http://127.0.0.1:8000/help/wizard-guide.json
```

The overlay code lives in `frontend/app.jsx`. After fixing it, rebuild `frontend/app.js`.

## Grafana dashboard build model

Grafana dashboard source lives at:

```text
k8s/observability/dashboards/otp-relay-live.json
```

The generator script is:

```text
scripts/build_grafana_dashboard_configmap.py
```

The generated ConfigMap output is:

```text
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Build command:

```bash
python3 scripts/generate_grafana_dashboard_configmap.py
```

Rules:

- Edit `k8s/observability/dashboards/otp-relay-live.json` as the dashboard source of truth.
- Do not hand-edit the generated ConfigMap as the source.
- Regenerate the ConfigMap after dashboard source changes.
- Commit both the source JSON and generated YAML when dashboard changes are made.
- The Grafana UI should not be used as the permanent source of truth.

The generator supports Grafana `dashboard.grafana.app/v2` exports and converts them to classic Grafana dashboard JSON for sidecar provisioning.

The generated dashboard JSON must preserve:

```text
id: null
uid: otp-relay-live
refresh: 15s
timepicker.refresh_intervals
panel type from vizConfig.group
dashboard layout and panel sizing
```

Validation commands:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Manual apply/reload commands:

```bash
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

## Runtime data

Runtime data belongs on the Kubernetes PVC at:

```text
/app/data
```

Do not bake runtime files into the image.

Expected runtime files:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

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

## Local validation commands

Before committing frontend/help/Grafana generated changes, run the relevant checks:

```bash
# Help docs
python3 scripts/build_help_docs.py

# Grafana dashboard ConfigMap
python3 scripts/generate_grafana_dashboard_configmap.py

# Dashboard refresh metadata
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

## Local development notes

- Keep application changes focused and small.
- Do not commit secrets or runtime data.
- Do not commit generated logs or tar images.
- Keep Kubernetes manifests as the deployment source of truth.
- Keep observability manifests under `k8s/observability/`.
- Keep docs under `docs/`; do not recreate `k8s/docs/`.
- Keep frontend source/generated bundle changes together.
- Keep Grafana dashboard source/generated ConfigMap changes together.

## Files not to commit

```text
data/
.env
k8s/manifests/secret.env
*.log
*.tar
```

Generated files such as `frontend/app.js`, `frontend/help/`, and `k8s/observability/grafana-dashboard-otp-relay-live.yaml` may be committed only when the repository's deployment model expects generated artifacts to be versioned. When committed, regenerate them from their source files instead of editing them directly.

## Design notes retained as active rules

- Use multi-stage builds where appropriate.
- Keep containers focused: app container runs the app, not nginx.
- TLS termination belongs to Kubernetes ingress, not inside the app container.
- Run as non-root where possible.
- Keep `/app/data` as a mounted persistent path, not image content.
- Keep Grafana dashboard provisioning source-driven: source JSON → generated ConfigMap → Grafana sidecar.
