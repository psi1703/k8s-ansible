#!/usr/bin/env bash

# Environment source-of-truth helpers for install-otp-relay-k8s.sh.

# This file is sourced by the installer; do not execute it directly.

# Current architecture:

# This server/real host is the K3s control-plane and Ansible runner.

# The VM provisioner creates only worker1 and worker2.

# NFS is external and is not joined to Kubernetes.

# frontend/app.jsx is source; frontend/app.js is generated during deployment.

ENV_FILE_LOADED=0
ENV_FILE_CREATED=0

_env_quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

_env_get_current() {
local name="$1"
local current=""
current="$(printenv "$name" 2>/dev/null || true)"
printf '%s' "$current"
}

_env_prompt() {
local name="$1"
local label="$2"
local required="${3:-0}"
local secret="${4:-0}"
local current=""
local input=""

current="$(_env_get_current "$name")"

while true; do
if [ "$secret" = "1" ]; then
if [ -n "$current" ]; then
read -r -s -p "$label [currently set, press Enter to keep]: " input
else
read -r -s -p "$label: " input
fi
printf '\n'
else
if [ -n "$current" ]; then
read -r -p "$label [$current]: " input
else
read -r -p "$label: " input
fi
fi

if [ -n "$input" ]; then
  printf -v "$name" '%s' "$input"
  export "$name"
  return 0
fi

if [ -n "$current" ]; then
  printf -v "$name" '%s' "$current"
  export "$name"
  return 0
fi

if [ "$required" != "1" ]; then
  printf -v "$name" ''
  export "$name"
  return 0
fi

warn "$name is required"

done
}

_env_set_default() {
local name="$1"
local value="${2:-}"

if [ -z "${!name:-}" ]; then
printf -v "$name" '%s' "$value"
export "$name"
fi
}

_env_default_interface() {
ip route show default 2>/dev/null | awk '{print $5; exit}'
}

_env_reset_config_vars() {
local names="REPO_URL REPO_REF INSTALL_DIR NAMESPACE APP_IMAGE MONITOR_IMAGE DEPLOY_MODE SERVICE_TYPE SERVICE_NODE_PORT LOADBALANCER_IP INGRESS_ENABLED TLS_ENABLED TLS_HOST TLS_SECRET_NAME TLS_SELF_SIGNED PORTAL_URL PVC_STORAGE_CLASS PVC_SIZE NFS_ENABLED NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_PV_NAME NFS_MOUNT_OPTIONS REPLICA_COUNT APP_NODE_SELECTOR_KEY APP_NODE_SELECTOR_VALUE MONITOR_NODE_SELECTOR_KEY MONITOR_NODE_SELECTOR_VALUE REDIS_NODE_SELECTOR_KEY REDIS_NODE_SELECTOR_VALUE REQUIRE_METALLB INSTALL_METALLB METALLB_VERSION METALLB_MANIFEST_URL METALLB_IP_RANGE METALLB_POOL_NAME SERVER_HOSTNAME SERVER_IP PHONE_IP PHONE_INTERFACE PHONE_PING_INTERVAL PHONE_OFFLINE_THRESHOLD PHONE_ARP_COUNT PHONE_ARP_TIMEOUT MONITOR_METRICS_PORT OTP_RELAY_DATA_DIR USERS_EXCEL_PATH AUDIT_LOG_PATH CLAIM_EXPIRY_SEC OTP_DISPLAY_SEC CONCURRENT_RISK_SEC TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID RUNTIME_DATA_DIR SKIP_HELP_DOCS_BUILD INSTALL_GITHUB_RUNNER GITHUB_RUNNER_URL GITHUB_RUNNER_TOKEN GITHUB_RUNNER_DIR GITHUB_RUNNER_USER RUNNER_ONLY DOCKER_BIN REDIS_ENABLED REDIS_URL REDIS_REQUIRED REDIS_STORAGE_CLASS REDIS_SIZE REDIS_SPREAD_RECREATE_PVCS REDIS_NFS_PV_PREFIX REDIS_NFS_SERVER REDIS_NFS_BASE_PATH REDIS_NFS_MOUNT_OPTIONS DISTRIBUTE_IMAGES_TO_NODES IMAGE_DISTRIBUTION_PORT IMAGE_IMPORTER_IMAGE SMS_SECRET_TOKEN BRIDGE_NAME HOST_IFACE HOST_IP_CIDR GATEWAY DNS PREFIX IP_SCAN_PREFIX IP_SCAN_START IP_SCAN_END AUTO_ASSIGN_IPS WORKER1_IP WORKER2_IP VM_USER VM_PASSWORD VM_RAM_MB VM_VCPUS VM_DISK_GB WORKER1_NAME WORKER2_NAME OBSERVABILITY_NAMESPACE OBSERVABILITY_INSTALL_STACK OBSERVABILITY_STACK_CHART_VERSION GRAFANA_HOST"
local name=""
for name in $names; do
  unset "$name"
done
}

_env_file_syntax_ok() {
local source_file="$1"

if bash -n "$source_file" >/dev/null 2>&1; then
  return 0
fi

return 1
}

_env_reject_file() {
local source_file="$1"
local reason="$2"
local stamp=""
local rejected=""

stamp="$(date +%Y%m%d-%H%M%S)"
rejected="${source_file}.rejected.${stamp}"

warn "rejecting saved environment file: $source_file"
warn "reason: $reason"

mv "$source_file" "$rejected"
chmod 0600 "$rejected" 2>/dev/null || true
warn "saved rejected environment file as: $rejected"

ENV_FILE_LOADED=0
}

_env_clear_recoverable_placeholders() {
if _env_is_default_placeholder "${TLS_HOST:-}"; then
  unset TLS_HOST
fi

if [ "${VM_PASSWORD:-}" = "CHANGE_ME_VM_PASSWORD" ]; then
  unset VM_PASSWORD
fi
}

_env_is_default_placeholder() {
case "${1:-}" in
  ""|"CHANGE_ME_TLS_HOST"|"otp-relay.local"|"CHANGE_ME_VM_PASSWORD") return 0 ;;
  *) return 1 ;;
esac
}

_env_existing_file_is_recoverable_first_run() {
# Return 0 only for values that indicate an incomplete/cancelled first-run file.
# Normal older .env files with missing optional values are normalized instead of rejected.

if [ -z "${PHONE_IP:-}" ]; then
  warn "saved .env is missing PHONE_IP"
  return 0
fi

if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
  if _env_is_default_placeholder "${TLS_HOST:-}"; then
    warn "saved .env has no usable ingress/TLS hostname"
    return 0
  fi
fi

if [ "${NFS_ENABLED:-0}" = "1" ]; then
  if [ -z "${NFS_SERVER:-}" ] || [ -z "${NFS_PATH:-}" ]; then
    warn "saved .env is missing NFS_SERVER or NFS_PATH while NFS_ENABLED=1"
    return 0
  fi
fi

if [ "${INSTALL_METALLB:-0}" = "1" ] && [ -z "${METALLB_IP_RANGE:-}" ]; then
  warn "saved .env is missing METALLB_IP_RANGE while INSTALL_METALLB=1"
  return 0
fi

if [ -z "${SMS_SECRET_TOKEN:-}" ]; then
  warn "saved .env is missing SMS_SECRET_TOKEN"
  return 0
fi

if [ "${VM_PASSWORD:-}" = "CHANGE_ME_VM_PASSWORD" ]; then
  warn "saved .env contains the default VM_PASSWORD placeholder"
  return 0
fi

return 1
}

_write_env_file() {
local target="$1"
local tmp="${target}.tmp"

log "writing installer environment file: $target"

umask 077
cat > "$tmp" <<EOF_ENV

# OTP Relay Kubernetes runtime configuration.

# This file is the single input source for the installer, rendered Kubernetes

# manifests, Ansible deployment handoff, monitor/app runtime settings, and

# worker VM provisioning settings.

#

# Current architecture:

# - This server/real host is the K3s control-plane and Ansible runner.

# - The VM provisioner creates only worker1 and worker2.

# - NFS is external and is not joined to Kubernetes.

#

# Keep secrets in this file only. Do not commit populated .env files.

# Internal repository / install location.

REPO_URL=$(_env_quote "${REPO_URL:-}")
REPO_REF=$(_env_quote "${REPO_REF:-main}")
INSTALL_DIR=$(_env_quote "${INSTALL_DIR:-${SCRIPT_DIR}}")
NAMESPACE=$(_env_quote "${NAMESPACE:-otp-relay}")

# Images / deployment behavior

APP_IMAGE=$(_env_quote "${APP_IMAGE:-otp-relay:latest}")
MONITOR_IMAGE=$(_env_quote "${MONITOR_IMAGE:-otp-monitor:latest}")
DEPLOY_MODE=$(_env_quote "${DEPLOY_MODE:-full}")

# Service / Ingress

SERVICE_TYPE=$(_env_quote "${SERVICE_TYPE:-ClusterIP}")
SERVICE_NODE_PORT=$(_env_quote "${SERVICE_NODE_PORT:-30080}")
LOADBALANCER_IP=$(_env_quote "${LOADBALANCER_IP:-}")
INGRESS_ENABLED=$(_env_quote "${INGRESS_ENABLED:-1}")
TLS_ENABLED=$(_env_quote "${TLS_ENABLED:-0}")
TLS_HOST=$(_env_quote "${TLS_HOST:-CHANGE_ME_TLS_HOST}")
TLS_SECRET_NAME=$(_env_quote "${TLS_SECRET_NAME:-otp-relay-tls}")
TLS_SELF_SIGNED=$(_env_quote "${TLS_SELF_SIGNED:-1}")
PORTAL_URL=$(_env_quote "${PORTAL_URL:-}")

# Storage

PVC_STORAGE_CLASS=$(_env_quote "${PVC_STORAGE_CLASS:-otp-relay-devprod-nfs}")
PVC_SIZE=$(_env_quote "${PVC_SIZE:-1Gi}")
NFS_ENABLED=$(_env_quote "${NFS_ENABLED:-1}")
NFS_SERVER=$(_env_quote "${NFS_SERVER:-}")
NFS_PATH=$(_env_quote "${NFS_PATH:-}")
NFS_STORAGE_CLASS=$(_env_quote "${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs}")
NFS_PV_NAME=$(_env_quote "${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}")
NFS_MOUNT_OPTIONS=$(_env_quote "${NFS_MOUNT_OPTIONS:-nfsvers=4.1}")

# Replicas / placement

REPLICA_COUNT=$(_env_quote "${REPLICA_COUNT:-2}")
APP_NODE_SELECTOR_KEY=$(_env_quote "${APP_NODE_SELECTOR_KEY:-otp-relay/app-node}")
APP_NODE_SELECTOR_VALUE=$(_env_quote "${APP_NODE_SELECTOR_VALUE:-true}")
MONITOR_NODE_SELECTOR_KEY=$(_env_quote "${MONITOR_NODE_SELECTOR_KEY:-otp-relay/monitor-node}")
MONITOR_NODE_SELECTOR_VALUE=$(_env_quote "${MONITOR_NODE_SELECTOR_VALUE:-true}")
REDIS_NODE_SELECTOR_KEY=$(_env_quote "${REDIS_NODE_SELECTOR_KEY:-otp-relay/redis-node}")
REDIS_NODE_SELECTOR_VALUE=$(_env_quote "${REDIS_NODE_SELECTOR_VALUE:-true}")

# MetalLB

REQUIRE_METALLB=$(_env_quote "${REQUIRE_METALLB:-0}")
INSTALL_METALLB=$(_env_quote "${INSTALL_METALLB:-0}")
METALLB_VERSION=$(_env_quote "${METALLB_VERSION:-v0.15.3}")
METALLB_IP_RANGE=$(_env_quote "${METALLB_IP_RANGE:-}")
METALLB_POOL_NAME=$(_env_quote "${METALLB_POOL_NAME:-otp-relay-pool}")

# Runtime app / monitor inputs

PHONE_IP=$(_env_quote "${PHONE_IP:-}")
PHONE_INTERFACE=$(_env_quote "${PHONE_INTERFACE:-}")
PHONE_PING_INTERVAL=$(_env_quote "${PHONE_PING_INTERVAL:-10}")
PHONE_OFFLINE_THRESHOLD=$(_env_quote "${PHONE_OFFLINE_THRESHOLD:-30}")
PHONE_ARP_COUNT=$(_env_quote "${PHONE_ARP_COUNT:-2}")
PHONE_ARP_TIMEOUT=$(_env_quote "${PHONE_ARP_TIMEOUT:-2}")
MONITOR_METRICS_PORT=$(_env_quote "${MONITOR_METRICS_PORT:-9101}")
OTP_RELAY_DATA_DIR=$(_env_quote "${OTP_RELAY_DATA_DIR:-/app/data}")
USERS_EXCEL_PATH=$(_env_quote "${USERS_EXCEL_PATH:-/app/data/users.xlsx}")
AUDIT_LOG_PATH=$(_env_quote "${AUDIT_LOG_PATH:-/app/data/audit.log}")
CLAIM_EXPIRY_SEC=$(_env_quote "${CLAIM_EXPIRY_SEC:-90}")
OTP_DISPLAY_SEC=$(_env_quote "${OTP_DISPLAY_SEC:-285}")
CONCURRENT_RISK_SEC=$(_env_quote "${CONCURRENT_RISK_SEC:-30}")

# Secrets

SMS_SECRET_TOKEN=$(_env_quote "${SMS_SECRET_TOKEN:-$(make_secret)}")
TELEGRAM_BOT_TOKEN=$(_env_quote "${TELEGRAM_BOT_TOKEN:-}")
TELEGRAM_CHAT_ID=$(_env_quote "${TELEGRAM_CHAT_ID:-}")

# Redis

REDIS_ENABLED=$(_env_quote "${REDIS_ENABLED:-1}")
REDIS_URL=$(_env_quote "${REDIS_URL:-redis://otp-redis-haproxy:6379/0}")
REDIS_REQUIRED=$(_env_quote "${REDIS_REQUIRED:-1}")
REDIS_STORAGE_CLASS=$(_env_quote "${REDIS_STORAGE_CLASS:-otp-redis-devprod-nfs}")
REDIS_SIZE=$(_env_quote "${REDIS_SIZE:-1Gi}")
REDIS_SPREAD_RECREATE_PVCS=$(_env_quote "${REDIS_SPREAD_RECREATE_PVCS:-auto}")
REDIS_NFS_PV_PREFIX=$(_env_quote "${REDIS_NFS_PV_PREFIX:-otp-redis-devprod}")
REDIS_NFS_SERVER=$(_env_quote "${REDIS_NFS_SERVER:-${NFS_SERVER:-}}")
REDIS_NFS_BASE_PATH=$(_env_quote "${REDIS_NFS_BASE_PATH:-${NFS_PATH:-}/redis}")
REDIS_NFS_MOUNT_OPTIONS=$(_env_quote "${REDIS_NFS_MOUNT_OPTIONS:-${NFS_MOUNT_OPTIONS:-nfsvers=4.1}}")

# Installer behavior

RUNTIME_DATA_DIR=$(_env_quote "${RUNTIME_DATA_DIR:-}")
SKIP_HELP_DOCS_BUILD=$(_env_quote "${SKIP_HELP_DOCS_BUILD:-0}")
GIT_CLEAN=$(_env_quote "${GIT_CLEAN:-1}")
SKIP_REPO_SYNC=$(_env_quote "${SKIP_REPO_SYNC:-auto}")
NONINTERACTIVE=$(_env_quote "${NONINTERACTIVE:-0}")
INSTALL_GITHUB_RUNNER=$(_env_quote "${INSTALL_GITHUB_RUNNER:-}")
GITHUB_RUNNER_URL=$(_env_quote "${GITHUB_RUNNER_URL:-}")
GITHUB_RUNNER_TOKEN=$(_env_quote "${GITHUB_RUNNER_TOKEN:-}")
GITHUB_RUNNER_DIR=$(_env_quote "${GITHUB_RUNNER_DIR:-/opt/actions-runner}")
GITHUB_RUNNER_USER=$(_env_quote "${GITHUB_RUNNER_USER:-actions-runner}")
RUNNER_ONLY=$(_env_quote "${RUNNER_ONLY:-0}")
DOCKER_BIN=$(_env_quote "${DOCKER_BIN:-}")
DISTRIBUTE_IMAGES_TO_NODES=$(_env_quote "${DISTRIBUTE_IMAGES_TO_NODES:-1}")
IMAGE_DISTRIBUTION_PORT=$(_env_quote "${IMAGE_DISTRIBUTION_PORT:-18080}")
IMAGE_IMPORTER_IMAGE=$(_env_quote "${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}")

# Worker VM provisioner inputs.

# No CP_IP exists in this design. This server is the control-plane.

BRIDGE_NAME=$(_env_quote "${BRIDGE_NAME:-br0}")
HOST_IFACE=$(_env_quote "${HOST_IFACE:-}")
HOST_IP_CIDR=$(_env_quote "${HOST_IP_CIDR:-}")
GATEWAY=$(_env_quote "${GATEWAY:-}")
DNS=$(_env_quote "${DNS:-}")
PREFIX=$(_env_quote "${PREFIX:-24}")
IP_SCAN_PREFIX=$(_env_quote "${IP_SCAN_PREFIX:-}")
IP_SCAN_START=$(_env_quote "${IP_SCAN_START:-160}")
IP_SCAN_END=$(_env_quote "${IP_SCAN_END:-169}")
AUTO_ASSIGN_IPS=$(_env_quote "${AUTO_ASSIGN_IPS:-0}")
WORKER1_IP=$(_env_quote "${WORKER1_IP:-}")
WORKER2_IP=$(_env_quote "${WORKER2_IP:-}")
VM_USER=$(_env_quote "${VM_USER:-otp-relay}")
VM_PASSWORD=$(_env_quote "${VM_PASSWORD:-}")
VM_RAM_MB=$(_env_quote "${VM_RAM_MB:-3072}")
VM_VCPUS=$(_env_quote "${VM_VCPUS:-2}")
VM_DISK_GB=$(_env_quote "${VM_DISK_GB:-20}")
WORKER1_NAME=$(_env_quote "${WORKER1_NAME:-otp-devprod-worker1}")
WORKER2_NAME=$(_env_quote "${WORKER2_NAME:-otp-devprod-worker2}")

# Observability

# kube-prometheus-stack is installed by the installer when OBSERVABILITY_INSTALL_STACK=1.

OBSERVABILITY_NAMESPACE=$(_env_quote "${OBSERVABILITY_NAMESPACE:-observability-devprod}")
OBSERVABILITY_INSTALL_STACK=$(_env_quote "${OBSERVABILITY_INSTALL_STACK:-1}")
OBSERVABILITY_STACK_CHART_VERSION=$(_env_quote "${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}")
GRAFANA_HOST=$(_env_quote "${GRAFANA_HOST:-grafana-devprod.init-db.lan}")
EOF_ENV

mv "$tmp" "$target"
chmod 0600 "$target"
log "environment file written with mode 0600: $target"
}

source_env_file() {
local source_file="$1"

if [ ! -f "$source_file" ]; then
return 1
fi

if ! _env_file_syntax_ok "$source_file"; then
return 2
fi

log "sourcing environment file: $source_file"
set -a

# shellcheck disable=SC1090

if ! . "$source_file"; then
  set +a
  return 2
fi

set +a
}

create_env_interactive() {
log "creating first-run environment file at $ENV_FILE"
log "interactive setup will ask only for operator-owned values"

_env_set_default REPO_URL ""
_env_set_default REPO_REF "k8s-ansible-DEVtoPROD"
_env_set_default INSTALL_DIR "/opt/k8s-ansible-DEVtoPROD"
_env_set_default DEPLOY_MODE "full"
_env_set_default RUNNER_ONLY "0"

_env_set_default NAMESPACE "otp-relay-devprod"
_env_set_default SERVICE_TYPE "ClusterIP"
_env_set_default INGRESS_ENABLED "1"
_env_set_default TLS_ENABLED "0"
_env_set_default TLS_HOST "CHANGE_ME_TLS_HOST"

_env_set_default NFS_ENABLED "1"
_env_set_default PVC_STORAGE_CLASS "otp-relay-devprod-nfs"
_env_set_default NFS_STORAGE_CLASS "otp-relay-devprod-nfs"

_env_set_default INSTALL_METALLB "0"
_env_set_default REDIS_ENABLED "1"
_env_set_default REDIS_REQUIRED "1"
_env_set_default REDIS_URL "redis://otp-redis-haproxy:6379/0"
_env_set_default REDIS_STORAGE_CLASS "otp-redis-devprod-nfs"
_env_set_default REDIS_NFS_PV_PREFIX "otp-redis-devprod"
_env_set_default REDIS_NFS_SERVER "${NFS_SERVER:-}"
_env_set_default REDIS_NFS_BASE_PATH "${NFS_PATH:-}/redis"
_env_set_default REDIS_NFS_MOUNT_OPTIONS "${NFS_MOUNT_OPTIONS:-nfsvers=4.1}"
_env_set_default REPLICA_COUNT "2"

_env_set_default APP_NODE_SELECTOR_KEY "otp-relay/app-node"
_env_set_default APP_NODE_SELECTOR_VALUE "true"
_env_set_default MONITOR_NODE_SELECTOR_KEY "otp-relay/monitor-node"
_env_set_default MONITOR_NODE_SELECTOR_VALUE "true"
_env_set_default REDIS_NODE_SELECTOR_KEY "otp-relay/redis-node"
_env_set_default REDIS_NODE_SELECTOR_VALUE "true"

_env_set_default PHONE_PING_INTERVAL "10"
_env_set_default PHONE_OFFLINE_THRESHOLD "30"
_env_set_default OBSERVABILITY_NAMESPACE "observability"
_env_set_default OBSERVABILITY_INSTALL_STACK "1"
_env_set_default OBSERVABILITY_STACK_CHART_VERSION "85.0.1"
_env_set_default GRAFANA_HOST "grafana-devprod.init-db.lan"

_env_prompt NAMESPACE "Kubernetes namespace" 1 0
_env_prompt SERVICE_TYPE "Service type: ClusterIP, NodePort, or LoadBalancer" 1 0
_env_prompt INGRESS_ENABLED "Enable ingress? 1=yes, 0=no" 1 0
_env_prompt TLS_ENABLED "Enable TLS? 1=yes, 0=no" 1 0

if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
_env_prompt TLS_HOST "Ingress/TLS hostname" 1 0
fi

_env_prompt NFS_ENABLED "Use external NFS-backed app PVC? 1=yes, 0=no" 1 0
if [ "${NFS_ENABLED:-0}" = "1" ]; then
_env_prompt NFS_SERVER "External NFS server IP/DNS" 1 0
_env_prompt NFS_PATH "External NFS export path" 1 0
PVC_STORAGE_CLASS="${PVC_STORAGE_CLASS:-${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs}}"
export PVC_STORAGE_CLASS
fi

_env_prompt INSTALL_METALLB "Install/configure MetalLB? 1=yes, 0=no" 1 0
if [ "${INSTALL_METALLB:-0}" = "1" ]; then
_env_prompt METALLB_IP_RANGE "MetalLB IP range" 1 0
fi

_env_prompt PHONE_IP "Monitored phone IP" 1 0

if [ -z "${PHONE_INTERFACE:-}" ]; then
PHONE_INTERFACE="$(_env_default_interface)"
export PHONE_INTERFACE
fi

_env_prompt PHONE_INTERFACE "Host network interface for ARP checks" 1 0
_env_prompt PHONE_PING_INTERVAL "Phone ping interval seconds" 1 0
_env_prompt PHONE_OFFLINE_THRESHOLD "Phone offline threshold seconds" 1 0

_env_prompt REDIS_ENABLED "Enable Redis? 1=yes, 0=no" 1 0
if [ "${REDIS_ENABLED:-0}" = "1" ]; then
_env_prompt REDIS_URL "Redis URL" 1 0
_env_prompt REDIS_REQUIRED "Require Redis for readiness? 1=yes, 0=no" 1 0
fi

_env_prompt REPLICA_COUNT "App replica count" 1 0
_env_prompt TELEGRAM_BOT_TOKEN "Telegram bot token (optional)" 0 1
_env_prompt TELEGRAM_CHAT_ID "Telegram chat ID (optional)" 0 0

if [ -z "${SMS_SECRET_TOKEN:-}" ]; then
SMS_SECRET_TOKEN="$(make_secret)"
export SMS_SECRET_TOKEN
fi

_env_prompt SMS_SECRET_TOKEN "SMS webhook secret token" 1 1

normalize_loaded_env
_write_env_file "$ENV_FILE"
ENV_FILE_CREATED=1
}

create_env_noninteractive() {
log "creating non-interactive environment file at $ENV_FILE from exported variables"
log "NONINTERACTIVE=1 is set and no .env file exists; missing required values will fail validation after defaults are written"
normalize_loaded_env
_write_env_file "$ENV_FILE"
ENV_FILE_CREATED=1
}

change_env_menu() {
while true; do
cat <<EOF_MENU

Environment file: $ENV_FILE

1. Network/exposure: SERVICE_TYPE, INGRESS_ENABLED, TLS_ENABLED, TLS_HOST, PORTAL_URL
2. Storage: PVC_STORAGE_CLASS, NFS_ENABLED, NFS_SERVER, NFS_PATH
3. Monitor phone: PHONE_IP, PHONE_INTERFACE, PHONE_PING_INTERVAL, PHONE_OFFLINE_THRESHOLD
4. Alerts/secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SMS_SECRET_TOKEN
5. Redis: REDIS_ENABLED, REDIS_URL, REDIS_REQUIRED, REDIS_STORAGE_CLASS
6. Placement/replicas: REPLICA_COUNT, node selectors
7. Installer behavior: DEPLOY_MODE, RUNNER_ONLY, SKIP_REPO_SYNC
8. Worker VM provisioning: bridge, worker IPs, VM sizing
9. Observability: Grafana/Prometheus install and Grafana host
10. Save and continue
EOF_MENU

    read -r -p "Choose what to change [10]: " choice
    choice="${choice:-10}"

    case "$choice" in
    1)
    _env_prompt SERVICE_TYPE "Service type" 1 0
    _env_prompt INGRESS_ENABLED "Enable ingress? 1/0" 1 0
    _env_prompt TLS_ENABLED "Enable TLS? 1/0" 1 0
    _env_prompt TLS_HOST "Ingress/TLS hostname" 0 0
    _env_prompt PORTAL_URL "Portal URL override" 0 0
    ;;
    2)
    _env_prompt PVC_STORAGE_CLASS "PVC storage class" 0 0
    _env_prompt NFS_ENABLED "Use external NFS? 1/0" 1 0
    _env_prompt NFS_SERVER "External NFS server IP/DNS" 0 0
    _env_prompt NFS_PATH "External NFS export path" 0 0
    ;;
    3)
    _env_prompt PHONE_IP "Monitored phone IP" 1 0
    _env_prompt PHONE_INTERFACE "Host network interface" 1 0
    _env_prompt PHONE_PING_INTERVAL "Phone ping interval seconds" 1 0
    _env_prompt PHONE_OFFLINE_THRESHOLD "Offline threshold seconds" 1 0
    ;;
    4)
    _env_prompt TELEGRAM_BOT_TOKEN "Telegram bot token" 0 1
    _env_prompt TELEGRAM_CHAT_ID "Telegram chat ID" 0 0
    _env_prompt SMS_SECRET_TOKEN "SMS webhook secret token" 1 1
    ;;
    5)
    _env_prompt REDIS_ENABLED "Enable Redis? 1/0" 1 0
    _env_prompt REDIS_URL "Redis URL" 1 0
    _env_prompt REDIS_REQUIRED "Require Redis for readiness? 1/0" 1 0
    _env_prompt REDIS_STORAGE_CLASS "Redis storage class" 0 0
    ;;
    6)
    _env_prompt REPLICA_COUNT "App replica count" 1 0
    _env_prompt APP_NODE_SELECTOR_KEY "App node selector key" 0 0
    _env_prompt APP_NODE_SELECTOR_VALUE "App node selector value" 0 0
    _env_prompt MONITOR_NODE_SELECTOR_KEY "Monitor node selector key" 0 0
    _env_prompt MONITOR_NODE_SELECTOR_VALUE "Monitor node selector value" 0 0
    _env_prompt REDIS_NODE_SELECTOR_KEY "Redis node selector key" 0 0
    _env_prompt REDIS_NODE_SELECTOR_VALUE "Redis node selector value" 0 0
    ;;
    7)
    _env_prompt DEPLOY_MODE "Deploy mode: full, app, monitor, manifests, observability, or none" 1 0
    _env_prompt RUNNER_ONLY "Runner-only mode? 1/0" 1 0
    _env_prompt SKIP_REPO_SYNC "Skip repo sync? auto, 1, or 0" 1 0
    ;;
    8)
    _env_prompt BRIDGE_NAME "Libvirt bridge name" 1 0
    _env_prompt HOST_IFACE "Host interface to bridge for worker VMs" 1 0
    _env_prompt HOST_IP_CIDR "Host bridge IP/CIDR" 1 0
    _env_prompt GATEWAY "Network gateway" 1 0
    _env_prompt DNS "DNS server for worker VMs" 1 0
    _env_prompt PREFIX "Network prefix length" 1 0
    _env_prompt IP_SCAN_PREFIX "IP scan prefix, for example 172.31.11" 1 0
    _env_prompt IP_SCAN_START "IP scan start octet" 1 0
    _env_prompt IP_SCAN_END "IP scan end octet" 1 0
    _env_prompt AUTO_ASSIGN_IPS "Auto assign worker VM IPs? 1/0" 1 0
    if [ "${AUTO_ASSIGN_IPS:-1}" != "1" ]; then
    _env_prompt WORKER1_IP "Worker 1 VM IP" 1 0
    _env_prompt WORKER2_IP "Worker 2 VM IP" 1 0
    fi
    _env_prompt VM_USER "Worker VM login user" 1 0
    _env_prompt VM_PASSWORD "Worker VM login password" 1 1
    _env_prompt VM_RAM_MB "Worker VM RAM MB" 1 0
    _env_prompt VM_VCPUS "Worker VM vCPUs" 1 0
    _env_prompt VM_DISK_GB "Worker VM disk GB" 1 0
    ;;
    9)
    _env_prompt OBSERVABILITY_NAMESPACE "Observability namespace" 1 0
    _env_prompt OBSERVABILITY_INSTALL_STACK "Install Grafana/Prometheus with kube-prometheus-stack? 1/0" 1 0
    _env_prompt OBSERVABILITY_STACK_CHART_VERSION "kube-prometheus-stack chart version" 1 0
    _env_prompt GRAFANA_HOST "Grafana hostname" 1 0
    ;;
    10)
    normalize_loaded_env
    _write_env_file "$ENV_FILE"
    return 0
    ;;
    *) warn "invalid menu choice: $choice" ;;
    esac
    done
    }

validate_env_required() {
log "validating required installer environment values"

[ -n "${NAMESPACE:-}" ] || fatal "NAMESPACE is required in $ENV_FILE"
[ -n "${INSTALL_DIR:-}" ] || fatal "INSTALL_DIR is required in $ENV_FILE"

if [ "${DEPLOY_MODE:-full}" = "observability" ]; then
log "DEPLOY_MODE=observability; using observability-only environment validation"

[ -n "${OBSERVABILITY_NAMESPACE:-}" ] || fatal "OBSERVABILITY_NAMESPACE is required in $ENV_FILE when DEPLOY_MODE=observability"
[ -n "${OBSERVABILITY_INSTALL_STACK:-}" ] || fatal "OBSERVABILITY_INSTALL_STACK is required in $ENV_FILE when DEPLOY_MODE=observability"
[ -n "${OBSERVABILITY_STACK_CHART_VERSION:-}" ] || fatal "OBSERVABILITY_STACK_CHART_VERSION is required in $ENV_FILE when DEPLOY_MODE=observability"
[ -n "${GRAFANA_HOST:-}" ] || fatal "GRAFANA_HOST is required in $ENV_FILE when DEPLOY_MODE=observability"

log "observability-only environment values validated"
return 0
fi

[ -n "${SERVICE_TYPE:-}" ] || fatal "SERVICE_TYPE is required in $ENV_FILE"
[ -n "${PHONE_IP:-}" ] || fatal "PHONE_IP is required in $ENV_FILE because the monitor is a core component"
[ -n "${PHONE_INTERFACE:-}" ] || fatal "PHONE_INTERFACE is required in $ENV_FILE because ARP monitoring requires a host interface"

if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
[ -n "${TLS_HOST:-}" ] || fatal "TLS_HOST is required in $ENV_FILE when ingress or TLS is enabled"

if [ "${TLS_HOST:-}" = "CHANGE_ME_TLS_HOST" ] || [ "${TLS_HOST:-}" = "otp-relay.local" ]; then
  fatal "TLS_HOST must be changed from the default when ingress or TLS is enabled"
fi

fi

if [ "${NFS_ENABLED:-0}" = "1" ]; then
[ -n "${NFS_SERVER:-}" ] || fatal "NFS_SERVER is required in $ENV_FILE when NFS_ENABLED=1"
[ -n "${NFS_PATH:-}" ] || fatal "NFS_PATH is required in $ENV_FILE when NFS_ENABLED=1"
fi

if [ "${INSTALL_METALLB:-0}" = "1" ]; then
[ -n "${METALLB_IP_RANGE:-}" ] || fatal "METALLB_IP_RANGE is required in $ENV_FILE when INSTALL_METALLB=1"
fi

[ -n "${SMS_SECRET_TOKEN:-}" ] || fatal "SMS_SECRET_TOKEN is required in $ENV_FILE"

if [ -n "${VM_PASSWORD:-}" ]; then
if [ "${VM_PASSWORD:-}" = "otp-relay" ] || [ "${VM_PASSWORD:-}" = "CHANGE_ME_VM_PASSWORD" ]; then
fatal "VM_PASSWORD must be changed from the default before provisioning worker VMs"
fi
fi

if [ "${REDIS_ENABLED:-0}" = "1" ]; then
[ -n "${REDIS_URL:-}" ] || fatal "REDIS_URL is required in $ENV_FILE when REDIS_ENABLED=1"
fi

[ -n "${OTP_RELAY_DATA_DIR:-}" ] || fatal "OTP_RELAY_DATA_DIR is required in $ENV_FILE"
[ -n "${USERS_EXCEL_PATH:-}" ] || fatal "USERS_EXCEL_PATH is required in $ENV_FILE"
[ -n "${AUDIT_LOG_PATH:-}" ] || fatal "AUDIT_LOG_PATH is required in $ENV_FILE"
[ -n "${CLAIM_EXPIRY_SEC:-}" ] || fatal "CLAIM_EXPIRY_SEC is required in $ENV_FILE"
[ -n "${OTP_DISPLAY_SEC:-}" ] || fatal "OTP_DISPLAY_SEC is required in $ENV_FILE"
[ -n "${CONCURRENT_RISK_SEC:-}" ] || fatal "CONCURRENT_RISK_SEC is required in $ENV_FILE"

log "required installer environment values validated"
}

_env_reapply_runtime_overrides() {
local runtime_noninteractive="$1"
local runtime_skip_repo_sync="$2"
local runtime_git_clean="$3"

if [ -n "$runtime_noninteractive" ]; then
  NONINTERACTIVE="$runtime_noninteractive"
  export NONINTERACTIVE
fi

if [ -n "$runtime_skip_repo_sync" ]; then
  SKIP_REPO_SYNC="$runtime_skip_repo_sync"
  export SKIP_REPO_SYNC
fi

if [ -n "$runtime_git_clean" ]; then
  GIT_CLEAN="$runtime_git_clean"
  export GIT_CLEAN
fi
}

_env_restore_recovery_input() {
local name="$1"
local value="${2:-}"

if [ -n "$value" ]; then
  printf -v "$name" '%s' "$value"
  export "$name"
fi
}

_env_create_new_file_for_current_mode() {
if [ "${NONINTERACTIVE:-0}" = "1" ]; then
  create_env_noninteractive
else
  create_env_interactive
fi
}

load_or_create_env() {
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
export ENV_FILE

# Runtime overrides passed by Ansible/caller must win over persisted .env values.

# Example: .env may contain NONINTERACTIVE=0, but Ansible deployment must run with NONINTERACTIVE=1.

local runtime_noninteractive="${NONINTERACTIVE:-}"
local runtime_skip_repo_sync="${SKIP_REPO_SYNC:-}"
local runtime_git_clean="${GIT_CLEAN:-}"
local runtime_deploy_mode="${DEPLOY_MODE:-}"
local recovery_service_type="${SERVICE_TYPE:-}"
local recovery_ingress_enabled="${INGRESS_ENABLED:-}"
local recovery_tls_enabled="${TLS_ENABLED:-}"
local recovery_tls_host="${TLS_HOST:-}"
local recovery_nfs_enabled="${NFS_ENABLED:-}"
local recovery_nfs_server="${NFS_SERVER:-}"
local recovery_nfs_path="${NFS_PATH:-}"
local recovery_install_metallb="${INSTALL_METALLB:-}"
local recovery_metallb_ip_range="${METALLB_IP_RANGE:-}"
local recovery_phone_ip="${PHONE_IP:-}"
local recovery_phone_interface="${PHONE_INTERFACE:-}"
local recovery_sms_secret_token="${SMS_SECRET_TOKEN:-}"
local recovery_redis_enabled="${REDIS_ENABLED:-}"
local recovery_redis_url="${REDIS_URL:-}"
local recovery_redis_required="${REDIS_REQUIRED:-}"
local loaded_existing_env=0

if [ -f "$ENV_FILE" ]; then
  log "loading environment from $ENV_FILE"

  if source_env_file "$ENV_FILE"; then
    ENV_FILE_LOADED=1
    loaded_existing_env=1
  else
    _env_reject_file "$ENV_FILE" "file is not valid shell syntax or could not be sourced"
    _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
    _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
    _env_restore_recovery_input SERVICE_TYPE "$recovery_service_type"
    _env_restore_recovery_input INGRESS_ENABLED "$recovery_ingress_enabled"
    _env_restore_recovery_input TLS_ENABLED "$recovery_tls_enabled"
    _env_restore_recovery_input TLS_HOST "$recovery_tls_host"
    _env_restore_recovery_input NFS_ENABLED "$recovery_nfs_enabled"
    _env_restore_recovery_input NFS_SERVER "$recovery_nfs_server"
    _env_restore_recovery_input NFS_PATH "$recovery_nfs_path"
    _env_restore_recovery_input INSTALL_METALLB "$recovery_install_metallb"
    _env_restore_recovery_input METALLB_IP_RANGE "$recovery_metallb_ip_range"
    _env_restore_recovery_input PHONE_IP "$recovery_phone_ip"
    _env_restore_recovery_input PHONE_INTERFACE "$recovery_phone_interface"
    _env_restore_recovery_input SMS_SECRET_TOKEN "$recovery_sms_secret_token"
    _env_restore_recovery_input REDIS_ENABLED "$recovery_redis_enabled"
    _env_restore_recovery_input REDIS_URL "$recovery_redis_url"
    _env_restore_recovery_input REDIS_REQUIRED "$recovery_redis_required"
    _env_create_new_file_for_current_mode
  fi
fi

if [ ! -f "$ENV_FILE" ]; then
  _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
  _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
  _env_create_new_file_for_current_mode
fi

if [ "$loaded_existing_env" = "1" ]; then
  _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
  _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
  normalize_loaded_env

  if _env_existing_file_is_recoverable_first_run; then
    _env_reject_file "$ENV_FILE" "file appears incomplete or still contains first-run placeholders"
    _env_clear_recoverable_placeholders
    _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
    _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
    _env_restore_recovery_input SERVICE_TYPE "$recovery_service_type"
    _env_restore_recovery_input INGRESS_ENABLED "$recovery_ingress_enabled"
    _env_restore_recovery_input TLS_ENABLED "$recovery_tls_enabled"
    _env_restore_recovery_input TLS_HOST "$recovery_tls_host"
    _env_restore_recovery_input NFS_ENABLED "$recovery_nfs_enabled"
    _env_restore_recovery_input NFS_SERVER "$recovery_nfs_server"
    _env_restore_recovery_input NFS_PATH "$recovery_nfs_path"
    _env_restore_recovery_input INSTALL_METALLB "$recovery_install_metallb"
    _env_restore_recovery_input METALLB_IP_RANGE "$recovery_metallb_ip_range"
    _env_restore_recovery_input PHONE_IP "$recovery_phone_ip"
    _env_restore_recovery_input PHONE_INTERFACE "$recovery_phone_interface"
    _env_restore_recovery_input SMS_SECRET_TOKEN "$recovery_sms_secret_token"
    _env_restore_recovery_input REDIS_ENABLED "$recovery_redis_enabled"
    _env_restore_recovery_input REDIS_URL "$recovery_redis_url"
    _env_restore_recovery_input REDIS_REQUIRED "$recovery_redis_required"
    _env_create_new_file_for_current_mode
  elif [ "${NONINTERACTIVE:-0}" != "1" ]; then
    if prompt_yes_no "Change saved installer environment values before continuing? [y/N]" "N"; then
      change_env_menu
      source_env_file "$ENV_FILE"
      _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
      _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
      normalize_loaded_env
    fi
  else
    log "NONINTERACTIVE=1; using existing .env without prompting"
  fi
fi

source_env_file "$ENV_FILE"
ENV_FILE_LOADED=1
_env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean"
_env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
normalize_loaded_env

validate_env_required
log "environment source: $ENV_FILE"
}

normalize_loaded_env() {
log "normalizing installer environment values"

REPO_URL="${REPO_URL:-}"
REPO_REF="${REPO_REF:-k8s-ansible-DEVtoPROD}"
INSTALL_DIR="${INSTALL_DIR:-/opt/k8s-ansible-DEVtoPROD}"
NAMESPACE="${NAMESPACE:-otp-relay-devprod}"
APP_IMAGE="${APP_IMAGE:-otp-relay:latest}"
MONITOR_IMAGE="${MONITOR_IMAGE:-otp-monitor:latest}"

SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"
SERVICE_NODE_PORT="${SERVICE_NODE_PORT:-30080}"
LOADBALANCER_IP="${LOADBALANCER_IP:-}"
INGRESS_ENABLED="${INGRESS_ENABLED:-1}"
TLS_ENABLED="${TLS_ENABLED:-0}"
TLS_HOST="${TLS_HOST:-CHANGE_ME_TLS_HOST}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-otp-relay-tls}"
TLS_SELF_SIGNED="${TLS_SELF_SIGNED:-1}"

PVC_STORAGE_CLASS="${PVC_STORAGE_CLASS:-otp-relay-devprod-nfs}"
PVC_SIZE="${PVC_SIZE:-1Gi}"
NFS_ENABLED="${NFS_ENABLED:-1}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-}"
NFS_STORAGE_CLASS="${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs}"
NFS_PV_NAME="${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}"
NFS_MOUNT_OPTIONS="${NFS_MOUNT_OPTIONS:-nfsvers=4.1}"

REPLICA_COUNT="${REPLICA_COUNT:-2}"
APP_NODE_SELECTOR_KEY="${APP_NODE_SELECTOR_KEY:-otp-relay/app-node}"
APP_NODE_SELECTOR_VALUE="${APP_NODE_SELECTOR_VALUE:-true}"
MONITOR_NODE_SELECTOR_KEY="${MONITOR_NODE_SELECTOR_KEY:-otp-relay/monitor-node}"
MONITOR_NODE_SELECTOR_VALUE="${MONITOR_NODE_SELECTOR_VALUE:-true}"
REDIS_NODE_SELECTOR_KEY="${REDIS_NODE_SELECTOR_KEY:-otp-relay/redis-node}"
REDIS_NODE_SELECTOR_VALUE="${REDIS_NODE_SELECTOR_VALUE:-true}"

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

PHONE_IP="${PHONE_IP:-}"
PHONE_INTERFACE="${PHONE_INTERFACE:-$(_env_default_interface)}"
PHONE_INTERFACE="$(printf '%s' "$PHONE_INTERFACE" | xargs)"
PHONE_INTERFACE="${PHONE_INTERFACE:-}"
PHONE_PING_INTERVAL="${PHONE_PING_INTERVAL:-10}"
PHONE_OFFLINE_THRESHOLD="${PHONE_OFFLINE_THRESHOLD:-30}"
PHONE_ARP_COUNT="${PHONE_ARP_COUNT:-2}"
PHONE_ARP_TIMEOUT="${PHONE_ARP_TIMEOUT:-2}"
MONITOR_METRICS_PORT="${MONITOR_METRICS_PORT:-9101}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

OTP_RELAY_DATA_DIR="${OTP_RELAY_DATA_DIR:-/app/data}"
USERS_EXCEL_PATH="${USERS_EXCEL_PATH:-/app/data/users.xlsx}"
AUDIT_LOG_PATH="${AUDIT_LOG_PATH:-/app/data/audit.log}"
CLAIM_EXPIRY_SEC="${CLAIM_EXPIRY_SEC:-90}"
OTP_DISPLAY_SEC="${OTP_DISPLAY_SEC:-285}"
CONCURRENT_RISK_SEC="${CONCURRENT_RISK_SEC:-30}"

RUNTIME_DATA_DIR="${RUNTIME_DATA_DIR:-}"
SKIP_HELP_DOCS_BUILD="${SKIP_HELP_DOCS_BUILD:-0}"
GIT_CLEAN="${GIT_CLEAN:-1}"
SKIP_REPO_SYNC="${SKIP_REPO_SYNC:-auto}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
INSTALL_GITHUB_RUNNER="${INSTALL_GITHUB_RUNNER:-}"
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-}"
GITHUB_RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-}"
GITHUB_RUNNER_DIR="${GITHUB_RUNNER_DIR:-/opt/actions-runner}"
GITHUB_RUNNER_USER="${GITHUB_RUNNER_USER:-actions-runner}"
RUNNER_ONLY="${RUNNER_ONLY:-0}"
DEPLOY_MODE="${DEPLOY_MODE:-full}"
DOCKER_BIN="${DOCKER_BIN:-}"

REDIS_ENABLED="${REDIS_ENABLED:-1}"
REDIS_URL="${REDIS_URL:-redis://otp-redis-haproxy:6379/0}"
REDIS_REQUIRED="${REDIS_REQUIRED:-1}"
REDIS_STORAGE_CLASS="${REDIS_STORAGE_CLASS:-otp-redis-devprod-nfs}"
REDIS_SIZE="${REDIS_SIZE:-1Gi}"
REDIS_SPREAD_RECREATE_PVCS="${REDIS_SPREAD_RECREATE_PVCS:-auto}"
REDIS_NFS_PV_PREFIX="${REDIS_NFS_PV_PREFIX:-otp-redis-devprod}"
REDIS_NFS_SERVER="${REDIS_NFS_SERVER:-${NFS_SERVER:-}}"
REDIS_NFS_BASE_PATH="${REDIS_NFS_BASE_PATH:-${NFS_PATH:-}/redis}"
REDIS_NFS_MOUNT_OPTIONS="${REDIS_NFS_MOUNT_OPTIONS:-${NFS_MOUNT_OPTIONS:-nfsvers=4.1}}"

DISTRIBUTE_IMAGES_TO_NODES="${DISTRIBUTE_IMAGES_TO_NODES:-1}"
IMAGE_DISTRIBUTION_PORT="${IMAGE_DISTRIBUTION_PORT:-18080}"
IMAGE_IMPORTER_IMAGE="${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}"
SMS_SECRET_TOKEN="${SMS_SECRET_TOKEN:-$(make_secret)}"

BRIDGE_NAME="${BRIDGE_NAME:-br0}"
HOST_IFACE="${HOST_IFACE:-}"
HOST_IP_CIDR="${HOST_IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS="${DNS:-}"
PREFIX="${PREFIX:-24}"
IP_SCAN_PREFIX="${IP_SCAN_PREFIX:-}"
IP_SCAN_START="${IP_SCAN_START:-160}"
IP_SCAN_END="${IP_SCAN_END:-169}"
AUTO_ASSIGN_IPS="${AUTO_ASSIGN_IPS:-0}"
WORKER1_IP="${WORKER1_IP:-}"
WORKER2_IP="${WORKER2_IP:-}"
VM_USER="${VM_USER:-otp-relay}"
VM_PASSWORD="${VM_PASSWORD:-}"
VM_RAM_MB="${VM_RAM_MB:-3072}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GB="${VM_DISK_GB:-20}"
WORKER1_NAME="${WORKER1_NAME:-otp-devprod-worker1}"
WORKER2_NAME="${WORKER2_NAME:-otp-devprod-worker2}"

OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
OBSERVABILITY_INSTALL_STACK="${OBSERVABILITY_INSTALL_STACK:-1}"
OBSERVABILITY_STACK_CHART_VERSION="${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana-devprod.init-db.lan}"

RESTART_APP_REQUIRED=0
RESTART_MONITOR_REQUIRED=0

export REPO_URL REPO_REF INSTALL_DIR NAMESPACE APP_IMAGE MONITOR_IMAGE SERVICE_TYPE SERVICE_NODE_PORT LOADBALANCER_IP INGRESS_ENABLED TLS_ENABLED TLS_HOST TLS_SECRET_NAME TLS_SELF_SIGNED
export PVC_STORAGE_CLASS PVC_SIZE NFS_ENABLED NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_PV_NAME NFS_MOUNT_OPTIONS REPLICA_COUNT APP_NODE_SELECTOR_KEY APP_NODE_SELECTOR_VALUE
export MONITOR_NODE_SELECTOR_KEY MONITOR_NODE_SELECTOR_VALUE REDIS_NODE_SELECTOR_KEY REDIS_NODE_SELECTOR_VALUE REQUIRE_METALLB INSTALL_METALLB METALLB_VERSION METALLB_MANIFEST_URL METALLB_IP_RANGE METALLB_POOL_NAME
export SERVER_HOSTNAME SERVER_IP PORTAL_URL PORTAL_URL_EXPLICIT ASSIGNED_LOADBALANCER_ADDRESS PORTAL_URL_CONFIG_REFRESHED PHONE_IP PHONE_INTERFACE PHONE_PING_INTERVAL PHONE_OFFLINE_THRESHOLD PHONE_ARP_COUNT PHONE_ARP_TIMEOUT MONITOR_METRICS_PORT
export OTP_RELAY_DATA_DIR USERS_EXCEL_PATH AUDIT_LOG_PATH CLAIM_EXPIRY_SEC OTP_DISPLAY_SEC CONCURRENT_RISK_SEC
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID RUNTIME_DATA_DIR SKIP_HELP_DOCS_BUILD GIT_CLEAN SKIP_REPO_SYNC NONINTERACTIVE INSTALL_GITHUB_RUNNER GITHUB_RUNNER_URL GITHUB_RUNNER_TOKEN
export GITHUB_RUNNER_DIR GITHUB_RUNNER_USER RUNNER_ONLY DEPLOY_MODE DOCKER_BIN REDIS_ENABLED REDIS_URL REDIS_REQUIRED REDIS_STORAGE_CLASS REDIS_SIZE REDIS_SPREAD_RECREATE_PVCS REDIS_NFS_PV_PREFIX REDIS_NFS_SERVER REDIS_NFS_BASE_PATH REDIS_NFS_MOUNT_OPTIONS
export DISTRIBUTE_IMAGES_TO_NODES IMAGE_DISTRIBUTION_PORT IMAGE_IMPORTER_IMAGE SMS_SECRET_TOKEN RESTART_APP_REQUIRED RESTART_MONITOR_REQUIRED
export BRIDGE_NAME HOST_IFACE HOST_IP_CIDR GATEWAY DNS PREFIX IP_SCAN_PREFIX IP_SCAN_START IP_SCAN_END AUTO_ASSIGN_IPS WORKER1_IP WORKER2_IP VM_USER VM_PASSWORD VM_RAM_MB VM_VCPUS VM_DISK_GB WORKER1_NAME WORKER2_NAME
export OBSERVABILITY_NAMESPACE OBSERVABILITY_INSTALL_STACK OBSERVABILITY_STACK_CHART_VERSION GRAFANA_HOST

log "installer environment normalization completed"
}
