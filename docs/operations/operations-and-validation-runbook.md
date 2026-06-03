# Operations and Validation Runbook

## Purpose

This runbook is the single operations and validation reference for OTP Relay Kubernetes.

It combines:

* day-to-day health checks
* Phase 3 resilience validation
* Redis/Sentinel/HAProxy checks
* NFS shared-storage checks
* monitor validation
* observability and Grafana validation
* OTP business-flow validation
* SCH production-readiness checks

---

## Current validated state

Current validated cluster baseline:

```text
3-node K3s cluster
NFS/RWX app storage for /app/data
Redis Sentinel/HAProxy topology
Redis failover validated
Traefik HTTPS ingress enabled
Monitor pod isolated from Service/Ingress
Observability namespace with Prometheus/Grafana/Loki/Alloy
OTP Relay live Grafana dashboard provisioned from ConfigMap
```

Known node labels used for OTP Relay placement:

```text
otp-relay/storage-node=true
otp-relay/monitor-node=true
```

The monitor remains pinned to the node with phone-network visibility.

Redis-capable nodes are labelled with:

```text
otp-relay/storage-node=true
```

Current validation posture:

| Area                                   | Status                                             |
| -------------------------------------- | -------------------------------------------------- |
| K3s 3-node baseline                    | Validated                                          |
| NFS/RWX app storage                    | Validated                                          |
| Redis HA/Sentinel/HAProxy topology     | Validated                                          |
| Redis failover                         | Validated                                          |
| `/readyz` with Redis required          | Validated                                          |
| TLS/Ingress                            | Enabled; client trust rollout may still be pending |
| Monitor isolation                      | Aligned                                            |
| Observability namespace                | Enabled                                            |
| Grafana live dashboard                 | Provisioned from ConfigMap                         |
| Dashboard refresh/timepicker metadata  | Validated through generator                        |
| Frontend source/generated bundle model | Documented                                         |
| App multi-replica default              | Requires latest OTP business-flow validation       |
| Worker-drain validation                | Pending controlled-window validation               |

---

## Daily health checks

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get pvc -n otp-relay
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability
sudo k3s kubectl get servicemonitor -n observability
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Application endpoints:

```bash
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

* `/healthz` returns OK.
* `/readyz` returns Redis OK when Redis is required.
* App pods are Running/Ready.
* Monitor pod is Running/Ready.
* Redis, Sentinel, and HAProxy pods are Running/Ready.
* Observability pods are Running/Ready.
* `otp-relay-live-dashboard` ConfigMap exists in the `observability` namespace.
* ServiceMonitor resources exist for the portal and monitor.
* Monitor health script reports OK.

---

## Application storage checks

Confirm app PVC:

```bash
sudo k3s kubectl get pv,pvc -n otp-relay
sudo k3s kubectl describe pvc otp-relay-data -n otp-relay
```

Expected app storage:

```text
PVC:           otp-relay-data
PV:            otp-relay-data-nfs-pv
Access mode:   RWX
StorageClass:  otp-relay-nfs
NFS path:      /export/otp-relay-data
Mount path:    /app/data
```

Confirm runtime files from the app pod:

```bash
sudo k3s kubectl exec -n otp-relay deployment/otp-relay -- ls -l /app/data
```

Expected files:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

Confirm monitor can see the shared audit log:

```bash
sudo k3s kubectl exec -n otp-relay deployment/otp-monitor -- ls -l /app/data/audit.log
```

Validate app write access:

```bash
sudo k3s kubectl -n otp-relay get pods -l app=otp-relay -o name | while read p; do
  echo "=== $p ==="
  sudo k3s kubectl -n otp-relay exec "${p#pod/}" -- sh -c '
    id
    touch /app/data/write-test &&
    rm -f /app/data/write-test &&
    echo WRITE_OK || echo WRITE_FAILED
  '
done
```

Expected:

```text
WRITE_OK
```

from each app pod.

---

## Redis, Sentinel, and HAProxy checks

List Redis-related pods:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide | grep -E 'redis|haproxy'
```

Check Redis services:

```bash
sudo k3s kubectl get svc -n otp-relay | grep redis
```

Check StatefulSet:

```bash
sudo k3s kubectl get statefulset otp-redis -n otp-relay
sudo k3s kubectl get pods -n otp-relay -l app=otp-redis -o wide
```

Check Sentinel logs:

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
```

Check HAProxy logs:

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
```

The app should continue using:

```text
redis://otp-redis-haproxy:6379/0
```

`otp-redis` should route to HAProxy, and HAProxy should route to the current Redis master discovered through Sentinel.

Check Sentinel-reported Redis master:

```bash
SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
  -l app=otp-redis-sentinel \
  -o jsonpath='{.items[0].metadata.name}')

sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

---

## Redis StatefulSet update safety

Kubernetes does not allow normal patch/apply updates to some StatefulSet fields after creation.

If the installer or workflow fails with an error like this:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

then the update attempted to change an immutable Redis StatefulSet field.

Correct operational handling:

* Do not delete Redis PVCs during a normal update.
* Do not silently recreate Redis during a normal update.
* Do not treat this as a normal rollout restart issue.
* Preserve the existing Redis StatefulSet when possible.
* If a Redis topology change is required, use an explicit destructive reset or maintenance procedure.
* Any destructive Redis reset must be reviewed before execution.

Inspection commands:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay describe statefulset otp-redis
sudo k3s kubectl -n otp-relay get pvc
```

A normal application or observability update should not remove Redis data.

---

## Redis failover validation

Redis HA/Sentinel/HAProxy failover has been validated as a Phase 3 foundation.

Repeat failover testing only during a controlled maintenance/test window.

Before testing:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide | grep redis
curl -k https://srvotptest26.init-db.lan/readyz
```

During failover, delete or stop the current Redis master pod according to the planned test method, then watch:

```bash
sudo k3s kubectl get pods -n otp-relay -w
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=200
curl -k https://srvotptest26.init-db.lan/readyz
```

Pass criteria:

* Sentinel promotes a new master.
* HAProxy routes to the new master.
* `/readyz` returns Redis OK after recovery.
* The app does not need a Redis URL change.
* No Redis PVC is deleted.
* OTP runtime state behavior matches the expected Redis failover limitation for in-flight data.

---

## TLS and ingress checks

```bash
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl describe ingress -n otp-relay
sudo k3s kubectl get secret otp-relay-tls -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

* Ingress host is `srvotptest26.init-db.lan`.
* TLS secret exists.
* HTTPS endpoint works.
* Browser warning may remain until IT distributes/trusts the certificate by Group Policy or another approved endpoint trust method.

---

## Monitor checks

The monitor is required and must not be exposed publicly.

Check pod and logs:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide | grep monitor
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=100
```

Expected monitor properties:

* `hostNetwork: true`
* `dnsPolicy: ClusterFirstWithHostNet`
* `NET_RAW` capability
* no Service
* no Ingress
* can check phone presence on the configured phone network
* can read `/app/data/audit.log`
* can expose Prometheus metrics
* can send Telegram alerts when configured

Confirm no monitor Service/Ingress exists:

```bash
sudo k3s kubectl get svc -n otp-relay | grep monitor || true
sudo k3s kubectl get ingress -n otp-relay | grep monitor || true
```

Run monitor health script:

```bash
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected:

```text
OK: OTP Relay K3s deployment is healthy.
```

---

## Telegram alert validation

Telegram is the supported monitor alerting path.

Check relevant environment/configuration through the rendered deployment or runtime environment:

```bash
sudo k3s kubectl -n otp-relay describe deployment otp-monitor | grep -Ei 'TELEGRAM|PHONE'
```

Check monitor logs for alert activity:

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=200 | grep -Ei 'telegram|phone|alert' || true
```

Expected:

* Telegram credentials are not committed to Git.
* Telegram values come from `.env` or generated Kubernetes Secret/ConfigMap behavior.
* Phone online/offline events can trigger Telegram alerts when configured.
* Old WhatsApp alert references should not appear in active monitor documentation or workflow paths unless intentionally retained as historical notes.

---

## Observability and Grafana checks

The observability stack runs in the `observability` namespace.

The OTP Relay live dashboard is provisioned from a Kubernetes ConfigMap and should not be manually edited or saved from the Grafana UI.

### Grafana access

Normal Grafana browser access:

```text
https://grafana.init-db.lan
```

Port-forwarding is not the normal Grafana access model. Use port-forwarding only for temporary debugging.

Check Grafana route/resources:

```bash
sudo k3s kubectl get ingressroute -n observability
sudo k3s kubectl get svc -n observability | grep grafana
sudo k3s kubectl get pods -n observability -o wide | grep grafana
```

### Core resources

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
* Grafana IngressRoute exists when enabled.
* `otp-relay-live-dashboard` exists.
* ServiceMonitor resources exist for `otp-relay` and `otp-monitor`.

### Dashboard source and generated output

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
ConfigMap: otp-relay-live-dashboard
UID:       otp-relay-live
```

After editing the source dashboard JSON, regenerate the ConfigMap:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Validate the generated dashboard JSON before applying:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Apply and reload Grafana manually:

```bash
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Confirm the live ConfigMap contains the expected refresh metadata:

```bash
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

Expected:

* `"refresh": "15s"` exists.
* `timepicker.refresh_intervals` exists and includes `15s`.
* Top dashboard panels render as Stat tiles, not time-series graphs.
* Tile text is not clipped.
* Dashboard values update automatically without manual page refresh.

### Grafana logs

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

Use these logs when a dashboard ConfigMap has been applied but the dashboard does not appear or update in Grafana.

---

## Grafana dashboard metrics

The dashboard depends on these metrics:

```text
up{job="otp-relay"}
up{job="otp-monitor"}
otp_iphone_present
otp_monitor_arp_last_success_timestamp_seconds
otp_queue_depth
otp_active_user
otp_delivered_total
otp_claims_total
otp_iphone_absence_events_total
```

For multi-replica safety, dashboard queries should use aggregate expressions.

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

```promql
sum(increase(otp_delivered_total[$__range]))
```

```promql
sum(increase(otp_claims_total[$__range]))
```

```promql
clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)
```

Do not rely on a single pod's time series for counters when the app may run with multiple replicas.

---

## Prometheus query checks

Port-forward Prometheus only when direct Prometheus debugging is needed:

```bash
sudo k3s kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability
```

Then query from another shell:

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
* Last ARP is based on `otp_monitor_arp_last_success_timestamp_seconds`.

---

## Dashboard-specific checks

### Queue tile

Expected behavior:

```text
Queue: 0
```

can be correct when exactly one user has claimed the active OTP slot.

The queue tile represents users waiting behind the currently active OTP user. It does not count the active user as waiting.

### Active user tile

Expected behavior:

```text
Active user: IN USE
```

when a user currently owns the active OTP slot.

### Delivered today tile

Use a replica-aware counter query:

```promql
sum(increase(otp_delivered_total[$__range]))
```

Do not read only one pod's `otp_delivered_total` series.

### Last ARP tile

Last ARP shows the age of the monitor pod's last successful ARP probe.

Recommended expression:

```promql
clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)
```

If fake phone status is up but Last ARP is stale, check monitor connectivity and ARP metrics before changing the dashboard.

Do not make Last ARP depend only on whether the fake iPhone VM process is running.

---

## Frontend and help overlay validation

The portal serves the generated frontend bundle:

```text
Source:    frontend/app.jsx
Generated: frontend/app.js
```

Do not edit `frontend/app.js` directly as source.

Make frontend changes in:

```text
frontend/app.jsx
```

Then rebuild:

```text
frontend/app.js
```

and commit both files if the generated bundle changes.

Help content is generated from markdown:

```text
Source:    docs/help/*.md and docs/help/assets/*
Generated: frontend/help/*
```

Regenerate help output:

```bash
python3 scripts/build_help_docs.py
```

If a guide image works in pop-out view but not in the overlay:

* Confirm the image exists under `frontend/help/assets/`.
* Confirm `frontend/help/wizard-guide.json` uses `/help/assets/...` paths.
* Check `frontend/app.jsx` overlay iframe handling.
* Rebuild `frontend/app.js` after fixing `frontend/app.jsx`.

Useful checks:

```bash
find frontend/help -type f | sort | grep -Ei 'png|jpg|jpeg|webp|svg'
grep -R 'new-user-onboarding-sequence.png' -n docs/help frontend/help frontend/app.jsx frontend/guide.html scripts/build_help_docs.py
curl -I http://127.0.0.1:8000/help/assets/new-user-onboarding-sequence.png
curl -I http://127.0.0.1:8000/help/wizard-guide.json
```

---

## OTP validation checklist

Run this before approving multi-replica app validation:

* [ ] Login page loads through HTTPS.
* [ ] User token login works.
* [ ] OTP claim flow works.
* [ ] iPhone receives OTP SMS.
* [ ] iPhone Shortcut posts SMS to `/sms-received`.
* [ ] OTP appears on screen for the waiting user.
* [ ] OTP expires after TTL.
* [ ] OTP value is not written to logs or disk.
* [ ] Audit log records the non-sensitive flow.
* [ ] Manager live OTP trigger test passes.
* [ ] Pending OTP survives app restart when Redis is healthy.
* [ ] Two-replica OTP flow works in a controlled test.

Do not approve a production multi-replica posture until these checks pass after the latest source/build/workflow changes.

---

## Human-assisted OTP validation flow

Some OTP validation steps require a real SMS and human confirmation.

Recommended operator flow:

1. Open the portal through HTTPS.
2. Log in as a test user.
3. Claim the OTP slot.
4. Trigger the external system to send an SMS to the company iPhone.
5. Confirm the iPhone received the SMS.
6. Confirm the iOS Shortcut posted to `/sms-received`.
7. Confirm the OTP appears in the browser.
8. Confirm the audit log contains the expected non-sensitive events.
9. Confirm the OTP value is not present in application logs or audit logs.

Acceptable human checkpoint wording in validation scripts:

```text
Do you see the SMS on the iPhone and did the OTP appear in the portal?
1) Yes, continue
2) No, fail this validation step
```

---

## DNS/TLS client validation checklist

* [ ] `srvotptest26.init-db.lan` resolves from user machines.
* [ ] HTTPS loads from user machines.
* [ ] Certificate trust warning is gone after Group Policy trust rollout or approved certificate installation.
* [ ] Portal works from the intended client network.
* [ ] iPhone Shortcut target URL is correct after DNS/TLS finalization.

Useful commands:

```bash
nslookup srvotptest26.init-db.lan
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

---

## Worker-drain validation checklist

Run only in a controlled test window.

Before drain:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Drain one worker according to SCH-approved procedure, then verify:

* [ ] App pod reschedules or remains healthy according to placement rules.
* [ ] Redis Sentinel remains healthy.
* [ ] Redis HAProxy remains healthy.
* [ ] Redis master remains available or fails over correctly.
* [ ] NFS app storage remains mounted.
* [ ] `/readyz` returns healthy after the cluster settles.
* [ ] OTP flow still works after recovery.

After validation:

```bash
sudo k3s kubectl uncordon <NODE_NAME>
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
```

Do not drain multiple Redis/Sentinel-critical nodes at the same time.

---

## Useful commands

```bash
sudo k3s kubectl get all -n otp-relay
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl describe pod -n otp-relay <pod-name>
sudo k3s kubectl logs -n otp-relay deployment/otp-relay --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=200
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=200
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
sudo k3s kubectl rollout status deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout restart deployment/otp-relay -n otp-relay
sudo k3s kubectl get events -n otp-relay --sort-by=.lastTimestamp
```

---

## Troubleshooting quick reference

| Symptom                       | First checks                                                 |
| ----------------------------- | ------------------------------------------------------------ |
| Portal not loading            | ingress, service, app pod, `/healthz`, `/readyz`             |
| `/readyz` fails               | Redis, HAProxy, Sentinel, app logs                           |
| OTP not appearing             | claim state, iPhone SMS, Shortcut URL/token, app logs, Redis |
| Monitor unhealthy             | phone IP/interface, hostNetwork, NET_RAW, audit log mount    |
| Telegram alert not sent       | `.env`, Secret/ConfigMap rendering, monitor logs             |
| Grafana URL not loading       | IngressRoute, DNS, Grafana service, Grafana pod              |
| Dashboard missing             | ConfigMap, sidecar logs, Grafana restart                     |
| Dashboard stale/no data       | ServiceMonitor, Prometheus query, panel query mode           |
| Last ARP stale                | monitor ARP metric, phone IP/interface, monitor logs         |
| Redis StatefulSet apply fails | immutable field change; avoid destructive normal update      |
| NFS write fails               | NFS ownership/permissions, PVC mount, app UID/GID            |

---

## Final sign-off gates

Before declaring the deployment production-aligned for SCH:

* [ ] Root README and docs are current.
* [ ] `.env` is the single operator input source.
* [ ] Workflow uses the self-hosted runner correctly.
* [ ] Observability applies cleanly from source/generated files.
* [ ] Grafana is reachable through `https://grafana.init-db.lan`.
* [ ] Portal is reachable through the intended TLS host.
* [ ] Redis update behavior is safe for existing StatefulSet/PVC resources.
* [ ] Telegram is the documented alerting path.
* [ ] OTP business-flow validation passes.
* [ ] Two-replica OTP flow validation passes.
* [ ] Worker-drain validation is completed or explicitly listed as pending.
* [ ] IT certificate trust rollout is completed or explicitly listed as pending.
