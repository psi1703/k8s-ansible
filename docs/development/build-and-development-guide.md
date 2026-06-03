# Build and Development Guide

## Purpose

This guide is the development and build reference for OTP Relay Kubernetes.

It covers:

* app and monitor image build rules
* modularized Python package layout
* frontend source/generated bundle model
* help-doc generation
* Grafana dashboard ConfigMap generation
* runtime data rules
* local validation commands
* dependency-change behavior
* generated artifact rules

---

## Application package layout

The portal application is organized under:

```text id="uh7mjh"
otp_relay/
```

Important modules:

| Module                     | Purpose                                           |
| -------------------------- | ------------------------------------------------- |
| `otp_relay/routes.py`      | App assembly and router registration              |
| `otp_relay/config.py`      | Runtime configuration                             |
| `otp_relay/state.py`       | Shared in-memory fallback state                   |
| `otp_relay/storage.py`     | JSON/PVC-backed admin and wizard files            |
| `otp_relay/users.py`       | `users.xlsx` import and validation                |
| `otp_relay/redis_state.py` | Redis queue, pending OTP, and admin session state |
| `otp_relay/otp_flow.py`    | OTP claim, status, cancel, and SMS receive flow   |
| `otp_relay/admin.py`       | Admin auth, users, queue, wizard, and diagnostics |
| `otp_relay/audit.py`       | Audit log write/read behavior                     |
| `otp_relay/metrics.py`     | Prometheus metrics                                |
| `otp_relay/frontend.py`    | Static frontend mounting and `guide.html`         |

The top-level app entry remains:

```text id="mz4ygo"
main.py
```

`main.py` should stay thin and delegate app construction to the modular package.

---

## Monitor package layout

The monitor is organized under:

```text id="cxw1zz"
otp_monitor/
```

Important modules:

| Module                      | Purpose                           |
| --------------------------- | --------------------------------- |
| `otp_monitor/runner.py`     | Monitor launcher/runtime loop     |
| `otp_monitor/config.py`     | Monitor runtime configuration     |
| `otp_monitor/phone.py`      | iPhone presence and ARP detection |
| `otp_monitor/alerts.py`     | Telegram alerts                   |
| `otp_monitor/audit_tail.py` | Audit-log tailing                 |
| `otp_monitor/metrics.py`    | Prometheus metrics                |

The top-level monitor entry remains:

```text id="8g6f3r"
monitor.py
```

`monitor.py` should stay thin and delegate runtime behavior to the modular package.

---

## App image

The app image is built from:

```text id="5gzm3u"
k8s/Dockerfile
```

The app image includes:

* Python runtime for FastAPI/Uvicorn
* Python dependencies from `requirements.txt`
* `main.py`
* `otp_relay/`
* frontend static files
* generated production `frontend/app.js` from `frontend/app.jsx`
* generated help pages from `docs/help/`

The app starts Uvicorn through Python:

```text id="n1ih5l"
python -m uvicorn main:app
```

This avoids relying on shell `PATH` details for the `uvicorn` executable.

The app should run as non-root where possible and use `/app/data` as a mounted persistent path, not image content.

---

## Monitor image

The monitor image is built from:

```text id="lrqbli"
k8s/Dockerfile.monitor
```

The monitor image includes:

* Python runtime
* Python dependencies from `requirements.txt`
* `monitor.py`
* `otp_monitor/`

The monitor is a required service. It performs:

* phone presence checks
* SMS-path checks
* audit-log checks
* Prometheus metric export
* Telegram alert checks

Kubernetes deployment requirements:

* `hostNetwork: true`
* `dnsPolicy: ClusterFirstWithHostNet`
* `NET_RAW` capability
* no Service
* no Ingress

---

## Dependency-change behavior

`requirements.txt` affects both the app and the monitor images.

A change to `requirements.txt` should trigger:

* app image rebuild
* monitor image rebuild
* app rollout
* monitor rollout

Do not classify a `requirements.txt` change as observability-only or manifest-only.

---

## Frontend build model

The React source is:

```text id="6b1xt9"
frontend/app.jsx
```

The production build output is:

```text id="o3c35k"
frontend/app.js
```

The portal serves `frontend/app.js` in production.

Rules:

* Edit `frontend/app.jsx` for frontend behavior changes.
* Rebuild `frontend/app.js` after editing `frontend/app.jsx`.
* Commit both `frontend/app.jsx` and `frontend/app.js` when the generated bundle changes.
* Do not edit `frontend/app.js` directly as source.
* Do not restore browser Babel or `text/babel` as the production model.

This matters for portal behavior such as:

* RTA wizard overlay
* guide iframe rendering
* admin UI
* OTP screen
* user login flow

---

## Help-doc build model

Help source lives under:

```text id="l6jzzx"
docs/help/
docs/help/assets/
```

The build script is:

```text id="98lnrw"
scripts/build_help_docs.py
```

The generated portal help output is under:

```text id="pn0cy0"
frontend/help/
```

Generated help output includes:

```text id="3u97li"
frontend/help/manifest.json
frontend/help/wizard-guide.json
frontend/help/rendered/
frontend/help/assets/
```

Build command:

```bash id="dg0yx1"
python3 scripts/build_help_docs.py
```

`docs/help/` is source material and should stay in the repo.

Generated help output should be handled by the build/deploy process according to `.gitignore` and installer behavior. If the repository intentionally versions generated help output, regenerate it from source before committing.

---

## Help overlay validation

If an image works in the pop-out guide but not in the portal overlay, check the generated guide assets and the React overlay source:

```bash id="7gx3sp"
find frontend/help -type f | sort | grep -Ei 'png|jpg|jpeg|webp|svg'
grep -R 'new-user-onboarding-sequence.png' -n docs/help frontend/help frontend/app.jsx frontend/guide.html scripts/build_help_docs.py
curl -I http://127.0.0.1:8000/help/assets/new-user-onboarding-sequence.png
curl -I http://127.0.0.1:8000/help/wizard-guide.json
```

The overlay code lives in:

```text id="26xbok"
frontend/app.jsx
```

After fixing it, rebuild:

```text id="k32tz9"
frontend/app.js
```

---

## Grafana dashboard build model

Grafana dashboard source lives at:

```text id="c6j1gj"
k8s/observability/dashboards/otp-relay-live.json
```

The generator script is:

```text id="9kumw7"
scripts/build_grafana_dashboard_configmap.py
```

The generated ConfigMap output is:

```text id="hwpswr"
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Build command:

```bash id="9nam8k"
python3 scripts/build_grafana_dashboard_configmap.py
```

Rules:

* Edit `k8s/observability/dashboards/otp-relay-live.json` as the dashboard source of truth.
* Do not hand-edit the generated ConfigMap as the source.
* Regenerate the ConfigMap after dashboard source changes.
* Commit both the source JSON and generated YAML when dashboard changes are made.
* The Grafana UI should not be used as the permanent source of truth.
* Provisioned dashboards may not be saveable from Grafana UI; this is expected.

The generator supports Grafana `dashboard.grafana.app/v2` exports and converts them to classic Grafana dashboard JSON for sidecar provisioning.

The generated dashboard JSON must preserve:

```text id="epuwfh"
id: null
uid: otp-relay-live
refresh: 15s
timepicker.refresh_intervals
panel type from vizConfig.group
dashboard layout and panel sizing
```

Validation commands:

```bash id="dcqfca"
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Manual apply/reload commands:

```bash id="83paua"
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Normal Grafana browser access:

```text id="ch1bmy"
https://grafana.init-db.lan
```

---

## Runtime data

Runtime data belongs on the Kubernetes PVC at:

```text id="pk4d61"
/app/data
```

Do not bake runtime files into the image.

Expected runtime files:

```text id="bk7pyv"
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

OTP values must not be written to runtime files, image layers, logs, or committed files.

---

## Local build commands

From the repository root:

```bash id="1yk3oi"
docker build -t otp-relay:latest -f k8s/Dockerfile .
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

For K3s without a registry:

```bash id="7cflwy"
docker save otp-relay:latest -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

Restart workloads:

```bash id="s3t1ja"
sudo k3s kubectl rollout restart deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout restart deployment/otp-monitor -n otp-relay
sudo k3s kubectl rollout status deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout status deployment/otp-monitor -n otp-relay
```

---

## Local validation commands

Before committing frontend/help/Grafana generated changes, run the relevant checks.

Help docs:

```bash id="vrixdv"
python3 scripts/build_help_docs.py
```

Grafana dashboard ConfigMap:

```bash id="lv9m7g"
python3 scripts/build_grafana_dashboard_configmap.py
```

Dashboard refresh metadata:

```bash id="lhgk0x"
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Docker image builds:

```bash id="bqnzfw"
docker build -t otp-relay:latest -f k8s/Dockerfile .
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

Basic Kubernetes rollout checks after deployment:

```bash id="g08041"
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl rollout status deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout status deployment/otp-monitor -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

---

## Development workflow notes

* Keep application changes focused and small.
* Do not commit secrets or runtime data.
* Do not commit generated logs or tar images.
* Keep Kubernetes manifests as deployment source.
* Keep observability manifests under `k8s/observability/`.
* Keep docs under `docs/`; do not recreate `k8s/docs/`.
* Keep frontend source/generated bundle changes together.
* Keep Grafana dashboard source/generated ConfigMap changes together.
* Keep `.env` as the source of operator/site-specific values.
* Do not hardcode phone IP, interface, Telegram token, NFS server, TLS host, Redis URL, or storage class in code.
* Keep monitor internal only; do not add Service or Ingress for it.

---

## Files not to commit

```text id="dscg6p"
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

Generated files such as these may be committed only when the repository's deployment model expects generated artifacts to be versioned:

```text id="vybnqm"
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

When committed, regenerate them from their source files instead of editing them directly.

---

## Design notes retained as active rules

* Use multi-stage builds where appropriate.
* Keep containers focused: app container runs the app, not nginx.
* TLS termination belongs to Kubernetes ingress, not inside the app container.
* Run as non-root where possible.
* Keep `/app/data` as a mounted persistent path, not image content.
* Keep Grafana dashboard provisioning source-driven: source JSON -> generated ConfigMap -> Grafana sidecar.
* Keep the monitor as a required internal workload.
* Keep Redis as required in the validated Kubernetes posture.
* Keep normal Redis updates non-destructive unless an explicit reset path is used.

---

## Build sign-off checklist

* [ ] App image includes `main.py`.
* [ ] App image includes `otp_relay/`.
* [ ] Monitor image includes `monitor.py`.
* [ ] Monitor image includes `otp_monitor/`.
* [ ] `requirements.txt` changes trigger app and monitor rebuilds.
* [ ] `frontend/app.js` is generated from `frontend/app.jsx`.
* [ ] Help output is generated from `docs/help/`.
* [ ] Grafana dashboard ConfigMap is generated by `scripts/build_grafana_dashboard_configmap.py`.
* [ ] Dashboard generated YAML contains `refresh: 15s`.
* [ ] Dashboard generated YAML contains `timepicker.refresh_intervals`.
* [ ] Runtime data is not baked into images.
* [ ] Secrets are not committed.
* [ ] Docker images build cleanly.
* [ ] K3s imports images successfully when manual import is used.
