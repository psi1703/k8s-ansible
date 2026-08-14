# Observability and Grafana

## Purpose

This document explains the observability layer for the OTP Relay Kubernetes environment.

It covers:

- Prometheus, Grafana, Loki, and Alloy roles
- OTP Relay portal and monitor metrics
- ServiceMonitor validation
- Grafana dashboard source and generated files
- Grafana access through Traefik
- Dashboard troubleshooting

General cluster operations belong in:

```text
docs/operations/operations-and-validation-runbook.md
```

Deployment and storage details belong in:

```text
docs/deployment/deployment-and-storage-guide.md
```

Build and generated artifact rules belong in:

```text
docs/development/build-and-development-guide.md
```

---

## Layer summary

Observability is a separate operational layer above the OTP Relay application and Kubernetes runtime.

```text
OTP Relay app and monitor
  -> expose /metrics
  -> scraped by Prometheus through ServiceMonitors
  -> displayed in Grafana dashboards
  -> logs collected by Alloy and stored in Loki when enabled
```

The observability layer must not own the OTP Relay runtime state. It observes the system; it does not replace Redis, PVC storage, the monitor, or the portal readiness checks.

---

## Namespace

Observability resources run in:

```text
observability
```

Core components:

| Component | Purpose |
|---|---|
| Prometheus / kube-prometheus-stack | Scrapes OTP Relay, monitor, Kubernetes, and platform metrics |
| Grafana | Displays the OTP Relay live dashboard |
| ServiceMonitor `otp-relay` | Scrapes portal metrics |
| ServiceMonitor `otp-monitor` | Scrapes monitor metrics |
| Loki | Stores logs when deployed |
| Alloy | Collects and forwards logs when deployed |
| Grafana dashboard ConfigMap | Provisions the OTP Relay live dashboard |

---

## Normal Grafana access model

The preferred access model is Traefik Ingress with an internal DNS hostname.

Current test-cluster hostname:

```text
grafana-srvotptest26.init-db.lan
```

Current shared Traefik / MetalLB IP:

```text
172.31.11.121
```

Expected DNS record:

```text
grafana-srvotptest26.init-db.lan  A  172.31.11.121
```

Expected browser URL when DNS exists:

```text
http://grafana-srvotptest26.init-db.lan/
```

If TLS is enabled later, the URL may become:

```text
https://grafana-srvotptest26.init-db.lan/
```

Do not use `grafana-test.lan` as the active hostname. It is not the current environment hostname.

Do not expect bare-IP access to route to Grafana when Grafana is exposed by host-based Ingress. Bare IP access has no Grafana Host header and may route to the default portal Ingress instead.

Example:

```text
http://172.31.11.121/                    -> portal/default route
http://grafana-srvotptest26.init-db.lan/ -> Grafana route
```

---

## Optional direct-IP Grafana access

If DNS is not available and Windows hosts-file changes are not acceptable, Grafana can be exposed through a separate MetalLB LoadBalancer IP.

Example:

```text
Portal Traefik IP:       172.31.11.121
Grafana direct IP:       172.31.11.122
```

This is a practical dev/test access mode, not the preferred SCH-style production model.

Rules for this mode:

- Use only a free IP from the configured MetalLB range.
- Check ping and ARP/neighbor state before assigning the IP.
- Do not replace the main Traefik portal IP.
- Document the selected Grafana IP in `.env` and install summary output.
- Keep DNS/Ingress as the preferred production path.

Suggested environment keys if this is added repo-wide:

```text
GRAFANA_EXPOSURE_MODE=ingress
GRAFANA_LOADBALANCER_IP=
```

Valid future values:

```text
ingress
loadbalancer
```

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
k8s/observability/grafana-ingress.yaml
k8s/observability/servicemonitor-otp-relay.yaml
k8s/observability/servicemonitor-otp-monitor.yaml
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

The dashboard generator is:

```text
scripts/build_grafana_dashboard_configmap.py
```

Source/generated rule:

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
ConfigMap: otp-relay-live-dashboard
Namespace: observability
Data key:  otp-relay-live.json
UID:       otp-relay-live
```

Edit the source JSON. Do not hand-edit the generated dashboard ConfigMap as the source of truth.

---

## Dashboard generation workflow

From the repo root:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Commit both files when the dashboard changes:

```text
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

The Grafana UI should not be used as the permanent source of truth. Provisioned dashboards may not be saveable from the Grafana UI; that is expected.

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

## Validate generated dashboard output

After running the generator:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Expected:

```text
"refresh": "15s"
"timepicker"
"refresh_intervals" includes 15s
```

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

Normally the installer applies manifests after the local checkout is synchronized from GitHub.

The repo-sync script itself is sync-only. It must not apply manifests, run Helm, restart deployments, or mutate the cluster.

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

## Live health checks

Check observability pods and services:

```bash
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability
sudo k3s kubectl get ingress -n observability -o wide
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability
sudo k3s kubectl get servicemonitor -n observability
```

Expected:

- Grafana pod is Running/Ready.
- Prometheus pod is Running/Ready.
- Loki and Alloy components are Running/Ready when deployed.
- Grafana Ingress exists when browser access is enabled.
- `otp-relay-live-dashboard` exists.
- ServiceMonitor resources exist for `otp-relay` and `otp-monitor`.

Check Grafana logs:

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

---

## Grafana access checks

Check the live Ingress:

```bash
sudo k3s kubectl -n observability get ingress -o wide
```

Expected example:

```text
NAME      CLASS     HOSTS                              ADDRESS         PORTS
grafana   traefik   grafana-srvotptest26.init-db.lan   172.31.11.121   80
```

Check the Grafana service:

```bash
sudo k3s kubectl -n observability get svc kube-prometheus-stack-grafana -o wide
```

Check Grafana pod readiness:

```bash
sudo k3s kubectl -n observability get pods -l app.kubernetes.io/name=grafana -o wide
```

Check Traefik LoadBalancer:

```bash
sudo k3s kubectl -n kube-system get svc traefik -o wide
```

Test from the Debian control-plane host using the required Host header:

```bash
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Expected:

```text
HTTP/1.1 302 Found
Location: /login
```

If that works, Kubernetes routing is healthy. Remaining browser access failures are DNS/client-side access problems, not Grafana pod problems.

From Windows PowerShell:

```powershell
nslookup grafana-srvotptest26.init-db.lan
Test-NetConnection 172.31.11.121 -Port 80
curl.exe -v --noproxy "*" -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Interpretation:

```text
nslookup fails:
  DNS record is missing.

Test-NetConnection fails:
  Client cannot reach Traefik/MetalLB on the selected IP.

curl with Host header works, browser hostname fails:
  DNS or browser/client resolution is the issue.

Debian Host-header curl fails:
  Check Ingress, service, pod, or Traefik.
```

---

## Metrics used by the dashboard

| Metric | Meaning |
|---|---|
| `up{job="otp-relay"}` | Portal scrape status |
| `up{job="otp-monitor"}` | Monitor scrape status |
| `otp_iphone_present` | iPhone presence signal from monitor |
| `otp_monitor_arp_last_success_timestamp_seconds` | Timestamp of monitor pod's last successful ARP probe |
| `otp_queue_depth` | Number of users waiting behind the active OTP user |
| `otp_active_user` | Whether a user currently holds the active OTP slot |
| `otp_delivered_total` | Delivered OTP counter |
| `otp_claims_total` | Claim counter |
| `otp_iphone_absence_events_total` | iPhone absence event counter |

---

## Replica-aware PromQL guidance

Dashboard queries must be safe when more than one portal or monitor pod exists.

For counters, use aggregate increase expressions:

```promql
sum(increase(otp_delivered_total[$__range]))
```

```promql
sum(increase(otp_claims_total[$__range]))
```

For current-state gauges, use an aggregate that matches the panel meaning:

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

For node count:

```promql
count(kube_node_info)
```

For Last ARP age:

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

Expected:

- Portal and monitor `up` queries return `1`.
- `otp_queue_depth` shows users waiting behind the active OTP user.
- `otp_active_user` shows whether a user currently holds the OTP slot.
- `otp_iphone_present` reflects monitor phone presence.
- Last ARP reflects monitor-observed reachability, not fake VM process state.

---

## Dashboard behavior notes

### Queue versus active user

If only one user has claimed the OTP slot, this is normal:

```text
Queue:       0
Active user: IN USE
```

The queue tile represents users waiting behind the active OTP user. It does not count the active user as waiting.

### Delivered today

Use a replica-aware counter expression:

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

- monitor pod connectivity
- `PHONE_IP`
- `PHONE_INTERFACE`
- host networking
- exported ARP timestamp metric
- monitor logs

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

First confirm the expected URL:

```text
http://grafana-srvotptest26.init-db.lan/
```

Then check the cluster route:

```bash
sudo k3s kubectl -n observability get ingress -o wide
sudo k3s kubectl -n observability get svc kube-prometheus-stack-grafana -o wide
sudo k3s kubectl -n observability get pods -l app.kubernetes.io/name=grafana -o wide
sudo k3s kubectl -n kube-system get svc traefik -o wide
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

If the Host-header curl returns `302 Found` and `Location: /login`, Grafana routing is healthy.

Then check DNS from the client:

```bash
nslookup grafana-srvotptest26.init-db.lan
```

If DNS is missing, request this internal record:

```text
grafana-srvotptest26.init-db.lan  A  172.31.11.121
```

### Bare IP opens the portal instead of Grafana

This is expected with host-based Ingress.

```text
http://172.31.11.121/                    -> portal/default route
http://grafana-srvotptest26.init-db.lan/ -> Grafana route
```

Use DNS or the optional dedicated Grafana LoadBalancer IP mode.

### Panels show as mini graphs instead of Stat tiles

Cause: the v2-to-classic conversion did not preserve `vizConfig.group`, so Stat panels were converted as time-series panels.

Fix:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Then verify generated dashboard panels use:

```text
"type": "stat"
```

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

Edit the dashboard source:

```text
k8s/observability/dashboards/otp-relay-live.json
```

Adjust panel layout and Stat text options, then regenerate:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Apply and restart Grafana:

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

If Prometheus instant queries return valid values but Grafana Stat panels intermittently show `No data`, review the panel query mode.

For current-state Stat panels, instant query mode is usually more stable than range mode.

Recommended current-state expressions:

```promql
max(otp_queue_depth)
max(otp_active_user)
max(otp_iphone_present)
max(up{job="otp-relay"})
max(up{job="otp-monitor"})
```

Counter panels should stay range-aware:

```promql
sum(increase(otp_delivered_total[$__range]))
```

---

## Summary

The observability layer is healthy when:

- Grafana pod is Ready.
- Prometheus is scraping portal and monitor metrics.
- ServiceMonitors exist for `otp-relay` and `otp-monitor`.
- The dashboard ConfigMap is generated from source JSON.
- Grafana access works through the configured Ingress hostname.
- Dashboard queries are replica-aware.
- Logs are available through Loki/Alloy when log collection is enabled.

For the current test environment, the expected Grafana hostname is:

```text
grafana-srvotptest26.init-db.lan
```

Do not use `grafana-test.lan` as the active runtime hostname.
