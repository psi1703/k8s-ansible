OTP Relay Kubernetes

Repository: psi1703/k8s-ansible
License: MIT
Status: K3s automation baseline refreshed on 2026-07-01 after NFS hostname, Redis placement, and Grafana environment-password updates

Overview

OTP Relay is an internal LAN-only One-Time Password relay portal deployed on Kubernetes using K3s.

It allows OTP values received on the company iPhone to be relayed to an authenticated browser user through the portal. OTP values are runtime-only and must not be written to disk, logs, manifests, automation output, or committed files.

The deployment uses:

K3s

Traefik ingress

FastAPI portal app

React frontend

Redis StatefulSet with Sentinel and HAProxy

NFS-backed RWX application storage

NFS-backed Redis persistent volumes when REDIS_STORAGE_CLASS="otp-redis-nfs"

monitor pod for phone presence and alerting

Telegram alerts

Prometheus, Grafana, Loki, and Alloy for observability

local repository sync script and optional systemd timer

Current access paths

Portal is controlled by .env:

TLS_HOST="srvotptest26.init-db.lan"

Expected portal URL when TLS is enabled:

https://srvotptest26.init-db.lan

Grafana is also controlled by .env:

GRAFANA_HOST="grafana-test.lan"

Expected Grafana URL:

https://grafana-test.lan

Grafana should normally be accessed through Traefik/IngressRoute. Port-forwarding is only for temporary debugging.

Current architecture summary

Client browser
  -> internal DNS
  -> Traefik HTTPS ingress
  -> otp-relay Kubernetes service
  -> FastAPI app pods
  -> Redis HAProxy
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data for persistent non-OTP files

iPhone
  -> receives OTP SMS
  -> iOS Shortcut posts SMS body to /sms-received
  -> portal stores pending OTP state in Redis with TTL
  -> browser polling displays OTP to the active user

Monitor pod
  -> hostNetwork + NET_RAW
  -> phone presence checks
  -> audit-log checks
  -> Prometheus metrics
  -> Telegram alerts
  -> no Service
  -> no Ingress

Observability
  -> kube-prometheus-stack
  -> Grafana
  -> Prometheus and Alertmanager
  -> Loki
  -> Alloy
  -> OTP Relay dashboard and ServiceMonitor manifests

For the full architecture and SCH gap analysis, see:

docs/architecture/current-architecture-and-sch-gap-analysis.md

Documentation

Detailed documentation lives under docs/.

Recommended reading order:

Area

Document

Documentation index

docs/README.md

Architecture and SCH gap analysis

docs/architecture/current-architecture-and-sch-gap-analysis.md

Deployment and storage

docs/deployment/deployment-and-storage-guide.md

Operations and validation

docs/operations/operations-and-validation-runbook.md

Observability and Grafana

docs/operations/observability-and-grafana.md

Build and development

docs/development/build-and-development-guide.md

Portal help source

docs/help/

Source-of-truth rules

Area

Source

Generated output

Runtime configuration

.env

rendered manifests and runtime configuration

Frontend

frontend/app.jsx

frontend/app.js

Help docs

docs/help/*.md, docs/help/assets/*

frontend/help/*

Grafana dashboard

k8s/observability/dashboards/otp-relay-live.json

k8s/observability/grafana-dashboard-otp-relay-live.yaml

Build/generation commands:

python3 scripts/build_help_docs.py
python3 scripts/build_grafana_dashboard_configmap.py

Do not edit generated files as source.

Repository sync behavior

The build/server machine should sync this repository locally using the repo-sync script and optional systemd timer.

The local checkout path is normally:

/opt/k8s-ansible

Repository updates are handled by:

cd /opt/k8s-ansible
bash scripts/sync-repo.sh

For automatic polling, install the optional systemd timer:

cd /opt/k8s-ansible
bash scripts/install-repo-sync-timer.sh

The sync script may fetch GitHub and hard reset the local checkout to the configured branch, while preserving local runtime files such as .env, generated inventory, release artifacts, and local build state. It must not deploy the application, run Helm, apply Kubernetes manifests, install K3s, import images into a live cluster, or call the installer.

Deployment is intentionally controlled from the server with:

cd /opt/k8s-ansible
bash setup.sh

This keeps .env, runtime state, generated inventory, SSH keys, K3s state, and production validation under operator control on the server.

First install flow

Before running a real install, run the non-mutating health check:

cd /opt/k8s-ansible
bash setup.sh --doctor

--doctor checks the repository layout, key script syntax, .env syntax and consistency, local K3s status, generated Ansible inventory, worker SSH reachability when inventory exists, NFS/TLS/Ingress placeholders, and required host commands.

It does not create .env, provision worker VMs, install K3s, run Ansible, apply manifests, or change system state.

Normal first install:

cd /opt/k8s-ansible
bash setup.sh

Do not run the main orchestration as sudo bash setup.sh. The normal path is to run bash setup.sh as the operator user and let the scripts use sudo internally where required.

After a successful install, the installer writes an operator handover report:

/opt/k8s-ansible/install-report.txt

Use that report for a concise view of the portal URL, Grafana URL, namespace, service/ingress/TLS state, NFS state, Redis state, pods, services, PVCs, and useful validation commands.

Environment file behavior

.env is the single source of operator-provided deployment values.

Normal behavior:

A valid existing .env is reused.

Normal update runs must not silently overwrite .env.

Incomplete, cancelled, or syntactically broken .env files are rejected safely.

Rejected files are backed up as .env.rejected.<timestamp> before a clean .env is recreated.

Secrets must stay in .env or Kubernetes Secrets, not in committed files.

Recommended pre-install check:

bash setup.sh --doctor

Useful recovery artifacts:

.env.rejected.<timestamp>
install-report.txt
/var/backups/otp-relay-k8s/

Core .env example

Adjust values for the target environment:

NAMESPACE="otp-relay"

INGRESS_ENABLED="1"
TLS_ENABLED="1"
TLS_HOST="srvotptest26.init-db.lan"
TLS_SECRET_NAME="otp-relay-tls"
TLS_SELF_SIGNED="1"
TLS_ROTATE_SELF_SIGNED="0"

PVC_STORAGE_CLASS="otp-relay-nfs"
NFS_ENABLED="1"
NFS_SERVER="nfs-vm"
NFS_PATH="/export/otp-relay-data"
NFS_STORAGE_CLASS="otp-relay-nfs"

REDIS_ENABLED="1"
REDIS_URL="redis://otp-redis-haproxy:6379/0"
REDIS_REQUIRED="1"
REDIS_STORAGE_CLASS="otp-redis-nfs"
REDIS_SIZE="1Gi"
REDIS_SPREAD_RECREATE_PVCS="auto"

OBSERVABILITY_NAMESPACE="observability"
OBSERVABILITY_INSTALL_STACK="1"
OBSERVABILITY_STACK_CHART_VERSION="85.0.1"
GRAFANA_HOST="grafana-test.lan"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD=""
GRAFANA_ADMIN_SECRET_NAME="kube-prometheus-stack-grafana"

If GRAFANA_ADMIN_PASSWORD is empty, kube-prometheus-stack/Helm may generate or preserve the Grafana admin password in the Grafana Secret.

If GRAFANA_ADMIN_PASSWORD is set, the installer creates or updates the Grafana admin Secret and instructs Helm to use it.

NFS behavior

The preferred NFS model is hostname-based, not hardcoded DHCP IP-based.

Recommended .env:

NFS_ENABLED="1"
NFS_SERVER="nfs-vm"
NFS_PATH="/export/otp-relay-data"
PVC_STORAGE_CLASS="otp-relay-nfs"
REDIS_STORAGE_CLASS="otp-redis-nfs"

All K3s nodes must resolve nfs-vm and be able to reach the NFS exports.

Verify from the Ansible runner:

cd /opt/k8s-ansible

ansible all   -i automation/ansible/inventory.generated.ini   -b   -m shell   -a 'getent hosts nfs-vm && showmount -e nfs-vm'

Expected exports include:

/export/otp-relay-data
/export/otp-redis-0
/export/otp-redis-1
/export/otp-redis-2

When using the unified /export/otp-relay-data path for Redis, the installer expects Redis subdirectories similar to:

/export/otp-relay-data/redis/otp-redis-0
/export/otp-relay-data/redis/otp-redis-1
/export/otp-relay-data/redis/otp-redis-2

Check rendered PVs after install:

sudo k3s kubectl get pv | grep -E 'otp-redis|otp-relay-data'

sudo k3s kubectl get pv   otp-redis-0-nfs-pv   otp-redis-1-nfs-pv   otp-redis-2-nfs-pv   otp-relay-data-nfs-pv   -o yaml | grep -E 'server:|path:'

Expected server value:

server: nfs-vm

Redis placement requirement

Redis runs as a 3-pod StatefulSet with hard one-per-host scheduling behavior.

Because Redis uses:

replicas: 3
nodeSelector: otp-relay/redis-node=true
topology spread: kubernetes.io/hostname with DoNotSchedule

all three cluster nodes must be Redis-eligible in the current 1 control-plane + 2 workers design.

Required Redis label state:

debian        otp-relay/redis-node=true
otp-worker1   otp-relay/redis-node=true
otp-worker2   otp-relay/redis-node=true

The control-plane must keep monitor eligibility but must also be Redis eligible. The application pods should remain worker-only.

Verify labels:

sudo k3s kubectl get nodes   -L otp-relay/app-node,otp-relay/redis-node,otp-relay/storage-node,otp-relay/monitor-node

Verify Redis placement:

sudo k3s kubectl -n otp-relay get pods -o wide | grep otp-redis

Expected result:

otp-redis-0   Running   ...   one cluster node
otp-redis-1   Running   ...   different cluster node
otp-redis-2   Running   ...   different cluster node

TLS and internal HTTPS behavior

The preferred internal access model is Traefik ingress with DNS pointing to the server/load-balancer address.

Important TLS settings:

TLS_ENABLED="1"
TLS_HOST="srvotptest26.init-db.lan"
TLS_SECRET_NAME="otp-relay-tls"
TLS_SELF_SIGNED="1"
TLS_ROTATE_SELF_SIGNED="0"

Behavior:

TLS_ENABLED=0 leaves the portal on HTTP ingress/service behavior.

TLS_ENABLED=1 enables HTTPS ingress configuration.

TLS_SELF_SIGNED=1 lets the installer create the Kubernetes TLS secret only when the secret is missing.

Existing self-signed TLS secrets are preserved by default.

TLS_ROTATE_SELF_SIGNED=1 intentionally replaces the existing self-signed certificate.

TLS_SELF_SIGNED=0 requires the Kubernetes TLS secret to exist before the installer runs.

To export the self-signed certificate for IT Group Policy distribution:

sudo k3s kubectl get secret otp-relay-tls   -n otp-relay   -o jsonpath='{.data.tls\.crt}' | base64 -d > otp-relay.crt

Do not rotate the certificate after IT has trusted/distributed it unless the rotation is intentional.

Grafana credentials

Grafana credentials are controlled by these .env values:

GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD=""
GRAFANA_ADMIN_SECRET_NAME="kube-prometheus-stack-grafana"

Behavior:

If GRAFANA_ADMIN_PASSWORD is blank, the installer leaves Grafana password generation/preservation to Helm and the existing Kubernetes Secret.

If GRAFANA_ADMIN_PASSWORD is set, the installer creates or updates the Secret named by GRAFANA_ADMIN_SECRET_NAME.

The default Secret is kube-prometheus-stack-grafana in the observability namespace.

The Secret keys are admin-user and admin-password.

Read the current Grafana credentials:

sudo k3s kubectl get secret kube-prometheus-stack-grafana   -n observability   -o jsonpath='{.data.admin-user}' | base64 -d; echo

sudo k3s kubectl get secret kube-prometheus-stack-grafana   -n observability   -o jsonpath='{.data.admin-password}' | base64 -d; echo

Change Grafana password persistently through .env:

GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="YourStrongPasswordHere"
GRAFANA_ADMIN_SECRET_NAME="kube-prometheus-stack-grafana"

Then run observability-only:

cd /opt/k8s-ansible
DEPLOY_MODE=observability bash setup.sh

Or run the full orchestration:

cd /opt/k8s-ansible
bash setup.sh

Deployment

Normal deployment is local/server controlled:

cd /opt/k8s-ansible
bash setup.sh

Repository synchronization is separate from deployment:

cd /opt/k8s-ansible
bash scripts/sync-repo.sh

The sync script and optional timer must not call:

install-otp-relay-k8s.sh
helm
kubectl apply
k3s install scripts
Ansible deploy tasks that mutate the live cluster

Installer logic belongs in repository scripts. Repository sync must only update the local checkout.

Quick health check

Pre-install or troubleshooting health check:

cd /opt/k8s-ansible
bash setup.sh --doctor

Cluster and application health check:

cd /opt/k8s-ansible
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/cluster-health-check.sh

The script writes a timestamped log under /tmp by default.

Expected successful result:

OK: OTP Relay Kubernetes stack health check passed.

Quick manual checks:

sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -n otp-relay -o wide
sudo k3s kubectl get pods -n observability -o wide
curl -k https://srvotptest26.init-db.lan/healthz
curl -k https://srvotptest26.init-db.lan/readyz

Install report:

cat /opt/k8s-ansible/install-report.txt

For the full runbook, see:

docs/operations/operations-and-validation-runbook.md

Expected successful workload layout

A healthy current install should show:

3/3 Kubernetes nodes Ready

otp-relay namespace:
  otp-relay                 2/2 Running
  otp-monitor               1/1 Running
  otp-redis                 3/3 Running
  otp-redis-haproxy         2/2 Running
  otp-redis-sentinel        3/3 Running

observability namespace:
  kube-prometheus-stack
  Grafana
  Prometheus
  Alertmanager
  Loki
  Alloy

Redis should be spread across all three Kubernetes nodes.

The OTP app pods should run on worker nodes.

The monitor pod should run on the control-plane.

Important operational rules

.env is the source of operator-provided deployment values.

Normal updates must not overwrite .env silently.

Broken or incomplete .env files are backed up as .env.rejected.<timestamp> before recovery.

Run bash setup.sh --doctor before first install or when troubleshooting setup state.

Run normal orchestration with bash setup.sh, not sudo bash setup.sh.

Repository sync is local/server controlled and must not directly deploy to the cluster.

Redis is required in the current Kubernetes validation posture.

Redis requires three Redis-eligible Kubernetes nodes when replicas=3 and hard spread is enabled.

Normal updates must not destructively recreate Redis StatefulSet or Redis PVC resources.

NFS should use a stable hostname such as nfs-vm, not a changing DHCP IP.

OTP values must not be written to disk or logs.

The monitor must remain internal only: no Service and no Ingress.

Telegram is the active monitor alerting path.

frontend/app.jsx is the frontend source; frontend/app.js is generated.

Grafana dashboard source is JSON; the ConfigMap YAML is generated.

Grafana admin credentials should be managed through .env and the Kubernetes Secret, not committed files.

Self-signed TLS secrets are not rotated on normal installer reruns.

Set TLS_ROTATE_SELF_SIGNED=1 only when certificate replacement is intentional.

Re-run validation after future changes to OTP flow, Redis state handling, frontend polling, Kubernetes placement, observability, or deployment workflow behavior.

Files not to commit

.env
.env.rejected.*
secret.env
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
install-report.txt
*.tar
*.tar.gz
*.tgz
*.zip
*.log
runtime tokens
Telegram credentials
SMS secrets
Grafana admin passwords
local kubeconfig files
private keys

Current production-alignment items

Current baseline refreshed on 2026-07-01 after:

repository sync aligned to local script/timer behavior

install path confirmed as bash setup.sh

NFS storage aligned to hostname-based NFS_SERVER="nfs-vm"

Redis NFS PV/PVC rendering fixed

Redis 3-node scheduling fixed by allowing the control-plane to be Redis eligible

Grafana admin credentials added as .env-controlled observability settings

Validated in the current design:

three K3s nodes Ready

two OTP Relay app replicas

monitor pod on control-plane

Redis StatefulSet 3/3 spread across all three nodes

Redis Sentinel and HAProxy available

NFS-backed app PVC

NFS-backed Redis PVCs

Traefik ingress for portal

observability stack managed through kube-prometheus-stack, Loki, and Alloy

Remaining production-alignment items:

IT certificate trust rollout or approved certificate installation

SCH decision on Redis Sentinel/HAProxy versus managed Redis

Redis backup/restore procedure

final production LB/VIP decision if SCH requires more than current Traefik/internal DNS

optional full production validation run when VALIDATE_OTP_RELAY=1
