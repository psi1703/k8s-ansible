#!/usr/bin/env bash
# Environment source-of-truth helpers for the OTP Relay bundle-only release builder.
# This file is sourced by build-release-bundle.sh; do not execute it directly.
#
# Bundle-only architecture:
#   - This script runs on the dev/build host.
#   - It produces a sealed release tarball under dist/.
#   - It does not deploy to any Kubernetes cluster.
#   - It does not install K3s, Helm, MetalLB, GitHub runners, or runtime tooling.
#   - It does not provision worker VMs.
#   - It does not import images into a live cluster.
#   - It does not apply manifests.
#   - It does not restart deployments.
#   - It does not validate a live cluster.
#
# The production server receives only the finished bundle.

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

_env_file_syntax_ok() {
  local source_file="$1"

  bash -n "$source_file" >/dev/null 2>&1
}

_env_is_default_placeholder() {
  case "${1:-}" in
    ""|"CHANGE_ME_TLS_HOST"|"CHANGE_ME_NFS_SERVER"|"CHANGE_ME_NFS_PATH"|"CHANGE_ME_METALLB_IP_RANGE"|"otp-relay.local"|"CHANGE_ME_VM_PASSWORD") return 0 ;;
    *) return 1 ;;
  esac
}

_env_mode_requires_runtime_manifests() {
  case "${DEPLOY_MODE:-full}" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

_env_mode_requires_app() {
  case "${DEPLOY_MODE:-full}" in
    full|app) return 0 ;;
    *) return 1 ;;
  esac
}

_env_mode_requires_monitor() {
  case "${DEPLOY_MODE:-full}" in
    full|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

_env_force_bundle_only_flags() {
  RELEASE_MODE="bundle"

  SKIP_CLUSTER_DEPLOY="1"
  SKIP_K3S_INSTALL="1"
  SKIP_HELM_INSTALL="1"
  SKIP_KUBECTL_APPLY="1"
  SKIP_IMAGE_IMPORT="1"
  SKIP_ROLLOUT_RESTART="1"
  SKIP_LIVE_CLUSTER_VALIDATE="1"
  SKIP_GITHUB_RUNNER_INSTALL="1"
  SKIP_VM_PROVISIONING="1"

  DEPLOY_OTP_RELAY="0"
  VALIDATE_OTP_RELAY="0"
  INSTALL_GITHUB_RUNNER="0"
  RUNNER_ONLY="0"
  DISTRIBUTE_IMAGES_TO_NODES="0"

  export RELEASE_MODE
  export SKIP_CLUSTER_DEPLOY
  export SKIP_K3S_INSTALL
  export SKIP_HELM_INSTALL
  export SKIP_KUBECTL_APPLY
  export SKIP_IMAGE_IMPORT
  export SKIP_ROLLOUT_RESTART
  export SKIP_LIVE_CLUSTER_VALIDATE
  export SKIP_GITHUB_RUNNER_INSTALL
  export SKIP_VM_PROVISIONING
  export DEPLOY_OTP_RELAY
  export VALIDATE_OTP_RELAY
  export INSTALL_GITHUB_RUNNER
  export RUNNER_ONLY
  export DISTRIBUTE_IMAGES_TO_NODES
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

  if _env_is_default_placeholder "${NFS_SERVER:-}"; then
    unset NFS_SERVER
  fi

  if _env_is_default_placeholder "${NFS_PATH:-}"; then
    unset NFS_PATH
  fi

  if _env_is_default_placeholder "${METALLB_IP_RANGE:-}"; then
    unset METALLB_IP_RANGE
  fi
}

_env_existing_file_is_recoverable_first_run() {
  # Bundle builder .env files are allowed to contain production-side
  # placeholders. The production import/merge procedure is responsible for
  # comparing .env.bundle against the existing production .env and prompting
  # before critical changes.
  #
  # Only an unsupported artifact selector is treated as recoverable bad state.

  case "${DEPLOY_MODE:-full}" in
    full|app|monitor|none)
      return 1
      ;;
    *)
      warn "saved .env has unsupported DEPLOY_MODE=${DEPLOY_MODE:-}"
      return 0
      ;;
  esac
}

_write_env_file() {
  local target="$1"
  local tmp="${target}.tmp"

  log "writing bundle-builder environment file: $target"

  _env_force_bundle_only_flags

  umask 077
  cat > "$tmp" <<EOF_ENV
# OTP Relay Kubernetes release bundle configuration.
#
# This file is the single input source for rendered Kubernetes manifests,
# image archive export, release metadata, and production handoff packaging.
#
# Bundle-only architecture:
# - This file is consumed on the dev/build host.
# - The builder creates a sealed release tarball under dist/.
# - The builder does not deploy anything.
# - The builder does not install K3s, Helm, MetalLB, GitHub runners, or runtime tooling.
# - The builder does not provision worker VMs.
# - The builder does not import images into a live cluster.
# - The builder does not apply manifests.
# - The builder does not restart deployments.
# - The builder does not validate a live cluster.
#
# The production server receives only the finished bundle.
#
# Keep secrets in this file only. Do not commit populated .env files.

REPO_URL=$(_env_quote "${REPO_URL:-}")
REPO_REF=$(_env_quote "${REPO_REF:-k8s-ansible-DEVtoPROD}")
INSTALL_DIR=$(_env_quote "${INSTALL_DIR:-${SCRIPT_DIR}}")

NAMESPACE=$(_env_quote "${NAMESPACE:-otp-relay-devprod}")
APP_IMAGE=$(_env_quote "${APP_IMAGE:-otp-relay:latest}")
MONITOR_IMAGE=$(_env_quote "${MONITOR_IMAGE:-otp-monitor:latest}")
DEPLOY_MODE=$(_env_quote "${DEPLOY_MODE:-full}")
RELEASE_MODE=$(_env_quote "bundle")

SKIP_CLUSTER_DEPLOY=$(_env_quote "1")
SKIP_K3S_INSTALL=$(_env_quote "1")
SKIP_HELM_INSTALL=$(_env_quote "1")
SKIP_KUBECTL_APPLY=$(_env_quote "1")
SKIP_IMAGE_IMPORT=$(_env_quote "1")
SKIP_ROLLOUT_RESTART=$(_env_quote "1")
SKIP_LIVE_CLUSTER_VALIDATE=$(_env_quote "1")
SKIP_GITHUB_RUNNER_INSTALL=$(_env_quote "1")
SKIP_VM_PROVISIONING=$(_env_quote "1")
DEPLOY_OTP_RELAY=$(_env_quote "0")
VALIDATE_OTP_RELAY=$(_env_quote "0")

SERVICE_TYPE=$(_env_quote "${SERVICE_TYPE:-ClusterIP}")
SERVICE_NODE_PORT=$(_env_quote "${SERVICE_NODE_PORT:-30080}")
LOADBALANCER_IP=$(_env_quote "${LOADBALANCER_IP:-}")
INGRESS_ENABLED=$(_env_quote "${INGRESS_ENABLED:-1}")
TLS_ENABLED=$(_env_quote "${TLS_ENABLED:-0}")
TLS_HOST=$(_env_quote "${TLS_HOST:-CHANGE_ME_TLS_HOST}")
TLS_SECRET_NAME=$(_env_quote "${TLS_SECRET_NAME:-otp-relay-tls}")
TLS_SELF_SIGNED=$(_env_quote "${TLS_SELF_SIGNED:-1}")
PORTAL_URL=$(_env_quote "${PORTAL_URL:-}")

PVC_STORAGE_CLASS=$(_env_quote "${PVC_STORAGE_CLASS:-otp-relay-devprod-nfs}")
PVC_SIZE=$(_env_quote "${PVC_SIZE:-1Gi}")
NFS_ENABLED=$(_env_quote "${NFS_ENABLED:-1}")
NFS_SERVER=$(_env_quote "${NFS_SERVER:-CHANGE_ME_NFS_SERVER}")
NFS_PATH=$(_env_quote "${NFS_PATH:-CHANGE_ME_NFS_PATH}")
NFS_STORAGE_CLASS=$(_env_quote "${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs}")
NFS_PV_NAME=$(_env_quote "${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}")
NFS_MOUNT_OPTIONS=$(_env_quote "${NFS_MOUNT_OPTIONS:-nfsvers=4.1}")

REPLICA_COUNT=$(_env_quote "${REPLICA_COUNT:-2}")
APP_NODE_SELECTOR_KEY=$(_env_quote "${APP_NODE_SELECTOR_KEY:-otp-relay/app-node}")
APP_NODE_SELECTOR_VALUE=$(_env_quote "${APP_NODE_SELECTOR_VALUE:-true}")
MONITOR_NODE_SELECTOR_KEY=$(_env_quote "${MONITOR_NODE_SELECTOR_KEY:-otp-relay/monitor-node}")
MONITOR_NODE_SELECTOR_VALUE=$(_env_quote "${MONITOR_NODE_SELECTOR_VALUE:-true}")
REDIS_NODE_SELECTOR_KEY=$(_env_quote "${REDIS_NODE_SELECTOR_KEY:-otp-relay/redis-node}")
REDIS_NODE_SELECTOR_VALUE=$(_env_quote "${REDIS_NODE_SELECTOR_VALUE:-true}")

REQUIRE_METALLB=$(_env_quote "${REQUIRE_METALLB:-0}")
INSTALL_METALLB=$(_env_quote "${INSTALL_METALLB:-0}")
METALLB_VERSION=$(_env_quote "${METALLB_VERSION:-v0.15.3}")
METALLB_IP_RANGE=$(_env_quote "${METALLB_IP_RANGE:-CHANGE_ME_METALLB_IP_RANGE}")
METALLB_POOL_NAME=$(_env_quote "${METALLB_POOL_NAME:-otp-relay-pool}")

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

SMS_SECRET_TOKEN=$(_env_quote "${SMS_SECRET_TOKEN:-}")
TELEGRAM_BOT_TOKEN=$(_env_quote "${TELEGRAM_BOT_TOKEN:-}")
TELEGRAM_CHAT_ID=$(_env_quote "${TELEGRAM_CHAT_ID:-}")

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

RUNTIME_DATA_DIR=$(_env_quote "${RUNTIME_DATA_DIR:-}")
SKIP_HELP_DOCS_BUILD=$(_env_quote "${SKIP_HELP_DOCS_BUILD:-0}")
GIT_CLEAN=$(_env_quote "${GIT_CLEAN:-1}")
SKIP_REPO_SYNC=$(_env_quote "${SKIP_REPO_SYNC:-auto}")
NONINTERACTIVE=$(_env_quote "${NONINTERACTIVE:-0}")
DOCKER_BIN=$(_env_quote "${DOCKER_BIN:-}")
DIST_DIR=$(_env_quote "${DIST_DIR:-dist}")

INSTALL_GITHUB_RUNNER=$(_env_quote "0")
GITHUB_RUNNER_URL=$(_env_quote "")
GITHUB_RUNNER_TOKEN=$(_env_quote "")
GITHUB_RUNNER_DIR=$(_env_quote "")
GITHUB_RUNNER_USER=$(_env_quote "")
RUNNER_ONLY=$(_env_quote "0")

DISTRIBUTE_IMAGES_TO_NODES=$(_env_quote "0")
IMAGE_DISTRIBUTION_PORT=$(_env_quote "${IMAGE_DISTRIBUTION_PORT:-18080}")
IMAGE_IMPORTER_IMAGE=$(_env_quote "${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}")

BRIDGE_NAME=$(_env_quote "")
HOST_IFACE=$(_env_quote "")
HOST_IP_CIDR=$(_env_quote "")
GATEWAY=$(_env_quote "")
DNS=$(_env_quote "")
PREFIX=$(_env_quote "")
IP_SCAN_PREFIX=$(_env_quote "")
IP_SCAN_START=$(_env_quote "")
IP_SCAN_END=$(_env_quote "")
AUTO_ASSIGN_IPS=$(_env_quote "0")
WORKER1_IP=$(_env_quote "")
WORKER2_IP=$(_env_quote "")
VM_USER=$(_env_quote "")
VM_PASSWORD=$(_env_quote "")
VM_RAM_MB=$(_env_quote "")
VM_VCPUS=$(_env_quote "")
VM_DISK_GB=$(_env_quote "")
WORKER1_NAME=$(_env_quote "")
WORKER2_NAME=$(_env_quote "")

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
  log "creating first-run bundle-builder environment file at $ENV_FILE"
  log "interactive setup asks only for the release artifact selector"
  log "production-specific runtime values may remain as placeholders and are finalized by the production import/merge procedure"

  _env_set_default REPO_URL ""
  _env_set_default REPO_REF "k8s-ansible-DEVtoPROD"
  _env_set_default INSTALL_DIR "${SCRIPT_DIR}"
  _env_set_default DEPLOY_MODE "full"

  _env_set_default NAMESPACE "otp-relay-devprod"
  _env_set_default SERVICE_TYPE "ClusterIP"
  _env_set_default INGRESS_ENABLED "1"
  _env_set_default TLS_ENABLED "0"
  _env_set_default TLS_HOST "CHANGE_ME_TLS_HOST"

  _env_set_default NFS_ENABLED "1"
  _env_set_default NFS_SERVER "CHANGE_ME_NFS_SERVER"
  _env_set_default NFS_PATH "CHANGE_ME_NFS_PATH"
  _env_set_default PVC_STORAGE_CLASS "otp-relay-devprod-nfs"
  _env_set_default NFS_STORAGE_CLASS "otp-relay-devprod-nfs"

  _env_set_default INSTALL_METALLB "0"
  _env_set_default METALLB_IP_RANGE "CHANGE_ME_METALLB_IP_RANGE"
  _env_set_default REDIS_ENABLED "1"
  _env_set_default REDIS_REQUIRED "1"
  _env_set_default REDIS_URL "redis://otp-redis-haproxy:6379/0"
  _env_set_default REDIS_STORAGE_CLASS "otp-redis-devprod-nfs"
  _env_set_default REDIS_NFS_PV_PREFIX "otp-redis-devprod"
  _env_set_default REPLICA_COUNT "2"

  _env_set_default APP_NODE_SELECTOR_KEY "otp-relay/app-node"
  _env_set_default APP_NODE_SELECTOR_VALUE "true"
  _env_set_default MONITOR_NODE_SELECTOR_KEY "otp-relay/monitor-node"
  _env_set_default MONITOR_NODE_SELECTOR_VALUE "true"
  _env_set_default REDIS_NODE_SELECTOR_KEY "otp-relay/redis-node"
  _env_set_default REDIS_NODE_SELECTOR_VALUE "true"

  _env_set_default PHONE_IP ""
  if [ -z "${PHONE_INTERFACE:-}" ]; then
    PHONE_INTERFACE="$(_env_default_interface)"
    export PHONE_INTERFACE
  fi
  _env_set_default PHONE_PING_INTERVAL "10"
  _env_set_default PHONE_OFFLINE_THRESHOLD "30"

  _env_set_default OBSERVABILITY_NAMESPACE "observability-devprod"
  _env_set_default OBSERVABILITY_INSTALL_STACK "1"
  _env_set_default OBSERVABILITY_STACK_CHART_VERSION "85.0.1"
  _env_set_default GRAFANA_HOST "grafana-devprod.init-db.lan"

  _env_prompt DEPLOY_MODE "Artifact selector: full, app, monitor, or none" 1 0

  normalize_loaded_env
  _write_env_file "$ENV_FILE"
  ENV_FILE_CREATED=1
}

create_env_noninteractive() {
  log "creating non-interactive bundle-builder environment file at $ENV_FILE from exported variables"
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
7. Bundle behavior: DEPLOY_MODE artifact selector, SKIP_REPO_SYNC
8. Observability metadata: Grafana/Prometheus intent and Grafana host
9. Save and continue
EOF_MENU

    read -r -p "Choose what to change [9]: " choice
    choice="${choice:-9}"

    case "$choice" in
      1)
        _env_prompt SERVICE_TYPE "Service type" 1 0
        _env_prompt INGRESS_ENABLED "Render ingress? 1/0" 1 0
        _env_prompt TLS_ENABLED "Render TLS reference? 1/0" 1 0
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
        _env_prompt PHONE_IP "Monitored phone IP" 0 0
        _env_prompt PHONE_INTERFACE "Host network interface value" 0 0
        _env_prompt PHONE_PING_INTERVAL "Phone ping interval seconds" 1 0
        _env_prompt PHONE_OFFLINE_THRESHOLD "Offline threshold seconds" 1 0
        ;;
      4)
        _env_prompt TELEGRAM_BOT_TOKEN "Telegram bot token" 0 1
        _env_prompt TELEGRAM_CHAT_ID "Telegram chat ID" 0 0
        _env_prompt SMS_SECRET_TOKEN "SMS webhook secret token" 0 1
        ;;
      5)
        _env_prompt REDIS_ENABLED "Render Redis? 1/0" 1 0
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
        _env_prompt DEPLOY_MODE "Artifact selector: full, app, monitor, or none" 1 0
        _env_prompt SKIP_REPO_SYNC "Skip repo sync? auto, 1, or 0" 1 0
        ;;
      8)
        _env_prompt OBSERVABILITY_NAMESPACE "Observability namespace" 1 0
        _env_prompt OBSERVABILITY_INSTALL_STACK "Record Grafana/Prometheus stack as planned? 1/0" 1 0
        _env_prompt OBSERVABILITY_STACK_CHART_VERSION "kube-prometheus-stack chart version to record" 1 0
        _env_prompt GRAFANA_HOST "Grafana hostname" 1 0
        ;;
      9)
        normalize_loaded_env
        _write_env_file "$ENV_FILE"
        return 0
        ;;
      *)
        warn "invalid menu choice: $choice"
        ;;
    esac
  done
}

validate_env_required() {
  log "validating required bundle-builder environment values"

  _env_force_bundle_only_flags

  [ -n "${INSTALL_DIR:-}" ] || fatal "INSTALL_DIR is required in $ENV_FILE"

  case "${DEPLOY_MODE:-full}" in
    full|app|monitor|none) ;;
    *) fatal "DEPLOY_MODE is an artifact selector only. Use one of: full, app, monitor, none." ;;
  esac

  if ! _env_mode_requires_runtime_manifests; then
    log "DEPLOY_MODE=${DEPLOY_MODE:-none}; metadata-only environment validation completed"
    return 0
  fi

  [ -n "${NAMESPACE:-}" ] || fatal "NAMESPACE is required in $ENV_FILE"
  [ -n "${SERVICE_TYPE:-}" ] || fatal "SERVICE_TYPE is required in $ENV_FILE"

  case "${SERVICE_TYPE:-}" in
    ClusterIP|NodePort|LoadBalancer) ;;
    *) fatal "SERVICE_TYPE must be ClusterIP, NodePort, or LoadBalancer" ;;
  esac

  if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
    if _env_is_default_placeholder "${TLS_HOST:-}"; then
      warn "TLS_HOST is not finalized; bundle will carry placeholder value for production import/merge"
    fi
  fi

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    if _env_is_default_placeholder "${NFS_SERVER:-}" || _env_is_default_placeholder "${NFS_PATH:-}"; then
      warn "NFS_SERVER or NFS_PATH is not finalized; bundle will carry placeholder values for production import/merge"
    fi
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    if _env_is_default_placeholder "${METALLB_IP_RANGE:-}"; then
      warn "METALLB_IP_RANGE is not finalized; bundle metadata will carry a placeholder value for production import/merge"
    fi
  fi

  if _env_mode_requires_monitor; then
    if [ -z "${PHONE_IP:-}" ]; then
      warn "PHONE_IP is not set; monitor runtime target must be finalized by the approved production-side procedure"
    fi

    if [ -z "${PHONE_INTERFACE:-}" ]; then
      warn "PHONE_INTERFACE is not set; monitor runtime interface must be finalized by the approved production-side procedure"
    fi
  fi

  if _env_mode_requires_app && [ -z "${SMS_SECRET_TOKEN:-}" ]; then
    warn "SMS_SECRET_TOKEN is not set; production secret must be created by the approved production-side procedure"
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

  log "required bundle-builder environment values validated"
}

_env_reapply_runtime_overrides() {
  local runtime_noninteractive="$1"
  local runtime_skip_repo_sync="$2"
  local runtime_git_clean="$3"
  local runtime_dist_dir="${4:-}"

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

  if [ -n "$runtime_dist_dir" ]; then
    DIST_DIR="$runtime_dist_dir"
    export DIST_DIR
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
  local runtime_noninteractive="${NONINTERACTIVE:-}"
  local runtime_skip_repo_sync="${SKIP_REPO_SYNC:-}"
  local runtime_git_clean="${GIT_CLEAN:-}"
  local runtime_dist_dir="${DIST_DIR:-}"
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

  ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
  export ENV_FILE

  if [ -f "$ENV_FILE" ]; then
    log "loading environment from $ENV_FILE"

    if source_env_file "$ENV_FILE"; then
      ENV_FILE_LOADED=1
      loaded_existing_env=1
    else
      _env_reject_file "$ENV_FILE" "file is not valid shell syntax or could not be sourced"
      _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
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
    _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
    _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
    _env_create_new_file_for_current_mode
  fi

  if [ "$loaded_existing_env" = "1" ]; then
    _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
    _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
    normalize_loaded_env

    if _env_existing_file_is_recoverable_first_run; then
      _env_reject_file "$ENV_FILE" "file appears incomplete or still contains first-run placeholders"
      _env_clear_recoverable_placeholders
      _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
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
      if prompt_yes_no "Change saved bundle-builder environment values before continuing? [y/N]" "N"; then
        change_env_menu
        source_env_file "$ENV_FILE"
        _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
        _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"
        normalize_loaded_env
      fi
    else
      log "NONINTERACTIVE=1; using existing .env without prompting"
    fi
  fi

  source_env_file "$ENV_FILE"
  ENV_FILE_LOADED=1

  _env_reapply_runtime_overrides "$runtime_noninteractive" "$runtime_skip_repo_sync" "$runtime_git_clean" "$runtime_dist_dir"
  _env_restore_recovery_input DEPLOY_MODE "$runtime_deploy_mode"

  normalize_loaded_env
  validate_env_required

  log "environment source: $ENV_FILE"
}

normalize_loaded_env() {
  log "normalizing bundle-builder environment values"

  REPO_URL="${REPO_URL:-}"
  REPO_REF="${REPO_REF:-k8s-ansible-DEVtoPROD}"
  INSTALL_DIR="${INSTALL_DIR:-${SCRIPT_DIR:-$(pwd)}}"
  NAMESPACE="${NAMESPACE:-otp-relay-devprod}"
  APP_IMAGE="${APP_IMAGE:-otp-relay:latest}"
  MONITOR_IMAGE="${MONITOR_IMAGE:-otp-monitor:latest}"

  DEPLOY_MODE="${DEPLOY_MODE:-full}"
  case "$DEPLOY_MODE" in
    manifests|observability)
      warn "old DEPLOY_MODE=$DEPLOY_MODE is no longer supported as a live apply/install mode; using DEPLOY_MODE=full artifact selector"
      DEPLOY_MODE="full"
      ;;
  esac

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
  NFS_SERVER="${NFS_SERVER:-CHANGE_ME_NFS_SERVER}"
  NFS_PATH="${NFS_PATH:-CHANGE_ME_NFS_PATH}"
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
  METALLB_IP_RANGE="${METALLB_IP_RANGE:-CHANGE_ME_METALLB_IP_RANGE}"
  METALLB_POOL_NAME="${METALLB_POOL_NAME:-otp-relay-pool}"

  SERVER_HOSTNAME="${SERVER_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
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

  OTP_RELAY_DATA_DIR="${OTP_RELAY_DATA_DIR:-/app/data}"
  USERS_EXCEL_PATH="${USERS_EXCEL_PATH:-/app/data/users.xlsx}"
  AUDIT_LOG_PATH="${AUDIT_LOG_PATH:-/app/data/audit.log}"
  CLAIM_EXPIRY_SEC="${CLAIM_EXPIRY_SEC:-90}"
  OTP_DISPLAY_SEC="${OTP_DISPLAY_SEC:-285}"
  CONCURRENT_RISK_SEC="${CONCURRENT_RISK_SEC:-30}"

  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

  RUNTIME_DATA_DIR="${RUNTIME_DATA_DIR:-}"
  SKIP_HELP_DOCS_BUILD="${SKIP_HELP_DOCS_BUILD:-0}"
  GIT_CLEAN="${GIT_CLEAN:-1}"
  SKIP_REPO_SYNC="${SKIP_REPO_SYNC:-auto}"
  NONINTERACTIVE="${NONINTERACTIVE:-0}"
  DOCKER_BIN="${DOCKER_BIN:-}"
  DIST_DIR="${DIST_DIR:-dist}"

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

  IMAGE_DISTRIBUTION_PORT="${IMAGE_DISTRIBUTION_PORT:-18080}"
  IMAGE_IMPORTER_IMAGE="${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}"

  SMS_SECRET_TOKEN="${SMS_SECRET_TOKEN:-}"

  BRIDGE_NAME=""
  HOST_IFACE=""
  HOST_IP_CIDR=""
  GATEWAY=""
  DNS=""
  PREFIX=""
  IP_SCAN_PREFIX=""
  IP_SCAN_START=""
  IP_SCAN_END=""
  AUTO_ASSIGN_IPS="0"
  WORKER1_IP=""
  WORKER2_IP=""
  VM_USER=""
  VM_PASSWORD=""
  VM_RAM_MB=""
  VM_VCPUS=""
  VM_DISK_GB=""
  WORKER1_NAME=""
  WORKER2_NAME=""

  OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
  OBSERVABILITY_INSTALL_STACK="${OBSERVABILITY_INSTALL_STACK:-1}"
  OBSERVABILITY_STACK_CHART_VERSION="${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}"
  GRAFANA_HOST="${GRAFANA_HOST:-grafana-devprod.init-db.lan}"

  RESTART_APP_REQUIRED=0
  RESTART_MONITOR_REQUIRED=0

  _env_force_bundle_only_flags

  export REPO_URL REPO_REF INSTALL_DIR NAMESPACE APP_IMAGE MONITOR_IMAGE DEPLOY_MODE RELEASE_MODE
  export SERVICE_TYPE SERVICE_NODE_PORT LOADBALANCER_IP INGRESS_ENABLED TLS_ENABLED TLS_HOST TLS_SECRET_NAME TLS_SELF_SIGNED
  export PVC_STORAGE_CLASS PVC_SIZE NFS_ENABLED NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_PV_NAME NFS_MOUNT_OPTIONS
  export REPLICA_COUNT APP_NODE_SELECTOR_KEY APP_NODE_SELECTOR_VALUE MONITOR_NODE_SELECTOR_KEY MONITOR_NODE_SELECTOR_VALUE REDIS_NODE_SELECTOR_KEY REDIS_NODE_SELECTOR_VALUE
  export REQUIRE_METALLB INSTALL_METALLB METALLB_VERSION METALLB_MANIFEST_URL METALLB_IP_RANGE METALLB_POOL_NAME
  export SERVER_HOSTNAME SERVER_IP PORTAL_URL PORTAL_URL_EXPLICIT ASSIGNED_LOADBALANCER_ADDRESS PORTAL_URL_CONFIG_REFRESHED
  export PHONE_IP PHONE_INTERFACE PHONE_PING_INTERVAL PHONE_OFFLINE_THRESHOLD PHONE_ARP_COUNT PHONE_ARP_TIMEOUT MONITOR_METRICS_PORT
  export OTP_RELAY_DATA_DIR USERS_EXCEL_PATH AUDIT_LOG_PATH CLAIM_EXPIRY_SEC OTP_DISPLAY_SEC CONCURRENT_RISK_SEC
  export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID RUNTIME_DATA_DIR SKIP_HELP_DOCS_BUILD GIT_CLEAN SKIP_REPO_SYNC NONINTERACTIVE DOCKER_BIN DIST_DIR
  export REDIS_ENABLED REDIS_URL REDIS_REQUIRED REDIS_STORAGE_CLASS REDIS_SIZE REDIS_SPREAD_RECREATE_PVCS REDIS_NFS_PV_PREFIX REDIS_NFS_SERVER REDIS_NFS_BASE_PATH REDIS_NFS_MOUNT_OPTIONS
  export SMS_SECRET_TOKEN RESTART_APP_REQUIRED RESTART_MONITOR_REQUIRED
  export BRIDGE_NAME HOST_IFACE HOST_IP_CIDR GATEWAY DNS PREFIX IP_SCAN_PREFIX IP_SCAN_START IP_SCAN_END AUTO_ASSIGN_IPS WORKER1_IP WORKER2_IP VM_USER VM_PASSWORD VM_RAM_MB VM_VCPUS VM_DISK_GB WORKER1_NAME WORKER2_NAME
  export OBSERVABILITY_NAMESPACE OBSERVABILITY_INSTALL_STACK OBSERVABILITY_STACK_CHART_VERSION GRAFANA_HOST
  export SKIP_CLUSTER_DEPLOY SKIP_K3S_INSTALL SKIP_HELM_INSTALL SKIP_KUBECTL_APPLY SKIP_IMAGE_IMPORT SKIP_ROLLOUT_RESTART SKIP_LIVE_CLUSTER_VALIDATE SKIP_GITHUB_RUNNER_INSTALL SKIP_VM_PROVISIONING
  export DEPLOY_OTP_RELAY VALIDATE_OTP_RELAY INSTALL_GITHUB_RUNNER GITHUB_RUNNER_URL GITHUB_RUNNER_TOKEN GITHUB_RUNNER_DIR GITHUB_RUNNER_USER RUNNER_ONLY
  export DISTRIBUTE_IMAGES_TO_NODES IMAGE_DISTRIBUTION_PORT IMAGE_IMPORTER_IMAGE

  log "bundle-builder environment normalization completed"
}
