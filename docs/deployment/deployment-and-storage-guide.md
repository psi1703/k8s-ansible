# Deployment and Storage Guide

## Purpose

This guide explains how OTP Relay is deployed and how persistent runtime storage is handled.

It covers:

- deployment flow
- `.env` runtime configuration
- cluster and node roles
- Traefik and MetalLB exposure
- NFS/RWX application storage
- Redis deployment posture
- generated deployment assets
- post-deployment checks

It does not own day-to-day operations, Grafana dashboard troubleshooting, or development build details.

Use these documents for related areas:

```text
docs/operations/operations-and-validation-runbook.md
docs/operations/observability-and-grafana.md
docs/development/build-and-development-guide.md
```

---

## Deployment model in one view

The current repo model is intentionally operator-controlled.

```text
GitHub main branch
  -> local build/control-plane checkout
  -> scripts/sync-repo.sh updates repo files only
  -> local .env is preserved
  -> operator runs setup.sh intentionally
  -> installer validates runtime configuration
  -> generated assets are rebuilt when needed
  -> images are built/imported
  -> Kubernetes manifests are rendered from .env
  -> app, monitor, Redis, ingress, storage, and observability are applied
  -> health and rollout checks confirm the deployment
```

Repository sync is not deployment.

`sync-repo.sh` must not:

- install K3s
- run Helm
- apply Kubernetes manifests
- import container images
- restart workloads
- run Ansible deployment tasks
- mutate a live cluster

Deployment changes happen only when the operator intentionally runs the installer path.

---

## Operator commands

Sync local checkout with GitHub:

```bash
cd /opt/k8s-ansible
bash scripts/sync-repo.sh
```

Run the normal setup/deployment path:

```bash
cd /opt/k8s-ansible
bash setup.sh
```

Optional repo-sync timer:

```bash
cd /opt/k8s-ansible
bash scripts/install-repo-sync-timer.sh
```

The timer is still sync-only. It should never deploy by itself.

---

## Runtime configuration source of truth

The repository-root `.env` file is the source of truth for site-specific runtime configuration.

Fresh install behavior:

- If `.env` is missing, the installer creates or prompts for it.
- Required values must be validated before deployment continues.
- Site-specific values must be written to `.env`, not hardcoded into scripts or YAML.

Update behavior:

- Existing `.env` is loaded automatically.
- Existing `.env` must not be overwritten silently.
- Incomplete `.env` should fail clearly or follow the documented recreate path.
- Normal updates must preserve Redis data and PVC contents.

Values that belong in `.env` include:

```text
TLS_HOST
PORTAL_URL
SERVICE_TYPE
INGRESS_ENABLED
TLS_ENABLED
TLS_SECRET_NAME
TLS_SELF_SIGNED
LOADBALANCER_IP
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
GRAFANA_HOST
```

Do not place site-specific values directly in:

```text
Python files
shell scripts
Kubernetes YAML
Ansible tasks
documentation examples intended as active config
```

---

## Secrets and local-only files

The `.env` file is local runtime state. It must be preserved by repository sync and must not be committed.

Do not commit:

- `.env`
- Telegram credentials
- SMS secret token
- runtime tokens
- generated Kubernetes secrets
- production `users.xlsx`
- `admin_auth.json`
- `admin_config.json`
- `wizard_progress.json`
- `audit.log`

OTP values must remain runtime-only. They must not be written to disk, logs, manifests, install reports, or committed files.

---

## Current production-style posture

The current deployment posture is a resilience extension over the simple SCH baseline.

Expected posture:

```text
SERVICE_TYPE=ClusterIP
INGRESS_ENABLED=1
TLS_HOST=srvotptest26.init-db.lan
LOADBALANCER_IP=172.31.11.121
REDIS_ENABLED=1
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
NFS_ENABLED=1
NFS_SERVER=172.31.11.131
NFS_STORAGE_CLASS=otp-relay-nfs
PVC_STORAGE_CLASS=otp-relay-nfs
GRAFANA_HOST=grafana-srvotptest26.init-db.lan
```

The portal is exposed through Traefik Ingress. The `otp-relay` service remains internal and is used as the Ingress backend.

The app may run more than one replica only because OTP queue and pending OTP state are Redis-backed.

---

## Cluster and node model

The current `k8s-ansible` deployment model uses:

| Role | Description |
|---|---|
| Control-plane | Real server / localhost K3s control-plane and Ansible control host |
| Worker 1 | VM worker node |
| Worker 2 | VM worker node |
| NFS server | External storage server, not joined to Kubernetes |

Placement rules:

- VM provisioning creates worker VMs only.
- The real server remains the K3s control-plane and Ansible control host.
- The NFS server is external storage and should not be joined to Kubernetes.
- The monitor should run on the node with phone-network visibility.
- App replicas should run on worker nodes where possible.
- Redis/Sentinel/HAProxy should be spread across nodes where possible.

Known useful labels:

```text
otp-relay/storage-node=true
otp-relay/monitor-node=true
```

During controlled worker maintenance, one Redis pod may temporarily remain pending because of one-per-node placement. That is acceptable only during a controlled operation and only if app readiness, Redis HAProxy/Sentinel health, and post-maintenance recovery pass.

---

## Network access layer

Normal access model:

```text
Portal hostname  -> Traefik LoadBalancer IP -> OTP Relay Ingress
Grafana hostname -> Traefik LoadBalancer IP -> Grafana Ingress
```

Current expected hostnames:

```text
Portal:  srvotptest26.init-db.lan
Grafana: grafana-srvotptest26.init-db.lan
```

Current expected Traefik LoadBalancer IP:

```text
172.31.11.121
```

Important behavior:

- Bare IP access may hit the portal/default ingress.
- Grafana should normally be accessed through its Grafana hostname.
- If DNS is unavailable, a dedicated optional Grafana LoadBalancer mode may be used as a deliberate dev/test workaround.
- Do not treat `grafana-test.lan` as the active hostname.

Validate network resources:

```bash
sudo k3s kubectl -n kube-system get svc traefik -o wide
sudo k3s kubectl -n otp-relay get ingress -o wide
sudo k3s kubectl -n observability get ingress -o wide
```

Expected:

```text
traefik EXTERNAL-IP = 172.31.11.121
otp-relay ingress host = srvotptest26.init-db.lan
grafana ingress host = grafana-srvotptest26.init-db.lan
```

### DEV versus PROD Grafana access

The repository's intended production access model is DNS-based for both OTP Relay and Grafana:

```text
PRODUCTION

OTP Relay DNS
  -> Traefik / MetalLB
  -> OTP Relay Ingress
  -> OTP Relay service

Grafana DNS
  -> Traefik / MetalLB
  -> Grafana Ingress
  -> Grafana service
```

Production DNS records are managed externally and should resolve the approved OTP Relay and Grafana hostnames to the production Traefik/MetalLB address.

The current DEV environment has one deliberate exception: the Windows client used for testing cannot resolve the DEV Grafana hostname and cannot use a temporary hosts-file entry. For DEV only, Grafana may therefore be exposed through a separate direct `LoadBalancer` Service with its own MetalLB address.

Current DEV access model:

```text
DEV

OTP Relay
  srvotptest26.init-db.lan
  -> Traefik / MetalLB 172.31.11.121
  -> OTP Relay Ingress

Grafana
  http://172.31.11.122
  -> DEV-only grafana-direct LoadBalancer Service
  -> Grafana pod/service
```

Important production rule:

```text
The DEV-only grafana-direct LoadBalancer is a local testing workaround.
Do not treat it as the production Grafana exposure model.
Do not copy the DEV Grafana IP into production configuration.
Production must use the IT-provided Grafana DNS name through Traefik Ingress.
```

The existing Grafana Ingress should remain in the repository because it is the production path. The DEV direct-IP path is supplementary only and should not replace the hostname-based Ingress design.

---

## TLS posture

The portal may use HTTPS through Traefik and a Kubernetes TLS secret.

Typical portal TLS values:

```text
TLS_ENABLED=1
TLS_HOST=srvotptest26.init-db.lan
TLS_SECRET_NAME=otp-relay-tls
TLS_SELF_SIGNED=1
```

Validate portal TLS:

```bash
sudo k3s kubectl -n otp-relay get secret otp-relay-tls
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

- TLS secret exists.
- `/healthz` returns 200.
- `/readyz` returns 200.
- `/readyz` reports Redis healthy when `REDIS_REQUIRED=1`.

Browser users may see a certificate warning until IT distributes trust for the internal certificate or replaces it with an approved certificate.

---

## NFS/RWX application storage

The app data PVC should use shared NFS/RWX storage.

Expected Kubernetes storage model:

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

OTP values must not be written to NFS-backed files.

### Stable NFS endpoint and live PV consistency

The NFS endpoint used by Kubernetes must be stable. In the current environment the NFS VM uses:

```text
NFS_SERVER=172.31.11.131
```

Do not use a changing DHCP address for NFS-backed PVs.

Changing `NFS_SERVER` in `.env` does **not** rewrite an already-created or already-bound Kubernetes PV. Existing PVs retain the `spec.nfs.server` value with which they were created until the PV objects are deliberately changed or recreated through an approved maintenance procedure.

Before changing the NFS endpoint, and whenever Redis or app pods become `Running` but not `Ready` after an NFS VM restart, compare the configured value with the live PVs:

```bash
cd /opt/k8s-ansible

grep '^NFS_SERVER=' .env

sudo k3s kubectl get pv \
  -o custom-columns='PV:.metadata.name,STATUS:.status.phase,NFS_SERVER:.spec.nfs.server,NFS_PATH:.spec.nfs.path,CLAIM:.spec.claimRef.name'
```

For the current deployment, the OTP Relay shared-data PV and all three Redis NFS PVs should use the same stable NFS server:

```text
otp-relay-data-nfs-pv
otp-redis-0-nfs-pv
otp-redis-1-nfs-pv
otp-redis-2-nfs-pv
```

A mismatch between `.env` and any live `spec.nfs.server` value is configuration drift and must be resolved deliberately. Do not assume that editing `.env` alone updates existing storage objects.

The repository health check performs this consistency check:

```bash
cd /opt/k8s-ansible
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/cluster-health-check.sh
```

Validate PVC and mount state:

```bash
sudo k3s kubectl -n otp-relay get pvc
sudo k3s kubectl -n otp-relay get pods -l app=otp-relay -o name | while read -r pod; do
  echo "=== ${pod} ==="
  sudo k3s kubectl -n otp-relay exec "${pod#pod/}" -- sh -c '
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

## Existing PVC migration rule

Before moving an existing live deployment from local-path/RWO to NFS/RWX:

1. Stop or scale workloads safely if needed.
2. Back up existing `/app/data` contents.
3. Confirm the NFS export exists.
4. Confirm Kubernetes can mount the NFS export.
5. Restore app data onto the NFS export.
6. Apply NFS PV/PVC configuration.
7. Restart app and monitor workloads.
8. Verify `users.xlsx`, config files, wizard state, and `audit.log` exist.
9. Verify app pod write access.
10. Verify monitor can read the shared audit log.

Do not delete old PVC data until the NFS-backed deployment is verified.

---

## Redis deployment model

Redis is required for the current multi-replica posture.

Expected app Redis connection:

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

The app should connect through:

```text
otp-redis-haproxy:6379
```

The app should not connect directly to a single Redis pod.

Validate Redis posture:

```bash
sudo k3s kubectl -n otp-relay get pods -o wide | grep -E 'otp-redis|sentinel|haproxy'
sudo k3s kubectl -n otp-relay get svc | grep -E 'otp-redis|sentinel|haproxy'
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

- Redis pods are Running.
- Sentinel pods are Running.
- HAProxy pods are Running.
- `/readyz` reports Redis healthy.

---

## Redis StatefulSet update safety

Kubernetes does not allow normal patch updates to some StatefulSet fields after creation.

A normal update may fail with:

```text
The StatefulSet "otp-redis" is invalid: spec: Forbidden: updates to statefulset spec for fields other than ...
```

Normal deployment or update behavior must not:

- silently delete the Redis StatefulSet
- delete Redis PVCs
- recreate Redis as a side effect of unrelated changes
- treat Redis data loss as acceptable by default

Safe behavior is one of:

1. preserve the existing StatefulSet and continue with a clear warning,
2. fail clearly and require an explicit maintenance action,
3. run a documented destructive Redis reset only when intentionally approved.

Before any destructive Redis action, inspect:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay get pvc
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis -o wide
```

A normal application, documentation, frontend, workflow, or observability update must not destroy Redis data.

---

## Observability deployment hook

Observability resources live under:

```text
k8s/observability/
```

The deployment guide only describes how observability is attached to deployment. Dashboard queries and Grafana troubleshooting belong in:

```text
docs/operations/observability-and-grafana.md
```

Current Grafana hostname:

```text
grafana-srvotptest26.init-db.lan
```

Grafana dashboard source-generated model:

```text
Source:     k8s/observability/dashboards/otp-relay-live.json
Generated:  k8s/observability/grafana-dashboard-otp-relay-live.yaml
Generator:  scripts/build_grafana_dashboard_configmap.py
```

---

## Generated assets during deployment

The installer is responsible for generating required deployment artifacts.

Generated paths:

```text
frontend/app.js
frontend/help/
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Source paths:

```text
frontend/app.jsx
docs/help/
docs/help/assets/
k8s/observability/dashboards/otp-relay-live.json
```

Do not edit generated files as source.

For build rules, see:

```text
docs/development/build-and-development-guide.md
```

---

## Manual image build fallback

The installer path is preferred.

Manual image build is only a fallback for controlled operation from the build/control-plane host.

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
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout restart deployment/otp-monitor
sudo k3s kubectl -n otp-relay rollout status deployment/otp-relay
sudo k3s kubectl -n otp-relay rollout status deployment/otp-monitor
```

---

## Post-deployment verification

Run these after deployment:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n otp-relay get pods -o wide
sudo k3s kubectl -n otp-relay get svc
sudo k3s kubectl -n otp-relay get ingress -o wide
sudo k3s kubectl -n otp-relay get pvc
sudo k3s kubectl get pv \
  -o custom-columns='PV:.metadata.name,STATUS:.status.phase,NFS_SERVER:.spec.nfs.server,NFS_PATH:.spec.nfs.path'
sudo k3s kubectl -n kube-system get svc traefik -o wide
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected:

- nodes are Ready
- app pods are Running/Ready
- monitor pod is Running/Ready
- Redis/Sentinel/HAProxy pods are Running/Ready
- PVC is Bound
- Traefik has the expected MetalLB IP
- `/healthz` returns 200
- `/readyz` returns 200 with Redis healthy
- monitor health script reports OK

For complete operational validation, see:

```text
docs/operations/operations-and-validation-runbook.md
```

---

## Deployment troubleshooting scope

This guide covers deployment-specific failure areas only.

For day-to-day operations and validation, use:

```text
docs/operations/operations-and-validation-runbook.md
```

For Grafana/Prometheus/Loki/Alloy, use:

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
sudo k3s kubectl -n otp-relay get pods -o wide | grep -E 'redis|haproxy'
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl -n otp-relay logs deployment/otp-redis-haproxy --tail=100
```

### NFS-backed workloads fail after deployment or NFS restart

First verify that `.env` and the live NFS PVs point to the same server:

```bash
cd /opt/k8s-ansible

grep '^NFS_SERVER=' .env

sudo k3s kubectl get pv \
  -o custom-columns='PV:.metadata.name,STATUS:.status.phase,NFS_SERVER:.spec.nfs.server,NFS_PATH:.spec.nfs.path,CLAIM:.spec.claimRef.name'
```

If Redis pods are `Running` but `0/1 Ready`, relay pods return readiness `503`, or the problem started after the NFS VM restarted or changed address, treat an NFS server mismatch as a primary check.

If the NFS server values are correct, then check PVC state and permissions:

```bash
sudo k3s kubectl -n otp-relay describe pvc otp-relay-data
sudo k3s kubectl -n otp-relay exec deployment/otp-relay -- ls -l /app/data
```

On the NFS server, verify that the export is active and that ownership and permissions match the UID/GID expected by the container.

### Redis StatefulSet apply fails

Treat this as an immutable-field update issue.

Do not delete Redis PVCs during a normal update.

Inspect:

```bash
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay get pvc
```

Use the documented maintenance/reset path only if destructive Redis recreation is intentionally approved.

### Grafana hostname does not open in browser

First test from the control-plane host:

```bash
curl -I -H "Host: grafana-srvotptest26.init-db.lan" http://172.31.11.121/
```

Expected:

```text
HTTP/1.1 302 Found
Location: /login
```

If this works, Kubernetes is routing correctly and the remaining issue is client DNS or network access.

---

## Files never to commit

```text
.env
secret.env
runtime tokens
Telegram credentials
SMS secret token
production users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
*.tar
*.log
```

---

## Deployment sign-off checklist

Use this as a lightweight checklist. Detailed destructive validation belongs in the operations runbook.

- [ ] `.env` exists and contains intended runtime values.
- [ ] Repository sync is configured or the manual sync process is understood.
- [ ] Installer runs without replacing `.env` unexpectedly.
- [ ] Required generated assets are produced before image build/apply.
- [ ] App and monitor images build successfully.
- [ ] K3s imports the expected images.
- [ ] Kubernetes resources apply cleanly.
- [ ] Redis StatefulSet is not destructively recreated during normal update.
- [ ] NFS PVC is Bound.
- [ ] `.env` `NFS_SERVER` matches the live `spec.nfs.server` value of every OTP Relay and Redis NFS PV.
- [ ] The NFS endpoint is stable and is not dependent on a changing DHCP address.
- [ ] App can write to `/app/data`.
- [ ] Monitor can read `/app/data/audit.log`.
- [ ] `/healthz` returns 200.
- [ ] `/readyz` returns 200 with Redis healthy.
- [ ] Monitor health script reports OK.
- [ ] Portal hostname resolves to the Traefik/MetalLB IP.
- [ ] In production, Grafana hostname resolves to the production Traefik/MetalLB IP and Grafana is accessed through Ingress.
- [ ] Any DEV-only `grafana-direct` LoadBalancer/IP workaround is excluded from production configuration.
- [ ] Telegram alerting configuration is present when alerts are expected.
- [ ] OTP business-flow validation is completed before production sign-off.
- [ ] IT certificate/DNS work is completed or explicitly tracked as pending.
- [ ] Redis backup/restore procedure is documented.
- [ ] Final production LB/VIP model is confirmed if required.
