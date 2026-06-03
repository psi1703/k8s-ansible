# Deployment and Storage Guide

## Purpose

This guide is the deployment and storage reference for OTP Relay Kubernetes.

It covers:

* GitHub Actions deployment through the self-hosted runner
* installer behavior
* `.env` source-of-truth configuration
* K3s deployment expectations
* Traefik/TLS exposure
* NFS/RWX application storage
* Redis Sentinel/HAProxy deployment
* Redis StatefulSet update safety
* observability deployment
* generated frontend/help/Grafana assets
* post-deployment verification

---

## Recommended deployment path

Use GitHub Actions with the self-hosted runner.

```text id="h9nr4r"
GitHub push or workflow run
  -> GitHub Actions job starts
  -> self-hosted runner checks out the repo
  -> installer runs from the runner/control-plane host
  -> installer loads or creates .env
  -> installer builds frontend app.js and help docs
  -> installer generates the Grafana dashboard ConfigMap
  -> installer builds/imports app and monitor images
  -> installer renders Kubernetes resources from .env
  -> installer applies Kubernetes resources
  -> installer applies observability resources when enabled
  -> installer waits for rollouts
  -> installer prints deployment summary
```

The workflow should call `install-otp-relay-k8s.sh`.

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

```text id="fxwjz4"
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

Do not place site-specific values directly in Python, shell scripts, Kubernetes YAML, or Ansible task files.

---

## Required GitHub Actions secrets

Create these in GitHub Actions secrets when the workflow expects them:

```text id="1f3jcg"
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

```text id="5l42bu"
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

Two app replicas are the intended HA posture, but final approval requires OTP business-flow validation after the latest source/build/workflow changes.

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

VM provisioning should create worker VMs only.

The external NFS server should not be joined to Kubernetes.

Known node labels:

```text id="1jk8c9"
otp-relay/storage-node=true
otp-relay/monitor-node=true
```

The monitor should run on the node with phone-network visibility.

Redis-capable nodes should be labelled with:

```text id="dfd4o0"
otp-relay/storage-node=true
```

---

## Traefik and TLS

The current validation path uses:

* Traefik Ingress for HTTP/HTTPS routing
* Kubernetes TLS secret for HTTPS
* self-signed TLS until IT distributes/trusts the certificate
* internal DNS name `srvotptest26.init-db.lan`

Validate exposure after deployment:

```bash id="fm57ly"
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

```text id="fgtgoi"
NFS server: 172.31.11.108
NFS path:   /export/otp-relay-data
```

Expected Kubernetes storage:

```text id="ah57fl"
PV:            otp-relay-data-nfs-pv
PVC:           otp-relay-data
StorageClass:  otp-relay-nfs
Access mode:   ReadWriteMany
Mount path:    /app/data
```

Expected files in `/app/data`:

```text id="jl6inq"
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

The monitor also reads the shared audit log from this storage path.

OTP values must not be written to the NFS-backed files.

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

```bash id="z8d1hm"
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

```text id="extk5j"
WRITE_OK
```

from each app pod.

---

## Redis deployment model

Redis is required in the Phase 3 validation posture.

```text id="eptvml"
REDIS_REQUIRED=1
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

Redis components:

```text id="rhi9ds"
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

```text id="748q30"
REDIS_URL=redis://otp-redis-haproxy:6379/0
```

`otp-redis-haproxy` routes to the current Redis master based on Sentinel state.

App pods should not connect directly to a single Redis pod.

---

## Redis StatefulSet update safety

Kubernetes does not allow normal `apply`/patch updates to some StatefulSet fields after the StatefulSet is created.

A normal update may fail with:

```text id="idskx6"
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

```bash id="iu3mfe"
sudo k3s kubectl -n otp-relay get statefulset otp-redis -o yaml
sudo k3s kubectl -n otp-relay get pvc
sudo k3s kubectl -n otp-relay get pods -l app=otp-redis -o wide
```

A normal application, documentation, workflow, frontend, or observability update should not destroy Redis data.

---

## Redis verification

List Redis-related pods:

```bash id="tg4dhd"
sudo k3s kubectl get pods -n otp-relay -o wide | grep -E 'redis|haproxy'
```

Check Redis services:

```bash id="fdynii"
sudo k3s kubectl get svc -n otp-relay | grep redis
```

Check Sentinel-reported master:

```bash id="4clv73"
SENTINEL_POD=$(sudo k3s kubectl -n otp-relay get pod \
  -l app=otp-redis-sentinel \
  -o jsonpath='{.items[0].metadata.name}')

sudo k3s kubectl -n otp-relay exec "$SENTINEL_POD" -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

Check logs:

```bash id="knygss"
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
```

---

## Observability deployment model

Observability resources live under:

```text id="k1vdpz"
k8s/observability/
```

Important files:

```text id="nlnp7l"
k8s/observability/prometheus-stack-values.yaml
k8s/observability/loki-values.yaml
k8s/observability/alloy-values.yaml
k8s/observability/grafana-ingressroute.yaml
k8s/observability/servicemonitor-otp-relay.yaml
k8s/observability/servicemonitor-otp-monitor.yaml
k8s/observability/dashboards/otp-relay-live.json
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Normal Grafana access:

```text id="9zyywk"
https://grafana.init-db.lan
```

The Grafana dashboard source of truth is:

```text id="1hny93"
k8s/observability/dashboards/otp-relay-live.json
```

The generated ConfigMap consumed by Grafana sidecar provisioning is:

```text id="kv2a6q"
k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Regenerate after editing the dashboard source:

```bash id="ttekli"
python3 scripts/build_grafana_dashboard_configmap.py
```

Validate generated dashboard metadata:

```bash id="75v5fl"
grep -n '"refresh"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"timepicker"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
grep -n '"refresh_intervals"' k8s/observability/grafana-dashboard-otp-relay-live.yaml
```

Apply manually if needed:

```bash id="lquz0f"
sudo k3s kubectl apply -f k8s/observability/grafana-dashboard-otp-relay-live.yaml
sudo k3s kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
sudo k3s kubectl rollout status deployment/kube-prometheus-stack-grafana -n observability
```

---

## Frontend and help generated files

The portal serves the generated frontend bundle:

```text id="2vig94"
frontend/app.js
```

The React source is:

```text id="ipvsw9"
frontend/app.jsx
```

Rules:

* Edit `frontend/app.jsx`.
* Rebuild `frontend/app.js`.
* Commit both when frontend behavior changes.
* Do not edit `frontend/app.js` directly as source.
* Do not use browser-side Babel in production.

Help docs source:

```text id="f1eiwf"
docs/help/
docs/help/assets/
```

Generated help output:

```text id="0bphbp"
frontend/help/
```

Build command:

```bash id="2woqln"
python3 scripts/build_help_docs.py
```

---

## Manual image build fallback

GitHub Actions is preferred.

Manual build is only a fallback when intentionally operating from the runner/control-plane host.

Build locally from the repo root:

```bash id="7m0026"
docker build -t otp-relay:latest -f k8s/Dockerfile .
docker build -t otp-monitor:latest -f k8s/Dockerfile.monitor .
```

Export images:

```bash id="gj5glv"
docker save otp-relay:latest -o otp-relay-latest.tar
docker save otp-monitor:latest -o otp-monitor-latest.tar
```

Import on the K3s node:

```bash id="6vuqs9"
sudo k3s ctr images import otp-relay-latest.tar
sudo k3s ctr images import otp-monitor-latest.tar
```

Restart workloads:

```bash id="oibwz1"
sudo k3s kubectl rollout restart deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout restart deployment/otp-monitor -n otp-relay
sudo k3s kubectl rollout status deployment/otp-relay -n otp-relay
sudo k3s kubectl rollout status deployment/otp-monitor -n otp-relay
```

---

## Post-deployment verification

Run these after deployment:

```bash id="ckp2f6"
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get svc -n otp-relay
sudo k3s kubectl get ingress -n otp-relay
sudo k3s kubectl get pvc -n otp-relay
sudo k3s kubectl get pods -n observability -o wide
sudo k3s kubectl get svc -n observability
sudo k3s kubectl get ingressroute -n observability
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability
sudo k3s kubectl get servicemonitor -n observability
sudo k3s kubectl logs -n otp-relay deployment/otp-relay --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=100
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz
sudo /usr/local/bin/otp-relayk3s-monitor.sh
```

Expected `/readyz` result should include Redis healthy and Redis required.

Expected observability state:

* Grafana pod is Running/Ready.
* Prometheus pod is Running/Ready.
* Grafana IngressRoute exists when enabled.
* `otp-relay-live-dashboard` ConfigMap exists.
* ServiceMonitor resources exist for portal and monitor.
* Dashboard JSON contains `refresh: 15s` and `timepicker.refresh_intervals`.

Validate the live dashboard ConfigMap:

```bash id="o7dpzn"
sudo k3s kubectl get configmap otp-relay-live-dashboard -n observability \
  -o jsonpath='{.data.otp-relay-live\.json}' | grep -E '"refresh":|"timepicker"|"refresh_intervals"'
```

Validate Grafana browser access:

```text id="z0pc9g"
https://grafana.init-db.lan
```

---

## Deployment troubleshooting

### `/readyz` fails after deployment

Check Redis first when `REDIS_REQUIRED=1`:

```bash id="h1kfed"
curl -k https://srvotptest26.init-db.lan/readyz
sudo k3s kubectl get pods -n otp-relay -o wide | grep -E 'redis|haproxy'
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-sentinel --tail=100
sudo k3s kubectl logs -n otp-relay deployment/otp-redis-haproxy --tail=100
```

### Grafana does not load

Check:

```bash id="0g9tuo"
sudo k3s kubectl get ingressroute -n observability
sudo k3s kubectl get svc -n observability | grep grafana
sudo k3s kubectl get pods -n observability -o wide | grep grafana
```

Then confirm DNS from the client machine:

```bash id="b6y59p"
nslookup grafana.init-db.lan
```

### Monitor cannot detect phone

Check:

```bash id="g3bd7r"
sudo k3s kubectl logs -n otp-relay deployment/otp-monitor --tail=200
sudo k3s kubectl describe deployment otp-monitor -n otp-relay | grep -Ei 'PHONE|hostNetwork|NET_RAW'
```

Review `.env` values:

```text id="pi8w0j"
PHONE_IP
PHONE_INTERFACE
```

### NFS write fails

Check PVC and permissions:

```bash id="dypre3"
sudo k3s kubectl describe pvc otp-relay-data -n otp-relay
sudo k3s kubectl exec -n otp-relay deployment/otp-relay -- ls -l /app/data
```

On the NFS server, verify ownership/permissions for the app UID/GID expected by the container.

---

## Files never to commit

```text id="7bi8e0"
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

* [ ] `.env` exists and contains the intended runtime values.
* [ ] GitHub Actions workflow uses the self-hosted runner.
* [ ] Installer runs without replacing `.env` unexpectedly.
* [ ] Frontend bundle is generated from `frontend/app.jsx`.
* [ ] Help output is generated from `docs/help/`.
* [ ] Grafana dashboard ConfigMap is generated from `k8s/observability/dashboards/otp-relay-live.json`.
* [ ] App and monitor images build successfully.
* [ ] K3s imports the expected images.
* [ ] Kubernetes resources apply cleanly.
* [ ] Redis StatefulSet is not destructively recreated during a normal update.
* [ ] NFS PVC is Bound.
* [ ] App can write to `/app/data`.
* [ ] Monitor can read `/app/data/audit.log`.
* [ ] `/healthz` returns 200.
* [ ] `/readyz` returns 200 with Redis healthy.
* [ ] Monitor health script reports OK.
* [ ] Grafana loads at `https://grafana.init-db.lan`.
* [ ] Dashboard appears and auto-refreshes.
* [ ] Telegram alerting configuration is present when alerts are expected.
* [ ] OTP business-flow validation passes before declaring multi-replica posture complete.
