# Deployment and Storage Guide

## Purpose

This guide is the single deployment reference for OTP Relay Kubernetes. It combines the previous GitHub Actions deployment guide, K3s setup notes, manual image fallback, NFS shared-storage migration notes, Redis HA deployment notes, and observability deployment validation.

## Recommended deployment path

Use GitHub Actions with the self-hosted runner.

```text
git push to main
  -> GitHub Actions job starts
  -> self-hosted runner checks out the repo
  -> installer syncs /opt/otp-relay-k8s to origin/main
  -> installer builds frontend app.js and help docs
  -> installer generates the Grafana dashboard ConfigMap
  -> installer builds/imports app and monitor images
  -> installer renders/applies Kubernetes resources
  -> installer waits for rollouts
```

The workflow intentionally calls `install-otp-relay-k8s.sh` instead of duplicating deployment logic in YAML.

## Required GitHub Actions secrets

Create these in GitHub Actions secrets:

```text
PHONE_IP
PHONE_INTERFACE
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
PORTAL_URL
```

Do not commit Telegram credentials, runtime tokens, generated secrets, or `.env` files.

## Current Phase 3 deployment defaults

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
REPLICA_COUNT=2
```

The portal is exposed through Traefik Ingress. The `otp-relay` service remains internal to the cluster and is used as the Ingress backend.

## Traefik and TLS

The current validation path uses:

- Traefik Ingress for HTTP/HTTPS routing.
- Kubernetes TLS secret for HTTPS.
- Self-signed TLS until IT distributes/trusts the certificate by Group Policy.
- Internal DNS name `srvotptest26.init-db.lan`.

Validate exposure after deployment:

```bash
kubectl get svc -n otp-relay
kubectl get ingress -n otp-relay
kubectl get secret otp-relay-tls -n otp-relay
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected:

- Ingress host is `srvotptest26.init-db.lan`.
- TLS secret exists.
- `/healthz` returns 200.
- `/readyz` returns 200 with Redis healthy and Redis required.

## NFS/RWX application storage

The app data PVC should use shared NFS/RWX storage after migration.

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

## Existing PVC migration rule

Before moving an existing live deployment from local-path/RWO to NFS/RWX:

1. Scale the app and monitor safely if needed.
2. Back up the existing `/app/data` contents.
3. Confirm the NFS export exists and is mounted by Kubernetes.
4. Restore app data onto the NFS export.
5. Apply `pv-nfs.yaml` and the updated PVC settings.
6. Restart the app and monitor.
7. Verify that `users.xlsx`, config files, wizard progress, and `audit.log` are present.

Do not delete old PVC data until the NFS-backed deployment is verified.

## Redis deployment model

Redis is required in the Phase 3 validation posture.

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

`otp-redis-haproxy` routes to the current Redis master based on Sentinel state. App pods should not connect directly to a single Redis pod.

## Observability deployment model

Observability resources live under:

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

The Grafana dashboard source of truth is:

```text
k8s/observability/dashboards/otp-relay-live.json
```

The generated ConfigMap consumed by Grafana sidecar provisioning is:

```text
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Regenerate after editing the dashboard source:

```bash
python3 scripts/build_grafana_dashboard_configmap.py
```

Validate generated dashboard metadata:

```bash
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Apply manually if needed:

```bash
kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

## Frontend and help generated files

The portal serves the generated frontend bundle:

```text
frontend/app.js
```

The React source is:

```text
frontend/app.jsx
```

Rules:

- Edit `frontend/app.jsx`.
- Rebuild `frontend/app.js`.
- Commit both when frontend behavior changes.
- Do not edit `frontend/app.js` directly as source.

Help docs source:

```text
docs/help/
docs/help/assets/
```

Generated help output:

```text
frontend/help/
```

Build command:

```bash
python3 scripts/build_help_docs.py
```

## Manual image build fallback

GitHub Actions is preferred. Manual build is only a fallback.

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
kubectl rollout restart deployment/otp-relay -n otp-relay
kubectl rollout restart deployment/otp-monitor -n otp-relay
kubectl rollout status deployment/otp-relay -n otp-relay
kubectl rollout status deployment/otp-monitor -n otp-relay
```

## Post-deployment verification

Run these after deployment:

```bash
kubectl get pods -n otp-relay -o wide
kubectl get svc -n otp-relay
kubectl get ingress -n otp-relay
kubectl get pvc -n otp-relay
kubectl get pods -n observability -o wide
kubectl get svc -n observability
kubectl get configmap otp-relay-live-dashboard -n observability
kubectl get servicemonitor -n observability
kubectl logs -n otp-relay deployment/otp-relay --tail=100
kubectl logs -n otp-relay deployment/otp-monitor --tail=100
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
```

Expected `/readyz` result should include Redis healthy and Redis required.

Expected observability state:

- Grafana pod is Running/Ready.
- Prometheus pod is Running/Ready.
- `otp-relay-live-dashboard` ConfigMap exists.
- ServiceMonitor resources exist for portal and monitor.
- Dashboard JSON contains `refresh: 15s` and `timepicker.refresh_intervals`.

Validate the live dashboard ConfigMap:

```bash
kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

## Files never to commit

```text
.env
secret.env
Runtime tokens or Telegram credentials
users.xlsx production copy
admin_auth.json
admin_config.json
audit.log
*.tar
*.log
```
