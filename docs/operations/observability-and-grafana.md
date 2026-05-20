# Observability and Grafana Guide

## Purpose

This guide is the operational reference for OTP Relay Kubernetes observability. It covers the Prometheus/Grafana/Loki/Alloy model, ServiceMonitor resources, the OTP Relay live dashboard, and the source-generated workflow for the Grafana dashboard ConfigMap.

## Observability namespace

Observability resources run in:

```text
observability
```

Core components:

| Component | Purpose |
|---|---|
| Prometheus / kube-prometheus-stack | Scrapes portal, monitor, Kubernetes, and platform metrics. |
| Grafana | Displays the OTP Relay live dashboard. |
| ServiceMonitor `otp-relay` | Scrapes portal metrics. |
| ServiceMonitor `otp-monitor` | Scrapes monitor metrics. |
| Loki | Stores logs when deployed. |
| Alloy | Collects and forwards logs when deployed. |
| Grafana dashboard ConfigMap | Provisions the OTP Relay live dashboard. |

## Repository files

Observability manifests live under:

```text
k8s/observability/
```

Important files:

```text
k8s/observability/prometheus-stack-values.yaml
k8s/observability/loki-values.yaml
k8s/observability/alloy-values.yaml
k8s/observability/grafana-ingressroute.yaml
k8s/observability/servicemonitor-otp-relay.yaml
k8s/observability/servicemonitor-otp-monitor.yaml
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

## Dashboard source-generated model

The Grafana dashboard follows a source-generated workflow.

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
ConfigMap: otp-relay-live-dashboard
Namespace: observability
Data key:  otp-relay-live.json
UID:       otp-relay-live
```

Rules:

- Edit `k8s/observability/dashboards/otp-relay-live.json`.
- Do not hand-edit `k8s/observability/grafana-dashboard-otp-relay-live.yaml` as the source.
- Regenerate the ConfigMap after dashboard source changes.
- Commit both the source JSON and generated YAML when dashboard changes are made.
- The Grafana UI should not be used as the permanent source of truth.

## Generate the dashboard ConfigMap

From the repo root:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

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

## Validate generated output

After running the generator:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Expected:

- `"refresh": "15s"` exists.
- `"timepicker"` exists.
- `"refresh_intervals"` exists and includes `15s`.

Confirm the generated ConfigMap embeds classic Grafana JSON, not the v2 wrapper:

```bash
python3 - <<'PY'
import json
import yaml
from pathlib import Path

cm = yaml.safe_load(Path("k8s/observability/grafana-dashboard-otp-relay-live.yaml").read_text())
dash = json.loads(cm["data"]["otp-relay-live.json"])

errors = []

if dash.get("apiVersion"):
    errors.append("generated dashboard still has apiVersion")
if dash.get("kind") == "Dashboard":
    errors.append("generated dashboard still has kind=Dashboard")
if dash.get("id") is not None:
    errors.append("dashboard id is not null")
if dash.get("uid") != "otp-relay-live":
    errors.append(f"dashboard uid is wrong: {dash.get('uid')!r}")
if dash.get("refresh") != "15s":
    errors.append(f"dashboard refresh is wrong: {dash.get('refresh')!r}")

intervals = dash.get("timepicker", {}).get("refresh_intervals", [])
if "15s" not in intervals:
    errors.append(f"15s missing from refresh intervals: {intervals}")

stat_titles = {
    "📱 iPhone",
    "🚪 Portal",
    "📥 Queue",
    "👤 Active user",
    "✉️ Delivered today",
    "👁️ Monitor",
    "🎛️ Nodes",
    "📊 Prometheus",
    "⏰ Last ARP",
}

by_title = {panel.get("title"): panel for panel in dash.get("panels", [])}
for title in stat_titles:
    panel = by_title.get(title)
    if not panel:
        errors.append(f"missing panel: {title}")
        continue
    if panel.get("type") != "stat":
        errors.append(f"{title} is {panel.get('type')!r}, expected stat")
    if panel.get("options", {}).get("graphMode") != "none":
        errors.append(f"{title} graphMode is not none")

if errors:
    print("VALIDATION FAILED")
    for error in errors:
        print(" -", error)
    raise SystemExit(1)

print("VALIDATION PASSED")
PY
```

## Apply dashboard changes manually

Normally the installer or GitHub Actions applies manifests. To apply only the dashboard ConfigMap manually:

```bash
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Confirm the live ConfigMap contains the expected dashboard metadata:

```bash
kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

## Live resource checks

```bash
kubectl get pods -n observability -o wide
kubectl get svc -n observability
kubectl get configmap otp-relay-live-dashboard -n observability
kubectl get servicemonitor -n observability
```

Expected:

- Grafana pod is Running/Ready.
- Prometheus pod is Running/Ready.
- Loki/Alloy components are Running/Ready when deployed.
- `otp-relay-live-dashboard` exists.
- ServiceMonitor resources exist for `otp-relay` and `otp-monitor`.

## Grafana logs

```bash
kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

Use these logs when a dashboard ConfigMap has been applied but the dashboard does not appear or update in Grafana.

## Dashboard metrics

The OTP Relay live dashboard depends on these metrics:

| Metric | Meaning |
|---|---|
| `up{job="otp-relay"}` | Portal scrape status. |
| `up{job="otp-monitor"}` | Monitor scrape status. |
| `otp_iphone_present` | iPhone presence signal from monitor. |
| `otp_monitor_arp_last_success_timestamp_seconds` | Timestamp of the monitor pod's last successful ARP probe. |
| `otp_queue_depth` | Number of users waiting behind the active OTP user. |
| `otp_active_user` | Whether a user currently holds the active OTP slot. |
| `otp_delivered_total` | Delivered OTP counter. |
| `otp_claims_total` | Claim counter. |
| `otp_iphone_absence_events_total` | iPhone absence event counter. |

## Prometheus query checks

Port-forward Prometheus:

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability
```

Query from another shell:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up{job="otp-relay"}'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up{job="otp-monitor"}'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_queue_depth'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_active_user'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_iphone_present'
```

Expected behavior:

- Portal and monitor `up` queries return `1`.
- `otp_queue_depth` shows users waiting behind the active OTP user.
- `otp_active_user` shows whether a user currently holds the OTP slot.
- `otp_iphone_present` reflects monitor phone presence.
- Last ARP is based on `otp_monitor_arp_last_success_timestamp_seconds`, not simply whether the fake iPhone VM process is running.

## Dashboard behavior notes

### Queue vs active user

If only one user has claimed the OTP slot, the expected dashboard state can be:

```text
Queue:       0
Active user: IN USE
```

The queue tile represents users waiting behind the currently active OTP user. It does not count the active user as waiting.

### Last ARP

`Last ARP` is the age of the monitor pod's last successful ARP probe:

```promql
clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)
```

If a fake iPhone VM says `phone up` but Last ARP is stale, check monitor connectivity, phone IP/interface configuration, and the exported ARP timestamp metric before changing the dashboard.

### Dashboard refresh

The provisioned dashboard should include:

```json
"refresh": "15s"
```

and:

```json
"timepicker": {
  "refresh_intervals": [
    "5s",
    "10s",
    "15s"
  ]
}
```

If the dashboard does not update automatically, first verify the live ConfigMap contains both fields.

## Troubleshooting

### Panels show as mini graphs instead of Stat tiles

Cause: the v2-to-classic conversion did not preserve `vizConfig.group`, so Stat panels were converted as time-series panels.

Fix:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
```

Then verify the generated dashboard panels use `"type": "stat"`.

### Auto-refresh is missing from the UI

Cause: the generated dashboard has `"refresh": "15s"` but is missing `timepicker.refresh_intervals`.

Fix:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
```

### Tile text is cut off

Cause: Stat panel grid size is too small or the value text size is too large.

Fix: edit `k8s/observability/dashboards/otp-relay-live.json`, adjust `layout.spec.items[*].spec.width`, `height`, and panel `vizConfig.spec.options.text.valueSize`, then regenerate the ConfigMap.

### Dashboard changes do not appear

Check the live ConfigMap:

```bash
kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | head -c 300
echo
```

Reapply and restart Grafana:

```bash
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

### Dashboard cannot be saved from the UI

This is expected for a provisioned dashboard. Update the source file instead:

```text
k8s/observability/dashboards/otp-relay-live.json
```

Then regenerate:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

## Commit checklist

When changing the Grafana dashboard, commit:

```text
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
scripts/generate_grafana_dashboard_configmap.py
```

Only include `scripts/build_grafana_dashboard_configmap.py` when the generator itself changed.
