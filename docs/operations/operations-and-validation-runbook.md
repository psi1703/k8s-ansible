# Operations and Validation Runbook

## Purpose

This runbook is the day-2 operations reference for the OTP Relay Kubernetes environment.

It is intentionally focused on runtime checks, validation, recovery, and troubleshooting. Deployment design belongs in `docs/deployment/deployment-and-storage-guide.md`. Observability details belong in `docs/operations/observability-and-grafana.md`. Build and generated artifact rules belong in `docs/development/build-and-development-guide.md`.

The project should be understood in layers:

```text
Application layer        FastAPI portal, frontend, monitor, iPhone Shortcut OTP flow
Kubernetes layer         K3s, Deployments, Services, Ingress, Secrets, ConfigMaps
Resilience layer         Redis, Sentinel, HAProxy, NFS/RWX storage, pod spreading
Network access layer     Traefik, MetalLB, internal DNS, optional TLS
Observability layer      Prometheus, Grafana, Loki, Alloy, dashboard provisioning
Automation layer         setup.sh, install-otp-relay-k8s.sh, repo sync, validation scripts
Operations layer         health checks, recovery, controlled destructive tests
```

---

## Current operating baseline

The current target operating model is:

```text
Cluster:            3-node K3s cluster
Control plane:      debian
Workers:            otp-worker1, otp-worker2
Portal namespace:   otp-relay
Observability ns:   observability
Portal ingress:     srvotptest26.init-db.lan
Grafana ingress:    grafana-srvotptest26.init-db.lan
Traefik LB IP:      172.31.11.121
Storage:            NFS-backed RWX /app/data
Redis:              Redis StatefulSet with Sentinel and HAProxy
App replicas:       multiple app replicas when Redis is required
Monitor:            isolated pod, no Service, no Ingress
```

The exact runtime state should always be verified from the cluster rather than assumed:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get ingress -A -o wide
sudo k3s kubectl get svc -A -o wide
```

---

## Daily health check

Run this first for routine validation:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay -o wide
sudo k3s kubectl get ingress -n otp-relay -o wide
sudo k3s kubectl get pvc -n otp-relay
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected result:

```text
All nodes Ready
App pods Running/Ready
Monitor pod Running/Ready
Redis, Sentinel, and HAProxy pods Running/Ready
PVC Bound
Ingress host present
Monitor health script reports OK
```

Application endpoint checks:

```bash
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

If TLS is not active or the browser is being tested through HTTP during setup, use the active scheme from the rendered Ingress and installer report.

---

## Network and access checks

Check Traefik and MetalLB address assignment:

```bash
sudo k3s kubectl -n kube-system get svc traefik -o wide
sudo k3s kubectl get ingress -A -o wide
```

Expected active access model:

```text
Portal:   srvotptest26.init-db.lan          -> 172.31.11.121
Grafana:  grafana-srvotptest26.init-db.lan  -> 172.31.11.121
```

Host-header validation from the server:

```bash
curl -I -H "Host: srvotptest26.init-db.lan" http://172.31.11.121/
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Expected:

```text
Portal host returns the portal
Grafana host returns 302 Found with Location: /login
```

Bare IP behavior is different from hostname behavior. If `http://172.31.11.121/` opens the portal, that does not prove Grafana is broken. Grafana is host-based unless a dedicated Grafana LoadBalancer IP or subpath mode is intentionally configured.

Client-side DNS checks:

```bash
nslookup srvotptest26.init-db.lan
nslookup grafana-srvotptest26.init-db.lan
```

Both names should resolve to the Traefik LoadBalancer IP unless a different exposure mode is intentionally selected.

---

## Application storage checks

Check PV and PVC state:

```bash
sudo k3s kubectl get pv,pvc -n otp-relay
sudo k3s kubectl describe pvc otp-relay-data -n otp-relay
```

Expected storage model:

```text
PVC:          otp-relay-data
Access mode:  RWX
Mount path:   /app/data
Back end:     NFS-backed shared storage
```

Check runtime files from an app pod:

```bash
sudo k3s kubectl exec -n otp-relay deployment/otp-relay -- ls -l /app/data
```

Expected runtime files may include:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

Check app write access:

```bash
sudo k3s kubectl -n otp-relay get pods -l app=otp-relay -o name | while read -r pod; do
  echo "=== $pod ==="
  sudo k3s kubectl -n otp-relay exec "${pod#pod/}" -- sh -c '
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

Do not delete the PVC or NFS data during normal updates.

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

Check Redis StatefulSet:

```bash
sudo k3s kubectl get statefulset otp-redis -n otp-relay
sudo k3s kubectl get pods -n otp-relay -l app=otp-redis -o wide
```

Check Sentinel-reported master:

```bash
SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
  -l app=otp-redis-sentinel \
  -o jsonpath='{.items[0].metadata.name}')

sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

Check logs when Redis readiness or OTP state looks unhealthy:

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-relay --tail=100
```

The app should use the Redis HAProxy service, not individual Redis pod IPs:

```text
redis://otp-redis-haproxy:6379/0
```

---

## Redis StatefulSet update safety

Kubernetes does not allow normal patch/apply updates to some StatefulSet fields after creation.

If an update fails with an error like this:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

then the update attempted to change an immutable Redis StatefulSet field.

Operational rules:

```text
Do not delete Redis PVCs during a normal update.
Do not silently recreate Redis during a normal update.
Do not treat this as a normal rollout restart issue.
Preserve the existing Redis StatefulSet when possible.
Use an explicit maintenance procedure for destructive Redis topology changes.
```

Inspection commands:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay describe statefulset otp-redis
sudo k3s kubectl -n otp-relay get pvc
```

Normal documentation, frontend, app-image, workflow, or observability updates should not remove Redis data.

---

## Monitor checks

The monitor is required and must not be exposed by Service or Ingress.

Check pod and logs:

```bash
sudo k3s kubectl get pods -n otp-relay -o wide | grep monitor
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=100
```

Expected monitor properties:

```text
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
NET_RAW capability
no Service
no Ingress
can check phone presence on the configured phone network
can read /app/data/audit.log
can expose Prometheus metrics
can send Telegram alerts when configured
```

Confirm monitor is not exposed:

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

## Telegram alert checks

Telegram is the supported monitor alerting path.

Check rendered monitor configuration without printing secret values into shared tickets:

```bash
sudo k3s kubectl -n otp-relay describe deployment otp-monitor | grep -Ei 'TELEGRAM|PHONE'
```

Check recent monitor logs:

```bash
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=200 | grep -Ei 'telegram|phone|alert' || true
```

Expected:

```text
Telegram credentials are not committed to Git.
Telegram values come from .env or generated Kubernetes Secret behavior.
Phone online/offline events can trigger Telegram alerts when configured.
Old WhatsApp alert references should not appear in active paths unless explicitly retained as history.
```

---

## Observability smoke checks

Detailed Grafana, Prometheus, Loki, Alloy, dashboard, and PromQL guidance belongs in:

```text
docs/operations/observability-and-grafana.md
```

Use this section only for quick operational checks.

Check core resources:

```bash
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability -o wide
sudo k3s kubectl get ingress -n observability -o wide
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability
sudo k3s kubectl get servicemonitor -n observability
```

Expected:

```text
Grafana pod Running/Ready
Prometheus pod Running/Ready
Loki/Alloy components Running/Ready when enabled
Grafana Ingress exists when enabled
otp-relay-live-dashboard ConfigMap exists
ServiceMonitor resources exist for portal and monitor
```

Grafana host-header test:

```bash
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Expected:

```text
HTTP/1.1 302 Found
Location: /login
```

Check Grafana logs only when dashboard provisioning appears broken:

```bash
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana --tail=100
sudo k3s kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=100
```

---

## OTP validation checklist

Real OTP validation requires the company iPhone and the iOS Shortcut flow. This cannot be fully proven by Kubernetes health checks alone.

Checklist:

```text
[ ] Portal loads through the intended hostname.
[ ] User token login works.
[ ] OTP claim flow works.
[ ] iPhone receives OTP SMS.
[ ] iPhone Shortcut posts SMS to /sms-received.
[ ] OTP appears on screen for the waiting user.
[ ] OTP expires after TTL.
[ ] OTP value is not written to logs or disk.
[ ] Audit log records only non-sensitive flow events.
[ ] Pending OTP survives app restart when Redis is healthy.
[ ] Two-replica OTP flow works in a controlled test.
```

Human-assisted validation flow:

```text
1. Open the portal.
2. Log in as a test user.
3. Claim the OTP slot.
4. Trigger the external system to send an SMS to the company iPhone.
5. Confirm the iPhone received the SMS.
6. Confirm the iOS Shortcut posted to /sms-received.
7. Confirm the OTP appears in the browser.
8. Confirm the audit log contains expected non-sensitive events.
9. Confirm the OTP value is not present in app logs or audit logs.
```

Do not treat future changes to OTP parsing, Redis state handling, frontend polling, or deployment behavior as automatically validated. Re-run this checklist after those changes.

---

## Worker-drain validation checklist

Run only during a controlled maintenance/test window.

Before drain:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Drain one worker at a time according to the approved procedure, then verify:

```text
[ ] App pod reschedules or remains healthy according to placement rules.
[ ] Redis Sentinel remains healthy.
[ ] Redis HAProxy remains healthy.
[ ] Redis master remains available or fails over correctly.
[ ] NFS app storage remains mounted.
[ ] /readyz returns healthy after the cluster settles.
[ ] OTP flow still works after recovery.
```

After validation:

```bash
sudo k3s kubectl uncordon <NODE_NAME>
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
```

Do not drain multiple Redis/Sentinel-critical nodes at the same time.

During active worker-drain maintenance, one Redis pod may temporarily remain `Pending` because of one-per-node Redis placement. That is acceptable only during the maintenance window if:

```text
/readyz remains healthy
Redis/Sentinel/HAProxy checks pass
app replicas remain available
post-uncordon strict health returns to full readiness
```

---

## Destructive validation rules

Destructive validation includes actions such as:

```text
deleting Redis pods
draining worker nodes
restarting critical deployments
forcing failover
restarting observability components
```

Rules:

```text
Run destructive tests only in a maintenance/test window.
Do not run destructive tests while SCH or users are actively validating OTP flow.
Do not delete Redis PVCs unless the procedure explicitly requires a destructive reset.
Do not drain more than one worker at a time.
Record before/after pod placement and endpoint health.
Confirm /readyz after every disruptive step.
```

If the repo contains an automated resilience validation script, start with its safe/default mode first. Use destructive flags only after confirming the maintenance window and expected blast radius.

---

## Troubleshooting quick reference

| Symptom | First checks |
|---|---|
| Portal not loading | Traefik service, portal Ingress, app service, app pods, `/healthz`, `/readyz` |
| Grafana not loading | Observability Ingress, Host header, DNS, Grafana pod, Grafana service |
| Bare IP opens portal instead of Grafana | Expected when Grafana uses host-based Ingress |
| `/readyz` fails | Redis, HAProxy, Sentinel, app logs |
| OTP not appearing | Claim state, iPhone SMS, Shortcut URL/token, Redis, app logs |
| User login fails | `users.xlsx`, token format, app logs, audit log |
| Monitor missing alerts | monitor pod, phone IP/interface, Telegram config, monitor logs |
| Redis pod Pending | node placement, anti-affinity, worker drain, PVC state |
| Grafana dashboard missing | dashboard ConfigMap, sidecar logs, Grafana logs |
| Loki missing workloads | Loki values and deployment mode |
| DNS works on server but not Windows | IT DNS, client DNS cache, client network, firewall/proxy |

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
sudo k3s kubectl get ingress -A -o wide
sudo k3s kubectl get svc -A -o wide
sudo k3s kubectl get events -n otp-relay --sort-by=.lastTimestamp
```

---

## Recovery discipline

Before changing runtime resources, capture evidence:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A -o wide
sudo k3s kubectl get ingress -A -o wide
sudo k3s kubectl get svc -A -o wide
sudo k3s kubectl get events -A --sort-by=.lastTimestamp | tail -80
```

Prefer source-of-truth repo fixes over live-only patches. Live patches are acceptable for emergency recovery, but the repo must be updated afterward if the change should survive reinstall or redeploy.
