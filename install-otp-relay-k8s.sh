#!/usr/bin/env bash
set -Eeuo pipefail

# Safe one-click installer/update script for psi1703/k8s OTP Relay.
# Official exposure model:
#   client -> Traefik HTTPS Ingress -> otp-relay ClusterIP Service -> app pods
#
# Normal use:
#   sudo bash install-otp-relay-k8s.sh
#
# Installer controls:
#   REPO_URL, REPO_REF, INSTALL_DIR, NAMESPACE
#   APP_IMAGE, MONITOR_IMAGE, DEPLOY_MODE, GIT_CLEAN, NONINTERACTIVE
#   SKIP_HELP_DOCS_BUILD, RUNTIME_DATA_DIR
#
# Kubernetes topology/exposure controls:
#   SERVICE_TYPE=ClusterIP|NodePort|LoadBalancer
#   SERVICE_NODE_PORT=30080
#   LOADBALANCER_IP=172.31.x.x
#   INGRESS_ENABLED=0|1
#   TLS_ENABLED=0|1
#   TLS_HOST=srvotptest26.init-db.lan
#   TLS_SECRET_NAME=otp-relay-tls
#   TLS_SELF_SIGNED=0|1
#   PVC_STORAGE_CLASS=<storage-class-name>
#   PVC_SIZE=1Gi
#   NFS_ENABLED=0|1
#   NFS_SERVER=<nfs-server-ip-or-dns>
#   NFS_PATH=/export/otp-relay-data
#   NFS_STORAGE_CLASS=otp-relay-nfs
#   NFS_PV_NAME=otp-relay-data-nfs-pv
#   NFS_MOUNT_OPTIONS=nfsvers=4.1
#   REPLICA_COUNT=2
#   APP_NODE_SELECTOR_KEY=kubernetes.io/hostname
#   APP_NODE_SELECTOR_VALUE=<node-name>
#   MONITOR_NODE_SELECTOR_KEY=kubernetes.io/hostname
#   MONITOR_NODE_SELECTOR_VALUE=<node-name>
#   REDIS_NODE_SELECTOR_KEY=kubernetes.io/hostname
#   REDIS_NODE_SELECTOR_VALUE=<node-name>
#   REQUIRE_METALLB=0|1
#   INSTALL_METALLB=0|1
#   METALLB_VERSION=v0.15.3
#   METALLB_IP_RANGE=172.31.11.120-172.31.11.130
#   METALLB_POOL_NAME=otp-relay-pool
#
# Runtime ConfigMap inputs:
#   PHONE_IP, PHONE_INTERFACE, PHONE_PING_INTERVAL, PHONE_OFFLINE_THRESHOLD
#   PORTAL_URL
#
# Runtime Secret inputs:
#   SMS_SECRET_TOKEN, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#
# Optional GitHub runner setup:
#   INSTALL_GITHUB_RUNNER, GITHUB_RUNNER_URL, GITHUB_RUNNER_TOKEN,
#   GITHUB_RUNNER_DIR, RUNNER_ONLY


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for installer_lib in \
  common.sh \
  os.sh \
  github-runner.sh \
  docker.sh \
  deploy-mode.sh \
  k3s.sh \
  metallb.sh \
  tls.sh \
  manifests.sh \
  observability.sh \
  images.sh; do
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/scripts/lib/$installer_lib"
done

need_root
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_URL="${REPO_URL:-https://github.com/psi1703/k8s-ansible.git}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/k8s-ansible}"
NAMESPACE="${NAMESPACE:-otp-relay}"
APP_IMAGE="${APP_IMAGE:-otp-relay:latest}"
MONITOR_IMAGE="${MONITOR_IMAGE:-otp-monitor:latest}"

# Official production exposure default is ClusterIP app service plus Traefik Ingress.
SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"
SERVICE_NODE_PORT="${SERVICE_NODE_PORT:-30080}"
LOADBALANCER_IP="${LOADBALANCER_IP:-}"
INGRESS_ENABLED="${INGRESS_ENABLED:-1}"
TLS_ENABLED="${TLS_ENABLED:-1}"
TLS_HOST="${TLS_HOST:-srvotptest26.init-db.lan}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-otp-relay-tls}"
TLS_SELF_SIGNED="${TLS_SELF_SIGNED:-1}"

PVC_STORAGE_CLASS="${PVC_STORAGE_CLASS:-}"
PVC_SIZE="${PVC_SIZE:-1Gi}"
NFS_ENABLED="${NFS_ENABLED:-0}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-}"
NFS_STORAGE_CLASS="${NFS_STORAGE_CLASS:-otp-relay-nfs}"
NFS_PV_NAME="${NFS_PV_NAME:-otp-relay-data-nfs-pv}"
NFS_MOUNT_OPTIONS="${NFS_MOUNT_OPTIONS:-nfsvers=4.1}"

REPLICA_COUNT="${REPLICA_COUNT:-2}"
APP_NODE_SELECTOR_KEY="${APP_NODE_SELECTOR_KEY:-}"
APP_NODE_SELECTOR_VALUE="${APP_NODE_SELECTOR_VALUE:-}"
MONITOR_NODE_SELECTOR_KEY="${MONITOR_NODE_SELECTOR_KEY:-}"
MONITOR_NODE_SELECTOR_VALUE="${MONITOR_NODE_SELECTOR_VALUE:-}"
REDIS_NODE_SELECTOR_KEY="${REDIS_NODE_SELECTOR_KEY:-}"
REDIS_NODE_SELECTOR_VALUE="${REDIS_NODE_SELECTOR_VALUE:-}"

REQUIRE_METALLB="${REQUIRE_METALLB:-0}"
INSTALL_METALLB="${INSTALL_METALLB:-0}"
METALLB_VERSION="${METALLB_VERSION:-v0.15.3}"
METALLB_MANIFEST_URL="${METALLB_MANIFEST_URL:-https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"
METALLB_POOL_NAME="${METALLB_POOL_NAME:-otp-relay-pool}"

SERVER_HOSTNAME="${SERVER_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}') }"
SERVER_IP="$(printf '%s' "$SERVER_IP" | xargs)"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

PORTAL_URL_EXPLICIT=0
if [ -n "${PORTAL_URL:-}" ]; then
  PORTAL_URL_EXPLICIT=1
fi
PORTAL_URL="${PORTAL_URL:-http://$SERVER_IP}"
if [ "$PORTAL_URL_EXPLICIT" = "0" ] && [ "$TLS_ENABLED" = "1" ] && [ -n "$TLS_HOST" ]; then
  PORTAL_URL="https://$TLS_HOST"
fi
ASSIGNED_LOADBALANCER_ADDRESS=""
PORTAL_URL_CONFIG_REFRESHED=0

PHONE_IP="${PHONE_IP:-172.31.11.122}"
PHONE_INTERFACE="${PHONE_INTERFACE:-$(ip route show default 2>/dev/null | awk '{print $5; exit}') }"
PHONE_INTERFACE="$(printf '%s' "$PHONE_INTERFACE" | xargs)"
PHONE_INTERFACE="${PHONE_INTERFACE:-ens33}"
PHONE_PING_INTERVAL="${PHONE_PING_INTERVAL:-150}"
PHONE_OFFLINE_THRESHOLD="${PHONE_OFFLINE_THRESHOLD:-2}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

RUNTIME_DATA_DIR="${RUNTIME_DATA_DIR:-}"
SKIP_HELP_DOCS_BUILD="${SKIP_HELP_DOCS_BUILD:-0}"
GIT_CLEAN="${GIT_CLEAN:-1}"
SKIP_REPO_SYNC="${SKIP_REPO_SYNC:-auto}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
INSTALL_GITHUB_RUNNER="${INSTALL_GITHUB_RUNNER:-}"
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-${REPO_URL%.git}}"
GITHUB_RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-}"
GITHUB_RUNNER_DIR="${GITHUB_RUNNER_DIR:-/opt/actions-runner}"
GITHUB_RUNNER_USER="${GITHUB_RUNNER_USER:-actions-runner}"
RUNNER_ONLY="${RUNNER_ONLY:-0}"
DEPLOY_MODE="${DEPLOY_MODE:-full}"
DOCKER_BIN="${DOCKER_BIN:-}"

REDIS_ENABLED="${REDIS_ENABLED:-1}"
REDIS_URL="${REDIS_URL:-redis://otp-redis-haproxy:6379/0}"
REDIS_REQUIRED="${REDIS_REQUIRED:-1}"
REDIS_STORAGE_CLASS="${REDIS_STORAGE_CLASS:-local-path}"
REDIS_SIZE="${REDIS_SIZE:-1Gi}"
REDIS_SPREAD_RECREATE_PVCS="${REDIS_SPREAD_RECREATE_PVCS:-auto}"

# Non-registry multi-node image distribution. The installer builds images on
# the runner/control-plane node, then imports the saved image tar into every
# K3s node through a temporary privileged DaemonSet. This avoids external
# registries and avoids SSH/SCP access to worker nodes.
DISTRIBUTE_IMAGES_TO_NODES="${DISTRIBUTE_IMAGES_TO_NODES:-1}"
IMAGE_DISTRIBUTION_PORT="${IMAGE_DISTRIBUTION_PORT:-18080}"
IMAGE_IMPORTER_IMAGE="${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}"

RESTART_APP_REQUIRED=0
RESTART_MONITOR_REQUIRED=0

OS_ID="unknown"
OS_NAME="unknown"
OS_VERSION_ID="unknown"
OS_LIKE=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) RUNNER_ARCH="x64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  armv7l|armv6l|armhf) RUNNER_ARCH="arm" ;;
  *) RUNNER_ARCH="" ;;
esac

IS_RPI=0
if grep -qi 'raspberry pi' /proc/cpuinfo 2>/dev/null || grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
fi



SMS_SECRET_TOKEN="${SMS_SECRET_TOKEN:-$(make_secret)}"




























# Optional runner prompt before validation, matching the existing installer behavior.
if [ -z "$INSTALL_GITHUB_RUNNER" ]; then
  if prompt_yes_no "Install a GitHub Actions self-hosted runner for CI/CD deployments from GitHub? [y/N]" "N"; then
    INSTALL_GITHUB_RUNNER=1
  else
    INSTALL_GITHUB_RUNNER=0
  fi
fi

validate_k8s_topology_settings

log "detected OS/arch: $OS_NAME / $ARCH_RAW"
[ "$IS_RPI" = "1" ] && log "detected Raspberry Pi hardware"
is_debian_family || fatal "this installer currently supports Debian-family systems only"

log "running non-invasive preflight checks"
if ! ss -lnt 2>/dev/null | grep -qE '(^|[[:space:]]|:)22[[:space:]]'; then
  warn "SSH does not appear to be listening on TCP/22. I will not change SSH, but confirm console access before continuing."
fi
if grep -qi '[[:space:]]cifs[[:space:]]' /etc/fstab 2>/dev/null; then
  warn "CIFS entries detected in /etc/fstab. This installer will not mount, unmount, or edit them."
fi
if mount | grep -qi ' type cifs '; then
  warn "An active CIFS mount is present. It will be left untouched."
fi
if systemctl is-active --quiet docker 2>/dev/null; then
  log "Docker is already running; installer will not restart it"
fi
if systemctl is-active --quiet k3s 2>/dev/null; then
  log "K3s is already running; installer will not restart it"
fi

mkdir -p /var/backups/otp-relay-k8s
ip route > /var/backups/otp-relay-k8s/ip-route.before 2>/dev/null || true
ip addr > /var/backups/otp-relay-k8s/ip-addr.before 2>/dev/null || true
iptables-save > /var/backups/otp-relay-k8s/iptables.before 2>/dev/null || true
nft list ruleset > /var/backups/otp-relay-k8s/nft.before 2>/dev/null || true

if [ "$IS_RPI" = "1" ]; then
  if ! grep -qw cgroup_memory /proc/cmdline 2>/dev/null || ! grep -qw cgroup_enable=memory /proc/cmdline 2>/dev/null; then
    warn "Raspberry Pi memory cgroup flags are not active. K3s may fail without them."
    warn "This installer will not edit boot files automatically. Add cgroup_memory=1 cgroup_enable=memory and reboot if K3s fails."
  fi
fi

log "installing base OS packages required for repository sync and optional runner setup with apt-get"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git tar gzip sudo python3 openssl

install_github_runner

if [ "$RUNNER_ONLY" = "1" ]; then
  log "RUNNER_ONLY=1 set; GitHub runner setup complete. Skipping Docker, K3s, image build, and deployment."
  exit 0
fi

case "$DEPLOY_MODE" in
  full|app|monitor|manifests|none) ;;
  *) fatal "unsupported DEPLOY_MODE=$DEPLOY_MODE. Use full, app, monitor, manifests, or none." ;;
esac
log "deployment mode: $DEPLOY_MODE"

if [ "$DEPLOY_MODE" = "none" ]; then
  log "DEPLOY_MODE=none; no deployment changes required. Exiting before Docker/K3s work."
  exit 0
fi

log "installing Kubernetes/deployment OS packages with apt-get"
apt-get install -y --no-install-recommends iproute2 iptables nftables python3-venv jq nodejs npm

if requires_docker; then
  ensure_docker
else
  log "DEPLOY_MODE=$DEPLOY_MODE does not require Docker image build; skipping Docker check/install"
fi

if ! cmd_exists k3s; then
  log "installing K3s server. This installs Kubernetes networking, but does not stop unrelated services."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --write-kubeconfig-mode 644' sh -
else
  log "K3s already installed; no reinstall performed"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
log "waiting for Kubernetes node readiness"
for i in $(seq 1 60); do
  if k3s kubectl get nodes >/dev/null 2>&1 && k3s kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
    break
  fi
  sleep 2
  [ "$i" -lt 60 ] || fatal "K3s node did not become Ready"
done

log "cluster nodes"
k3s kubectl get nodes -o wide
log "cluster storage classes"
k3s kubectl get storageclass 2>/dev/null || true
validate_selected_node "$APP_NODE_SELECTOR_KEY" "$APP_NODE_SELECTOR_VALUE" "app"
validate_selected_node "$MONITOR_NODE_SELECTOR_KEY" "$MONITOR_NODE_SELECTOR_VALUE" "monitor"
validate_selected_node "$REDIS_NODE_SELECTOR_KEY" "$REDIS_NODE_SELECTOR_VALUE" "redis"
install_metallb_if_requested
check_loadbalancer_prereqs

SCRIPT_DIR_REAL="$(cd "$SCRIPT_DIR" && pwd)"
INSTALL_DIR_REAL="$(mkdir -p "$INSTALL_DIR" 2>/dev/null || true; cd "$INSTALL_DIR" 2>/dev/null && pwd || printf '%s' "$INSTALL_DIR")"

if [ "$SKIP_REPO_SYNC" = "auto" ] && [ "$SCRIPT_DIR_REAL" = "$INSTALL_DIR_REAL" ]; then
  SKIP_REPO_SYNC=1
fi

if [ "$SKIP_REPO_SYNC" = "1" ]; then
  log "using existing synced repository at $SCRIPT_DIR_REAL; skipping installer git sync"
  INSTALL_DIR="$SCRIPT_DIR_REAL"
elif [ -d "$INSTALL_DIR/.git" ]; then
  log "syncing repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" || true
  git -C "$INSTALL_DIR" fetch --prune origin "$REPO_REF"
  git -C "$INSTALL_DIR" reset --hard "origin/$REPO_REF"
  if [ "$GIT_CLEAN" = "1" ]; then
    log "cleaning untracked files in repo working tree, preserving common local data/secret files"
    git -C "$INSTALL_DIR" clean -ffd -e data/ -e .env -e k8s/manifests/secret.env -e '*.log'
  fi
elif [ -e "$INSTALL_DIR" ]; then
  fatal "$INSTALL_DIR exists but is not a git repo. Move it away, set INSTALL_DIR to another path, or run from the synced repo with SKIP_REPO_SYNC=1."
else
  log "cloning repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
  git clone --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
log "deployment source repo: $(git rev-parse --short HEAD 2>/dev/null || echo no-git): $(git log -1 --pretty=%s 2>/dev/null || echo local-files)"

log "checking required source files"
[ -f main.py ] || fatal "main.py is missing in repo root"
[ -f monitor.py ] || fatal "monitor.py is required and missing in repo root"
[ -f requirements.txt ] || fatal "requirements.txt is missing in repo root"
[ -d frontend ] || fatal "frontend/ directory is missing"
[ -f frontend/index.html ] || fatal "frontend/index.html is missing"
[ -f frontend/app.jsx ] || fatal "frontend/app.jsx source is missing"
[ -f frontend/style.css ] || fatal "frontend/style.css is missing"
[ -f k8s/Dockerfile ] || fatal "k8s/Dockerfile is missing"
[ -f k8s/Dockerfile.monitor ] || fatal "k8s/Dockerfile.monitor is missing"
[ -d k8s/manifests ] || fatal "k8s/manifests directory is missing"
for required_manifest in namespace.yaml pvc.yaml deployment.yaml service.yaml deployment-monitor.yaml monitor-service.yaml; do
  [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
done
if [ "$REDIS_ENABLED" = "1" ]; then
  for required_manifest in redis-service.yaml redis-configmap.yaml redis-statefulset.yaml redis-sentinel-configmap.yaml redis-sentinel-deployment.yaml redis-sentinel-service.yaml redis-haproxy-configmap.yaml redis-haproxy-deployment.yaml redis-pdb.yaml; do
    [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
  done
fi
[ -f scripts/build_help_docs.py ] || fatal "required help-doc builder is missing: scripts/build_help_docs.py"
[ -d docs/help ] || fatal "required help-doc input directory is missing: docs/help"
[ -f scripts/build_grafana_dashboard_configmap.py ] || fatal "required Grafana dashboard ConfigMap builder is missing: scripts/build_grafana_dashboard_configmap.py"

if [ -z "$PHONE_IP" ]; then
  fatal "PHONE_IP is required because monitor.py is a core component"
fi
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  warn "Telegram alert credentials are not set. monitor.py will still run, but Telegram phone-state alerts will be skipped."
fi

if requires_app_image; then
  log "preparing installer Python environment for app validation/help docs"
  python3 -m venv .installer-venv
  .installer-venv/bin/python -m pip install --upgrade pip setuptools wheel
  .installer-venv/bin/python -m pip install -r requirements.txt

  if [ "$SKIP_HELP_DOCS_BUILD" = "1" ]; then
    log "skipping help docs build because SKIP_HELP_DOCS_BUILD=1"
  else
    log "building help docs with scripts/build_help_docs.py"
    .installer-venv/bin/python scripts/build_help_docs.py
  fi

  [ -f package.json ] || fatal "package.json is missing in repo root"
  [ -f package-lock.json ] || fatal "package-lock.json is missing in repo root"

  log "installing frontend build dependencies from committed package-lock.json"
  npm ci

  log "building production frontend bundle frontend/app.js"
  npm run build:frontend
  [ -f frontend/app.js ] || fatal "frontend/app.js was not produced by npm run build:frontend"
else
  log "DEPLOY_MODE=$DEPLOY_MODE does not require app help-doc build; skipping installer venv"
fi

if [ -f k8s/observability/dashboards/otp-relay-live.json ]; then
  log "generating Grafana dashboard ConfigMap from dashboard JSON"
  python3 scripts/build_grafana_dashboard_configmap.py
fi

log "staging repository Dockerfiles and Kubernetes manifests for deployment"
GENERATED_DIR="$(mktemp -d /tmp/otp-relay-k8s.XXXXXX)"
SOURCE_MANIFEST_DIR="k8s/manifests"
SOURCE_OBSERVABILITY_DIR="k8s/observability"
MANIFEST_DIR="$GENERATED_DIR/manifests"
OBSERVABILITY_DIR="$GENERATED_DIR/observability"
APP_DOCKERFILE="k8s/Dockerfile"
MONITOR_DOCKERFILE="k8s/Dockerfile.monitor"
cleanup_generated_assets() { rm -rf "$GENERATED_DIR"; }
trap cleanup_generated_assets EXIT
mkdir -p "$MANIFEST_DIR"
cp "$SOURCE_MANIFEST_DIR"/*.yaml "$MANIFEST_DIR"/
rm -f "$MANIFEST_DIR/secret-example.env"

if [ -d "$SOURCE_OBSERVABILITY_DIR" ]; then
  mkdir -p "$OBSERVABILITY_DIR"
  find "$SOURCE_OBSERVABILITY_DIR" -maxdepth 1 -type f -name '*.yaml' -exec cp {} "$OBSERVABILITY_DIR"/ \;
fi

existing_pvc_storage_class="$(k3s kubectl get pvc otp-relay-data -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
existing_pvc_storage_class="$(printf '%s' "$existing_pvc_storage_class" | xargs)"
if [ "$NFS_ENABLED" = "1" ]; then
  if [ -z "$PVC_STORAGE_CLASS" ]; then
    PVC_STORAGE_CLASS="$NFS_STORAGE_CLASS"
  fi
elif [ -n "$existing_pvc_storage_class" ] && [ -z "$PVC_STORAGE_CLASS" ]; then
  warn "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; preserving it"
  PVC_STORAGE_CLASS="$existing_pvc_storage_class"
fi
if [ -n "$existing_pvc_storage_class" ] && [ -n "$PVC_STORAGE_CLASS" ] && [ "$PVC_STORAGE_CLASS" != "$existing_pvc_storage_class" ]; then
  fatal "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; refusing to change immutable storageClassName to $PVC_STORAGE_CLASS"
fi

render_manifests

log "validating Python syntax and Kubernetes manifests"
if requires_app_image; then
  python3 -m py_compile main.py
fi
if requires_monitor_image; then
  python3 -m py_compile monitor.py
fi
k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/namespace.yaml" >/dev/null
if [ "$NFS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
  k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/pv-nfs.yaml" >/dev/null
fi
k3s kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
ensure_tls_secret_if_requested
ensure_tls_secret_available_if_required
k3s kubectl apply --dry-run=client \
  -f "$MANIFEST_DIR/configmap.yaml" \
  -f "$MANIFEST_DIR/pvc.yaml" \
  -f "$MANIFEST_DIR/deployment.yaml" \
  -f "$MANIFEST_DIR/service.yaml" \
  -f "$MANIFEST_DIR/deployment-monitor.yaml" \
  -f "$MANIFEST_DIR/monitor-service.yaml" >/dev/null
if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
  k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/ingress.yaml" >/dev/null
fi
if [ "$REDIS_ENABLED" = "1" ]; then
  for redis_manifest in redis-service.yaml redis-configmap.yaml redis-statefulset.yaml redis-sentinel-configmap.yaml redis-sentinel-deployment.yaml redis-sentinel-service.yaml redis-haproxy-configmap.yaml redis-haproxy-deployment.yaml redis-pdb.yaml redis-sentinel-pdb.yaml redis-haproxy-pdb.yaml; do
    if [ -f "$MANIFEST_DIR/$redis_manifest" ]; then
      k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/$redis_manifest" >/dev/null
    fi
  done
fi
dry_run_observability_manifests

if requires_manifests_apply; then
  log "creating/updating Kubernetes secret"
  k3s kubectl create secret generic otp-relay-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=SMS_SECRET_TOKEN="$SMS_SECRET_TOKEN" \
    --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
    --from-literal=TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
fi

if requires_app_image; then
  log "building app image with Docker"
  "$DOCKER_BIN" build -t "$APP_IMAGE" -f "$APP_DOCKERFILE" .
  log "saving app image for K3s import/distribution"
  tmp_app_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-app-image.XXXXXX.tar)"
  "$DOCKER_BIN" save "$APP_IMAGE" -o "$tmp_app_tar"
  log "importing app image into local K3s containerd"
  k3s ctr images import "$tmp_app_tar"
  distribute_image_tar_to_all_nodes "$APP_IMAGE" "$tmp_app_tar" "app"
else
  log "DEPLOY_MODE=$DEPLOY_MODE skips app image build/import"
fi

if requires_monitor_image; then
  log "building required monitor image with Docker"
  "$DOCKER_BIN" build -t "$MONITOR_IMAGE" -f "$MONITOR_DOCKERFILE" .
  log "saving monitor image for K3s import/distribution"
  tmp_monitor_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-monitor-image.XXXXXX.tar)"
  "$DOCKER_BIN" save "$MONITOR_IMAGE" -o "$tmp_monitor_tar"
  log "importing required monitor image into local K3s containerd"
  k3s ctr images import "$tmp_monitor_tar"
  distribute_image_tar_to_all_nodes "$MONITOR_IMAGE" "$tmp_monitor_tar" "monitor"
else
  log "DEPLOY_MODE=$DEPLOY_MODE skips monitor image build/import"
fi

if requires_manifests_apply; then
  log "applying Kubernetes resources"
  apply_runtime_configmap
  if [ "$NFS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
    log "applying static NFS PersistentVolume for app data"
    k3s kubectl apply -f "$MANIFEST_DIR/pv-nfs.yaml"
  fi
  k3s kubectl apply -f "$MANIFEST_DIR/pvc.yaml"

  if [ "$REDIS_ENABLED" = "1" ]; then
    log "applying Redis HA shared-state resources"
    apply_if_exists "$MANIFEST_DIR/redis-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-service.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-statefulset.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-service.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-deployment.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-deployment.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-pdb.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-pdb.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-pdb.yaml"

    log "waiting for Redis StatefulSet rollout"
    k3s kubectl rollout status statefulset/otp-redis -n "$NAMESPACE" --timeout=300s
    log "waiting for Redis Sentinel rollout"
    k3s kubectl rollout status deployment/otp-redis-sentinel -n "$NAMESPACE" --timeout=240s
    log "waiting for Redis HAProxy rollout"
    k3s kubectl rollout status deployment/otp-redis-haproxy -n "$NAMESPACE" --timeout=240s
  fi

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    k3s kubectl apply -f "$MANIFEST_DIR/deployment.yaml"
    k3s kubectl apply -f "$MANIFEST_DIR/service.yaml"
    resolve_portal_url_from_service
    if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
      k3s kubectl apply -f "$MANIFEST_DIR/ingress.yaml"
    else
      k3s kubectl delete ingress otp-relay -n "$NAMESPACE" --ignore-not-found=true
    fi
  fi

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "monitor" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    k3s kubectl apply -f "$MANIFEST_DIR/deployment-monitor.yaml"
    k3s kubectl apply -f "$MANIFEST_DIR/monitor-service.yaml"
  fi

  apply_observability_manifests

  if [ "$PORTAL_URL_CONFIG_REFRESHED" = "1" ]; then
    log "marking deployments for restart to pick up refreshed PORTAL_URL ConfigMap"
    mark_deployment_restart_required otp-relay
    mark_deployment_restart_required otp-monitor
  fi
fi

if requires_app_image; then
  log "marking app deployment for restart to pick up freshly imported local app image"
  mark_deployment_restart_required otp-relay
fi
if requires_monitor_image; then
  log "marking monitor deployment for restart to pick up freshly imported local monitor image"
  mark_deployment_restart_required otp-monitor
fi
perform_pending_rollout_restarts

if [ "$DEPLOY_MODE" = "manifests" ]; then
  log "manifest-only apply complete; checking rollout status for existing deployments"
  k3s kubectl rollout status deployment/otp-relay -n "$NAMESPACE" --timeout=240s || true
  k3s kubectl rollout status deployment/otp-monitor -n "$NAMESPACE" --timeout=180s || true
fi

if [ -n "$RUNTIME_DATA_DIR" ] && { [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ]; }; then
  [ -d "$RUNTIME_DATA_DIR" ] || fatal "RUNTIME_DATA_DIR does not exist: $RUNTIME_DATA_DIR"
  pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay -o jsonpath='{.items[0].metadata.name}')"
  for f in users.xlsx admin_auth.json admin_config.json wizard_progress.json audit.log; do
    if [ -f "$RUNTIME_DATA_DIR/$f" ]; then
      log "copying $f into PVC"
      k3s kubectl cp "$RUNTIME_DATA_DIR/$f" "$NAMESPACE/$pod:/app/data/$f" -n "$NAMESPACE"
    fi
  done
  mark_deployment_restart_required otp-relay
  mark_deployment_restart_required otp-monitor
  perform_pending_rollout_restarts
fi

log "checking deployment working tree cleanliness"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty_status="$(git status --porcelain)"
  if [ -n "$dirty_status" ]; then
    warn "deployment working tree has uncommitted/generated files:"
    printf '%s\n' "$dirty_status" >&2
    warn "tracked modifications should now be unexpected; generated frontend files should be covered by .gitignore"
  else
    log "deployment working tree is clean"
  fi
fi

NODEPORT_SUMMARY="disabled"
if [ "$SERVICE_TYPE" = "NodePort" ]; then
  NODEPORT_SUMMARY="http://$SERVER_IP:$SERVICE_NODE_PORT/"
fi

cat <<EOF_DONE

OTP Relay Kubernetes deployment complete.

Portal URL:   $PORTAL_URL/
NodePort URL: $NODEPORT_SUMMARY
Service type: $SERVICE_TYPE
LoadBalancer: ${ASSIGNED_LOADBALANCER_ADDRESS:-${LOADBALANCER_IP:-auto/none}}
Ingress:      enabled=$INGRESS_ENABLED tls=$TLS_ENABLED host=${TLS_HOST:-none} secret=${TLS_SECRET_NAME:-none} self_signed=$TLS_SELF_SIGNED
MetalLB:      install=$INSTALL_METALLB range=${METALLB_IP_RANGE:-none}
Namespace:    $NAMESPACE
Repo path:    $INSTALL_DIR
OS/arch:      $OS_NAME / $ARCH_RAW
Monitor:      installed as required component
Runner:       $INSTALL_GITHUB_RUNNER
Runner only:  $RUNNER_ONLY
Deploy mode:  $DEPLOY_MODE
App replicas:          $REPLICA_COUNT
App rollout strategy:  RollingUpdate maxUnavailable=0 maxSurge=1
App node selector:     ${APP_NODE_SELECTOR_KEY:-none}=${APP_NODE_SELECTOR_VALUE:-}
Monitor node selector: ${MONITOR_NODE_SELECTOR_KEY:-none}=${MONITOR_NODE_SELECTOR_VALUE:-}
Redis node selector:   ${REDIS_NODE_SELECTOR_KEY:-none}=${REDIS_NODE_SELECTOR_VALUE:-}
PVC storage:           ${PVC_STORAGE_CLASS:-default} / $PVC_SIZE
NFS app storage:       enabled=$NFS_ENABLED server=${NFS_SERVER:-none} path=${NFS_PATH:-none} class=$NFS_STORAGE_CLASS pv=$NFS_PV_NAME
Redis:                 enabled=$REDIS_ENABLED required=$REDIS_REQUIRED url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/$REDIS_SIZE spread_recreate_pvcs=$REDIS_SPREAD_RECREATE_PVCS
Image distribution:    enabled=$DISTRIBUTE_IMAGES_TO_NODES importer=$IMAGE_IMPORTER_IMAGE port=$IMAGE_DISTRIBUTION_PORT
Observability YAMLs:   applied from k8s/observability when present

Useful commands:
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl get pods -n $NAMESPACE
  k3s kubectl logs -n $NAMESPACE deployment/otp-relay
  k3s kubectl logs -n $NAMESPACE deployment/otp-monitor
  k3s kubectl get svc,ingress -n $NAMESPACE
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis -o wide
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis-sentinel -o wide
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis-haproxy -o wide
  k3s kubectl -n kube-system get svc traefik -o wide
  curl -k --resolve ${TLS_HOST:-srvotptest26.init-db.lan}:443:<TRAEFIK_LB_IP> https://${TLS_HOST:-srvotptest26.init-db.lan}/readyz
  curl -i http://127.0.0.1/
  # If SERVICE_TYPE=NodePort:
  # curl -i http://127.0.0.1:$SERVICE_NODE_PORT/

Monitor config is in ConfigMap otp-relay-config:
  PHONE_IP=$PHONE_IP
  PHONE_INTERFACE=$PHONE_INTERFACE
  PHONE_PING_INTERVAL=$PHONE_PING_INTERVAL
  PHONE_OFFLINE_THRESHOLD=$PHONE_OFFLINE_THRESHOLD
  PORTAL_URL=$PORTAL_URL

SMS webhook secret token was generated/stored in Kubernetes secret otp-relay-secrets.
To print it on this server:
  k3s kubectl get secret otp-relay-secrets -n $NAMESPACE -o jsonpath='{.data.SMS_SECRET_TOKEN}' | base64 -d; echo
EOF_DONE
