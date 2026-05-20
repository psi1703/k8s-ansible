# Operations and Validation Runbook

## Purpose

This runbook is the single operations and validation reference for OTP Relay Kubernetes. It combines the current Phase 3 resilience validation state with the practical commands needed for day-to-day checks and remaining SCH validation.

## Current validated state

Validated cluster baseline:

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

The monitor remains pinned to the node with phone-network visibility. Redis-capable nodes are labelled with `otp-relay/storage-node=true`.

## Daily health checks

```bash
kubectl get nodes -o wide
kubectl get pods -n otp-relay -o wide
kubectl get svc -n otp-relay
kubectl get ingress -n otp-relay
kubectl get pvc -n otp-relay
kubectl get pods -n observability -o wide
kubectl get svc -n observability
kubectl get configmap otp-relay-live-dashboard -n observability
kubectl get servicemonitor -n observability
```

Application endpoints:

```bash
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

- `/healthz` returns OK.
- `/readyz` returns Redis OK and Redis required.
- App pods are Running/Ready.
- Monitor pod is Running/Ready.
- Redis, Sentinel, and HAProxy pods are Running/Ready.
- Observability pods are Running/Ready.
- `otp-relay-live-dashboard` ConfigMap exists in the `observability` namespace.
- ServiceMonitor resources exist for the portal and monitor.

## Application storage checks

Confirm app PVC:

```bash
kubectl get pv,pvc -n otp-relay
kubectl describe pvc otp-relay-data -n otp-relay
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
kubectl exec -n otp-relay deployment/otp-relay -- ls -l /app/data
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
kubectl exec -n otp-relay deployment/otp-monitor -- ls -l /app/data/audit.log
```

## Redis/Sentinel/HAProxy checks

List Redis-related pods:

```bash
kubectl get pods -n otp-relay -o wide | grep -E 'redis|haproxy'
```

Check Redis service:

```bash
kubectl get svc -n otp-relay | grep redis
```

Check Sentinel logs:

```bash
kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
```

Check HAProxy logs:

```bash
kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
```

The app should continue using:

```text
redis://otp-redis-haproxy:6379/0
```

`otp-redis` should route to HAProxy, which then routes to the current Redis master.

## Redis failover validation

Redis HA/Sentinel/HAProxy failover has been validated as a Phase 3 foundation. Repeat only during a controlled maintenance/test window.

Before testing:

```bash
kubectl get pods -n otp-relay -o wide | grep redis
curl -k https://srvotptest26.init-db.lan/readyz
```

During failover, delete or stop the current Redis master pod according to the planned test method, then watch:

```bash
kubectl get pods -n otp-relay -w
kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=200
curl -k https://srvotptest26.init-db.lan/readyz
```

Pass criteria:

- Sentinel promotes a new master.
- HAProxy routes to the new master.
- `/readyz` returns Redis OK after recovery.
- The app does not need a Redis URL change.

## TLS and ingress checks

```bash
kubectl get ingress -n otp-relay
kubectl describe ingress -n otp-relay
kubectl get secret otp-relay-tls -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
```

Expected:

- Ingress host is `srvotptest26.init-db.lan`.
- TLS secret exists.
- HTTPS endpoint works.
- Browser warning may remain until IT distributes/trusts the certificate by Group Policy.

## Monitor checks

The monitor is required and must not be exposed publicly.

Check pod and logs:

```bash
kubectl get pods -n otp-relay -o wide | grep monitor
kubectl logs -n otp-relay deployment/otp-monitor --tail=100
```

Expected monitor properties:

- `hostNetwork: true`.
- `NET_RAW` capability.
- No Service.
- No Ingress.
- Can check phone presence on the configured phone network.
- Can read `/app/data/audit.log`.
- Can send Telegram alerts when configured.

## Observability and Grafana checks

The observability stack runs in the `observability` namespace. The OTP Relay live dashboard is provisioned from a Kubernetes ConfigMap and should not be manually edited or saved from the Grafana UI.

### Core resources

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

### Dashboard source and generated output

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
ConfigMap: otp-relay-live-dashboard
UID:       otp-relay-live
```

After editing the source dashboard JSON, regenerate the ConfigMap:

```bash
python3 scripts/generate_grafana_dashboard_configmap.py
```

Validate the generated dashboard JSON before applying:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Apply and reload Grafana:

```bash
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

Confirm the live ConfigMap contains the expected refresh metadata:

```bash
kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

Expected:

- `"refresh": "15s"` exists.
- `timepicker.refresh_intervals` exists and includes `15s`.
- Top dashboard panels render as Stat tiles, not time-series graphs.
- Tile text is not clipped.
- Dashboard values update automatically without manual page refresh.

### Grafana dashboard metrics

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

Check live Prometheus values when debugging dashboard panels:

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability
```

Then query from another shell or browser:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_queue_depth'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_active_user'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=otp_iphone_present'
```

### Dashboard-specific checks

- Queue tile shows users waiting behind the currently active OTP user.
- Active user tile shows whether a user currently holds the OTP slot.
- Last ARP shows the age of the monitor pod's last successful ARP probe, not simply whether the fake iPhone VM process is running.
- If fake phone status is up but Last ARP is stale, check monitor connectivity and ARP metrics before changing the dashboard.

## Frontend and help overlay validation

The portal serves the generated frontend bundle:

```text
Source:    frontend/app.jsx
Generated: frontend/app.js
```

Do not edit `frontend/app.js` directly as source. Make frontend changes in `frontend/app.jsx`, rebuild `frontend/app.js`, and commit both if the generated bundle changes.

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

- Confirm the image exists under `frontend/help/assets/`.
- Confirm `frontend/help/wizard-guide.json` uses `/help/assets/...` paths.
- Check `frontend/app.jsx` overlay iframe handling.
- Rebuild `frontend/app.js` after fixing `frontend/app.jsx`.

Useful checks:

```bash
find frontend/help -type f | sort | grep -Ei 'png|jpg|jpeg|webp|svg'
grep -R 'new-user-onboarding-sequence.png' -n docs/help frontend/help frontend/app.jsx frontend/guide.html scripts/build_help_docs.py
curl -I http://127.0.0.1:8000/help/assets/new-user-onboarding-sequence.png
curl -I http://127.0.0.1:8000/help/wizard-guide.json
```

## OTP validation checklist

Run this before approving multi-replica app validation:

- Login page loads through HTTPS.
- User token login works.
- OTP claim flow works.
- iPhone Shortcut posts SMS to `/sms-received`.
- OTP appears on screen for the waiting user.
- Audit log records the flow.
- Manager live OTP trigger test passes.
- Pending OTP survives app restart when Redis is healthy.
- Two-replica OTP flow works in a controlled test.

Do not approve a production multi-replica posture until these checks pass after the latest source/build changes.

## DNS/TLS client validation checklist

- `srvotptest26.init-db.lan` resolves from user machines.
- HTTPS loads from user machines.
- Certificate trust warning is gone after Group Policy trust rollout.
- Portal works from the intended client network.
- iPhone Shortcut target URL is correct after DNS/TLS finalization.

## Worker-drain validation checklist

Run only in a controlled test window.

Before drain:

```bash
kubectl get pods -n otp-relay -o wide
curl -k https://srvotptest26.init-db.lan/readyz
```

Drain one worker according to SCH-approved procedure, then verify:

- App pod reschedules or remains healthy according to placement rules.
- Redis Sentinel/HAProxy remains healthy.
- Redis master remains available or fails over correctly.
- NFS app storage remains mounted.
- `/readyz` returns healthy after the cluster settles.
- OTP flow still works after recovery.

## Useful commands

```bash
kubectl get all -n otp-relay
kubectl get pods -n otp-relay -o wide
kubectl describe pod -n otp-relay <pod-name>
kubectl logs -n otp-relay deployment/otp-relay --tail=200
kubectl logs -n otp-relay deployment/otp-monitor --tail=200
kubectl get pods -n observability -o wide
kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
kubectl rollout status deployment/otp-relay -n otp-relay
kubectl rollout restart deployment/otp-relay -n otp-relay
kubectl get events -n otp-relay --sort-by=.lastTimestamp
```

## Current validation summary

| Area | Status |
|---|---|
| K3s 3-node baseline | Validated |
| NFS/RWX app storage | Validated |
| Redis HA/Sentinel/HAProxy topology | Validated |
| Redis failover | Validated |
| `/readyz` with Redis required | Validated |
| TLS/Ingress | Enabled; client trust rollout pending |
| Monitor isolation | Aligned |
| Observability namespace | Enabled |
| Grafana live dashboard | Provisioned from ConfigMap |
| Dashboard refresh/timepicker metadata | Documented and validated through generator |
| Frontend source/generated bundle model | Documented |
| App multi-replica default | Requires latest OTP business-flow validation |
| Worker-drain validation | Pending |
