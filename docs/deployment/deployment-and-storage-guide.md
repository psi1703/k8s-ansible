# Deployment and Storage Guide

## Purpose

This guide is the deployment and storage reference for OTP Relay Kubernetes.

It owns:

* GitHub Actions deployment flow
* installer behavior
* `.env` source-of-truth configuration
* cluster/node deployment model
* Traefik/TLS exposure
* NFS/RWX application storage
* Redis deployment model
* Redis StatefulSet update safety
* post-deployment verification

Detailed operational checks belong in:

```text
docs/operations/operations-and-validation-runbook.md
```

Detailed Grafana, Prometheus, Loki, Alloy, and dashboard guidance belongs in:

```text
docs/operations/observability-and-grafana.md
```

Detailed build/source-generated artifact guidance belongs in:

```text
docs/development/build-and-development-guide.md
```

---

## Recommended deployment path

Use GitHub Actions with the self-hosted runner.

```text
GitHub push or workflow run
  -> GitHub Actions job starts
  -> self-hosted runner checks out the repo
  -> installer runs from the runner/control-plane host
  -> installer loads or creates .env
  -> installer builds required generated assets
  -> installer builds/imports app and monitor images
  -> installer renders Kubernetes resources from .env
  -> installer applies Kubernetes resources
  -> installer applies observability resources when enabled
  -> installer waits for rollouts
  -> installer prints deployment summary
```

The workflow should call:

```text
install-otp-relay-k8s.sh
```

Deployment logic belongs in the installer and repository scripts, not duplicated in GitHub Actions YAML.

---

## Runtime configuration source of truth

The repository root `.env` file is the single source of operator-provided deployment values.

Fresh install behavior:

* If `.env` is missing, the installer should create it interactively unless non-interactive mode is explicitly enabled.
* Required values should be validated before deployment continues.
* Site-specific values should be written to `.env`, not hardcoded elsewhere.

Update behavior:

* Existing `.env` is loaded automatically.
* Existing `.env` must not be overwritten silently.
* Incomplete or invalid `.env` should fail clearly or trigger the documented recreate flow.
* Normal updates must preserve existing Redis and PVC data.

Values that belong in `.env` include:

```text
TLS_HOST
PORTAL_URL
SERVICE_TYPE
INGRESS_ENABLED
TLS_ENABLED
TLS_SECRET_NAME
TLS_SELF_SIGNED
PHONE_IP
PHONE_INTERFACE
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
SMS_SECRET_TOKEN
REDIS_ENABLED
REDIS_REQUIRED
REDIS_URL
NFS_ENABLED
NFS_SERVER
NFS_PATH
NFS_STORAGE_CLASS
PVC_STORAGE_CLASS
REPLICA_COUNT
```

Do not place site-specific values directly in:

```text
Python files
shell scripts
Kubernetes YAML
Ansible tasks
documentation examples
```

---

## Required GitHub Actions secrets

Create these in GitHub Actions secrets when the workflow expects them:

```text
PHONE_IP
PHONE_INTERFACE
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
PORTAL_URL
```

Depending on workflow implementation, some values may instead be read from `.env` on the runner host.

Do not commit:

* Telegram credentials
* SMS secret token
* runtime tokens
* generated secrets
* `.env`
* production `users.xlsx`

---

## Current Phase 3 deployment posture

Current validation values:

```text
SERVICE_TYPE=ClusterIP
INGRESS_ENABLED=1
TLS_ENABLED=1
TLS_HOST=srvotptest26.init-db.lan
TLS_SECRET_NAME=otp-relay-tls
TLS_SELF_SIGNED=1
REDIS_ENABLED=1
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
NFS_ENABLED=1
NFS_SERVER=172.31.11.108
NFS_PATH=/export/otp-relay-data
NFS_STORAGE_CLASS=otp-relay-nfs
PVC_STORAGE_CLASS=otp-relay-nfs
```

`REPLICA_COUNT` is controlled by `.env`.

Two app replicas were validated with real SMS/OTP portal confirmation and worker-drain recovery on **2026-06-03**.

The portal is exposed through Traefik Ingress. The `otp-relay` service remains internal to the cluster and is used as the Ingress backend.

---

## Cluster and node model

The current `k8s-ansible` deployment model uses:

| Role          | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| Control-plane | Real server / localhost K3s control-plane and Ansible runner |
| Worker 1      | VM worker node                                               |
| Worker 2      | VM worker node                                               |
| NFS server    | External storage server, not joined as a Kubernetes node     |

Deployment rules:

* VM provisioning should create worker VMs only.
* The real server is the K3s control-plane and Ansible runner.
* The external NFS server should not be joined to Kubernetes.
* The monitor should run on the node with phone-network visibility.
* Redis-capable nodes should be labelled for Redis/storage placement.

Known node labels:

```text
otp-relay/storage-node=true
otp-relay/monitor-node=true
```

During controlled worker-drain maintenance, one Redis pod may temporarily remain `Pending` because of one-per-node Redis placement. This is acceptable only if `/readyz`, Redis/Sentinel/HAProxy checks, app availability, and post-uncordon strict health all pass.

---

## Traefik and TLS

The current validation path uses:

* Traefik Ingress for HTTP/HTTPS routing
* Kubernetes TLS secret for HTTPS
* self-signed TLS until IT distributes/trusts the certificate
* internal DNS name `srvotptest26.init-db.lan`

Validate exposure after deployment:

```bash
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get secret otp-relay-tls -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

* Ingress host is `srvotptest26.init-db.lan`.
* TLS secret exists.
* `/healthz` returns 200.
* `/readyz` returns 200 with Redis healthy and Redis required.

Browser users may see a certificate warning until IT deploys trust for the internal/self-signed certificate.

---

## NFS/RWX application storage

The app data PVC should use shared NFS/RWX storage.

Expected NFS export:

```text
NFS server: 172.31.11.108
NFS path:   /export/otp-relay-data
```

Expected Kubernetes storage:

```text
PV:            otp-relay-data-nfs-pv
PVC:           otp-relay-data
StorageClass:  otp-relay-nfs
Access mode:   ReadWriteMany
Mount path:    /app/data
```

Expected files in `/app/data`:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

The monitor also reads the shared audit log from this storage path.

OTP values must not be written to the NFS-backed files.

NFS/RWX app storage was validated on **2026-06-03** by writing a proof file from one app pod and reading it from another app pod.

---

## Existing PVC migration rule

Before moving an existing live deployment from local-path/RWO to NFS/RWX:

1. Scale the app and monitor safely if needed.
2. Back up the existing `/app/data` contents.
3. Confirm the NFS export exists.
4. Confirm Kubernetes can mount the NFS export.
5. Restore app data onto the NFS export.
6. Apply NFS PV/PVC configuration.
7. Restart the app and monitor.
8. Verify that `users.xlsx`, config files, wizard progress, and `audit.log` are present.
9. Verify write access from the app pod.
10. Verify monitor can read the shared audit log.

Do not delete old PVC data until the NFS-backed deployment is verified.

Validate write access:

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

## Redis deployment model

Redis is required in the Phase 3 validation posture.

```text
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

Redis components:

```text
redis-statefulset.yaml
redis-service.yaml
redis-pdb.yaml
redis-sentinel-configmap.yaml
redis-sentinel-deployment.yaml
redis-sentinel-service.yaml
redis-haproxy-configmap.yaml
redis-haproxy-deployment.yaml
redis-haproxy-service.yaml
```

The app uses:

```text
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

`otp-redis-haproxy` routes to the current Redis master based on Sentinel state.

App pods should not connect directly to a single Redis pod.

Redis HA/Sentinel/HAProxy behavior was validated on **2026-06-03**, including Redis master pod deletion recovery and post-recovery strict health validation.

---

## Redis StatefulSet update safety

Kubernetes does not allow normal `apply`/patch updates to some StatefulSet fields after the StatefulSet is created.

A normal update may fail with:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

This means the desired Redis StatefulSet manifest changed an immutable field.

Normal deployment or workflow update behavior must not:

* silently delete the Redis StatefulSet
* delete Redis PVCs
* recreate Redis as a side effect of an app or observability update
* treat Redis data loss as acceptable by default

Safe behavior is one of:

1. preserve the existing StatefulSet and continue with a clear warning,
2. fail clearly and require an explicit maintenance action, or
3. run a documented destructive Redis reset path only when intentionally requested.

Before any destructive Redis action, inspect:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay get pvc
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis -o wide
```

A normal application, documentation, workflow, frontend, or observability update should not destroy Redis data.

---

## Observability deployment hook

Observability resources live under:

```text
k8s/observability/
```

The installer may apply observability resources when observability is enabled.

Normal Grafana access:

```text
https://grafana.init-db.lan
```

The Grafana dashboard follows this source-generated model:

```text
Source:    k8s/observability/dashboards/otp-relay-live.json
Generated: k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator: scripts/build_grafana_dashboard_configmap.py
```

Observability recovery was validated on **2026-06-03**, including Prometheus/Grafana/Loki/Alloy checks and Grafana dashboard persistence after restart.

This guide does not own dashboard query details or Grafana troubleshooting.

See:

```text
docs/operations/observability-and-grafana.md
```

---

## Generated assets during deployment

The installer is responsible for generating required deployment artifacts.

Important generated paths:

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Source files:

```text
frontend/app.jsx
docs/help/
docs/help/assets/
k8s/observability/dashboards/otp-relay-live.json
```

Detailed source/generated rules belong in:

```text
docs/development/build-and-development-guide.md
```

---

## Manual image build fallback

GitHub Actions is preferred.

Manual build is only a fallback when intentionally operating from the runner/control-plane host.

Build locally from the repo root:

```bash
docker build -t otp-relay:latest -f k8s/Dockerfile .
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

Export images:

```bash
docker save otp-relay:latest -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
```

Import on the K3s node:

```bash
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

Restart workloads:

```bash
sudo k3s kubectl rollout restart deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout restart deployment/otp-monitor -n otp-relay
sudo k3s kubectl rollout status deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout status deployment/otp-monitor -n otp-relay
```

For image build details, see:

```text
docs/development/build-and-development-guide.md
```

---

## Post-deployment verification

Run these after deployment:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get pvc -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected:

* nodes are Ready
* app pods are Running/Ready
* monitor pod is Running/Ready
* Redis/Sentinel/HAProxy pods are Running/Ready
* PVC is Bound
* `/healthz` returns 200
* `/readyz` returns 200 with Redis healthy and required
* monitor health script reports OK

For complete operational validation, see:

```text
docs/operations/operations-and-validation-runbook.md
```

---

## Deployment troubleshooting scope

This guide only covers deployment-specific failure areas.

For day-to-day operations and validation, use:

```text
docs/operations/operations-and-validation-runbook.md
```

For Grafana/Prometheus issues, use:

```text
docs/operations/observability-and-grafana.md
```

For build/generation issues, use:

```text
docs/development/build-and-development-guide.md
```

### `/readyz` fails immediately after deployment

Check Redis first when `REDIS_REQUIRED=1`:

```bash
curl -k https://srvotptest26.init-db.lan/readyz
sudo k3s kubectl get pods -n otp-relay -o wide | grep -E 'redis|haproxy'
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
```

### NFS write fails after deployment

Check PVC and permissions:

```bash
sudo k3s kubectl describe pvc otp-relay-data -n otp-relay
sudo k3s kubectl exec -n otp-relay deployment/otp-relay -- ls -l /app/data
```

On the NFS server, verify ownership/permissions for the app UID/GID expected by the container.

### Redis StatefulSet apply fails

Treat this as an immutable-field update issue.

Do not delete Redis PVCs during a normal update.

Inspect:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay get pvc
```

Then use the documented maintenance/reset path only if destructive Redis recreation is intentionally approved.

---

## Files never to commit

```text
.env
secret.env
Runtime tokens
Telegram credentials
SMS secret token
users.xlsx production copy
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
*.tar
*.log
```

---

## Deployment sign-off checklist

* [x] `.env` exists and contains the intended runtime values.
* [x] GitHub Actions workflow uses the self-hosted runner.
* [x] Installer runs without replacing `.env` unexpectedly.
* [x] Required generated assets are produced before image build/apply.
* [x] App and monitor images build successfully.
* [x] K3s imports the expected images.
* [x] Kubernetes resources apply cleanly.
* [x] Redis StatefulSet is not destructively recreated during a normal update.
* [x] NFS PVC is Bound.
* [x] App can write to `/app/data`.
* [x] Monitor can read `/app/data/audit.log`.
* [x] `/healthz` returns 200.
* [x] `/readyz` returns 200 with Redis healthy.
* [x] Monitor health script reports OK.
* [x] Grafana loads at `https://grafana.init-db.lan` when observability is enabled.
* [x] Telegram alerting configuration is present when alerts are expected.
* [x] OTP business-flow validation passed on 2026-06-03.
* [x] Two-replica and worker-drain validation passed on 2026-06-03.
* [ ] IT certificate trust rollout is completed or explicitly tracked as pending.
* [ ] Redis backup/restore procedure is documented.
* [ ] SCH accepts Redis Sentinel/HAProxy or selects managed Redis.
* [ ] Final production LB/VIP model is confirmed with SCH if required.
