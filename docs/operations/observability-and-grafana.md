# Observability and Grafana Guide

## Purpose

This guide is the operational reference for OTP Relay Kubernetes observability.

It covers:

* Prometheus, Grafana, Loki, and Alloy
* ServiceMonitor resources
* OTP Relay portal and monitor metrics
* Grafana dashboard provisioning
* Dashboard source/generated workflow
* Replica-aware PromQL rules
* Grafana access through Traefik/IngressRoute
* Common troubleshooting steps

---

## Observability namespace

Observability resources run in:

```text
observability
```

Core components:

| Component                          | Purpose                                                   |
| ---------------------------------- | --------------------------------------------------------- |
| Prometheus / kube-prometheus-stack | Scrapes portal, monitor, Kubernetes, and platform metrics |
| Grafana                            | Displays the OTP Relay live dashboard                     |
| ServiceMonitor `otp-relay`         | Scrapes portal metrics                                    |
| ServiceMonitor `otp-monitor`       | Scrapes monitor metrics                                   |
| Loki                               | Stores logs when deployed                                 |
| Alloy                              | Collects and forwards logs when deployed                  |
| Grafana dashboard ConfigMap        | Provisions the OTP Relay live dashboard                   |

---

## Normal Grafana access

Grafana should be accessed through Traefik/IngressRoute.

Current browser access path:

```text
https://grafana.init-db.lan
```

Port-forwarding is not the normal Grafana access model. Use port-forwarding only for temporary debugging or when checking Prometheus directly from the control-plane host.

---

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

The dashboard generator is:

```text
scripts/build_grafana_dashboard_configmap.py
```

---

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

* Edit `k8s/observability/dashboards/otp-relay-live.json`.
* Do not hand-edit `k8s/observability/grafana-dashboard-otp-relay-live.yaml` as the source.
* Regenerate the ConfigMap after dashboard source changes.
* Commit both the source JSON and generated YAML when dashboard changes are made.
* The Grafana UI should not be used as the permanent source of truth.
* Provisioned dashboards may not be saveable from the Grafana UI; this is expected.

---

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

---

## Validate generated output

After running the generator:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Expected:

* `"refresh": "15s"` exists.
* `"timepicker"` exists.
* `"refresh_intervals"` exists and includes `15s`.

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

---

## Apply dashboard changes manually

Normally the installer or GitHub Actions applies manifests.

To apply only the dashboard ConfigMap manually:

```bash
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Confirm the live ConfigMap contains the expected dashboard metadata:

```bash
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

---

## Live resource checks

```bash
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability
sudo k3s kubectl get ingressroute -n observability
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability
sudo k3s kubectl get servicemonitor -n observability
```

Expected:

* Grafana pod is Running/Ready.
* Prometheus pod is Running/Ready.
* Loki/Alloy components are Running/Ready when deployed.
* Grafana IngressRoute exists when Grafana browser access is enabled.
* `otp-relay-live-dashboard` exists.
* ServiceMonitor resources exist for `otp-relay` and `otp-monitor`.

---

## Grafana logs

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

Use these logs when a dashboard ConfigMap has been applied but the dashboard does not appear or update in Grafana.

---

## Dashboard metrics

The OTP Relay live dashboard depends on these metrics:

| Metric                                           | Meaning                                                  |
| ------------------------------------------------ | -------------------------------------------------------- |
| `up{job="otp-relay"}`                            | Portal scrape status                                     |
| `up{job="otp-monitor"}`                          | Monitor scrape status                                    |
| `otp_iphone_present`                             | iPhone presence signal from monitor                      |
| `otp_monitor_arp_last_success_timestamp_seconds` | Timestamp of the monitor pod's last successful ARP probe |
| `otp_queue_depth`                                | Number of users waiting behind the active OTP user       |
| `otp_active_user`                                | Whether a user currently holds the active OTP slot       |
| `otp_delivered_total`                            | Delivered OTP counter                                    |
| `otp_claims_total`                               | Claim counter                                            |
| `otp_iphone_absence_events_total`                | iPhone absence event counter                             |

---

## Replica-aware PromQL guidance

Dashboard queries must be safe when more than one portal or monitor pod exists.

For counters, prefer aggregate increase expressions instead of reading a single series.

Examples:

```promql
sum(increase(otp_delivered_total[$__range]))
```

```promql
sum(increase(otp_claims_total[$__range]))
```

For status or current-state gauges, use an aggregate that matches the panel meaning.

Examples:

```promql
max(up{job="otp-relay"})
```

```promql
max(up{job="otp-monitor"})
```

```promql
max(otp_queue_depth)
```

```promql
max(otp_active_user)
```

```promql
max(otp_iphone_present)
```

For node count, use a cluster-level expression rather than a pod-local metric.

Example:

```promql
count(kube_node_info)
```

For Last ARP age, calculate the age from the latest valid timestamp:

```promql
clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)
```

---

## Prometheus query checks

Port-forward Prometheus only when direct Prometheus debugging is needed:

```bash
sudo k3s kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability
```

Query from another shell:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=max(up{job="otp-relay"})'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=max(up{job="otp-monitor"})'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=max(otp_queue_depth)'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=max(otp_active_user)'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=max(otp_iphone_present)'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=clamp_min(time()%20-%20max(otp_monitor_arp_last_success_timestamp_seconds%20%3E%200),%200)'
```

Expected behavior:

* Portal and monitor `up` queries return `1`.
* `otp_queue_depth` shows users waiting behind the active OTP user.
* `otp_active_user` shows whether a user currently holds the OTP slot.
* `otp_iphone_present` reflects monitor phone presence.
* Last ARP is based on `otp_monitor_arp_last_success_timestamp_seconds`, not simply whether the fake iPhone VM process is running.

---

## Dashboard behavior notes

### Queue vs active user

If only one user has claimed the OTP slot, the expected dashboard state can be:

```text
Queue:       0
Active user: IN USE
```

The queue tile represents users waiting behind the currently active OTP user. It does not count the active user as waiting.

### Delivered today

The delivered counter should be queried with a replica-aware counter expression.

Recommended pattern:

```promql
sum(increase(otp_delivered_total[$__range]))
```

Do not depend on one pod's counter series when the portal may run with multiple replicas.

### Last ARP

`Last ARP` is the age of the monitor pod's last successful ARP probe:

```promql
clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)
```

If a fake iPhone VM says `phone up` but Last ARP is stale, check:

* monitor pod connectivity
* `PHONE_IP`
* `PHONE_INTERFACE`
* host networking
* exported ARP timestamp metric
* monitor logs

Do not fix Last ARP by making the dashboard depend on the fake VM process state. The dashboard should reflect the monitor pod's actual observed phone reachability.

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

---

## Troubleshooting

### Grafana URL does not load

Expected URL:

```text
https://grafana.init-db.lan
```

Check IngressRoute and service:

```bash
sudo k3s kubectl get ingressroute -n observability
sudo k3s kubectl get svc -n observability | grep grafana
sudo k3s kubectl get pods -n observability -o wide | grep grafana
```

Check DNS resolution from the client machine:

```bash
nslookup grafana.init-db.lan
```

Check Grafana pod logs:

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
```

### Panels show as mini graphs instead of Stat tiles

Cause: the v2-to-classic conversion did not preserve `vizConfig.group`, so Stat panels were converted as time-series panels.

Fix:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
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
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

### Tile text is cut off

Cause: Stat panel grid size is too small or the value text size is too large.

Fix:

1. Edit:

   ```text
   k8s/observability/dashboards/otp-relay-live.json
   ```

2. Adjust the relevant dashboard layout and Stat text options.

3. Regenerate:

   ```bash
   python3 scripts/build_grafana_dashboard_configmap.py
   ```

4. Apply and restart Grafana:

   ```bash
   sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
   sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
   sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
   ```

### Dashboard changes do not appear

Check the live ConfigMap:

```bash
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | head -c 300
echo
```

Reapply and restart Grafana:

```bash
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Check sidecar logs:

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

### Dashboard cannot be saved from the UI

This is expected for a provisioned dashboard.

Update the source file instead:

```text
k8s/observability/dashboards/otp-relay-live.json
```

Then regenerate:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

### Prometheus shows no data for portal or monitor

Check ServiceMonitor resources:

```bash
sudo k3s kubectl get servicemonitor -n observability
sudo k3s kubectl describe servicemonitor otp-relay -n observability
sudo k3s kubectl describe servicemonitor otp-monitor -n observability
```

Check portal and monitor services/pods:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
```

Check whether `/metrics` is reachable from inside the cluster if needed.

### Intermittent Grafana "No data" on Stat panels

If Prometheus instant queries return valid values but Grafana Stat panels intermittently show "No data", review the panel query mode.

For current-state tiles, instant queries may be more appropriate than range queries. Confirm this against the dashboard source before changing the generated ConfigMap.

---

## Commit checklist

When changing the Grafana dashboard, commit:

```text
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Also commit the generator only when the generator itself changed:

```text
scripts/build_grafana_dashboard_configmap.py
```

Do not commit the old generator name:

```text
scripts/generate_grafana_dashboard_configmap.py
```

unless that file is intentionally restored in the repo.

---

## Quick validation checklist

After observability changes are deployed:

* [ ] `https://grafana.init-db.lan` loads.
* [ ] Grafana pod is Running/Ready.
* [ ] Prometheus pod is Running/Ready.
* [ ] `otp-relay-live-dashboard` ConfigMap exists.
* [ ] Dashboard appears in Grafana.
* [ ] Dashboard refresh is set to 15 seconds.
* [ ] Portal panel shows correct state.
* [ ] Monitor panel shows correct state.
* [ ] Prometheus panel shows correct state.
* [ ] Queue panel returns current queue depth.
* [ ] Active user panel returns current active state.
* [ ] Delivered today uses a replica-aware counter query.
* [ ] iPhone panel reflects monitor phone presence.
* [ ] Last ARP shows a sensible recent value when the phone is reachable.
* [ ] Dashboard survives Grafana pod restart.
