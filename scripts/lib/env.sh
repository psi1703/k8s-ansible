#!/usr/bin/env bash
# Environment source-of-truth helpers for install-otp-relay-k8s.sh.
# This file is sourced by the installer; do not execute it directly.

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

_write_env_file() {
  local target="$1"
  local tmp="${target}.tmp"

  log "writing installer environment file: $target"

  umask 077
  cat > "$tmp" <<EOF_ENV
# OTP Relay Kubernetes runtime configuration.
# This file is the single input source for the installer, rendered Kubernetes
# manifests, Ansible deployment handoff, and monitor/app runtime settings.
# Keep secrets in this file only. Do not commit populated .env files.

# Internal repository / install location.
# These are written for transparency, but they are not first-run prompts.
REPO_URL=$(_env_quote "${REPO_URL:-}")
REPO_REF=$(_env_quote "${REPO_REF:-main}")
INSTALL_DIR=$(_env_quote "${INSTALL_DIR:-${SCRIPT_DIR}}")
NAMESPACE=$(_env_quote "${NAMESPACE:-otp-relay}")

# Images / deployment behavior
APP_IMAGE=$(_env_quote "${APP_IMAGE:-otp-relay:latest}")
MONITOR_IMAGE=$(_env_quote "${MONITOR_IMAGE:-otp-monitor:latest}")
DEPLOY_MODE=$(_env_quote "${DEPLOY_MODE:-full}")
SERVICE_TYPE=$(_env_quote "${SERVICE_TYPE:-ClusterIP}")
SERVICE_NODE_PORT=$(_env_quote "${SERVICE_NODE_PORT:-30080}")
LOADBALANCER_IP=$(_env_quote "${LOADBALANCER_IP:-}")
INGRESS_ENABLED=$(_env_quote "${INGRESS_ENABLED:-1}")
TLS_ENABLED=$(_env_quote "${TLS_ENABLED:-0}")
TLS_HOST=$(_env_quote "${TLS_HOST:-}")
TLS_SECRET_NAME=$(_env_quote "${TLS_SECRET_NAME:-otp-relay-tls}")
TLS_SELF_SIGNED=$(_env_quote "${TLS_SELF_SIGNED:-1}")
PORTAL_URL=$(_env_quote "${PORTAL_URL:-}")

# Storage
PVC_STORAGE_CLASS=$(_env_quote "${PVC_STORAGE_CLASS:-}")
PVC_SIZE=$(_env_quote "${PVC_SIZE:-1Gi}")
NFS_ENABLED=$(_env_quote "${NFS_ENABLED:-0}")
NFS_SERVER=$(_env_quote "${NFS_SERVER:-}")
NFS_PATH=$(_env_quote "${NFS_PATH:-}")
NFS_STORAGE_CLASS=$(_env_quote "${NFS_STORAGE_CLASS:-otp-relay-nfs}")
NFS_PV_NAME=$(_env_quote "${NFS_PV_NAME:-otp-relay-data-nfs-pv}")
NFS_MOUNT_OPTIONS=$(_env_quote "${NFS_MOUNT_OPTIONS:-nfsvers=4.1}")

# Replicas / placement
REPLICA_COUNT=$(_env_quote "${REPLICA_COUNT:-1}")
APP_NODE_SELECTOR_KEY=$(_env_quote "${APP_NODE_SELECTOR_KEY:-}")
APP_NODE_SELECTOR_VALUE=$(_env_quote "${APP_NODE_SELECTOR_VALUE:-}")
MONITOR_NODE_SELECTOR_KEY=$(_env_quote "${MONITOR_NODE_SELECTOR_KEY:-}")
MONITOR_NODE_SELECTOR_VALUE=$(_env_quote "${MONITOR_NODE_SELECTOR_VALUE:-}")
REDIS_NODE_SELECTOR_KEY=$(_env_quote "${REDIS_NODE_SELECTOR_KEY:-}")
REDIS_NODE_SELECTOR_VALUE=$(_env_quote "${REDIS_NODE_SELECTOR_VALUE:-}")

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
REDIS_STORAGE_CLASS=$(_env_quote "${REDIS_STORAGE_CLASS:-local-path}")
REDIS_SIZE=$(_env_quote "${REDIS_SIZE:-1Gi}")
REDIS_SPREAD_RECREATE_PVCS=$(_env_quote "${REDIS_SPREAD_RECREATE_PVCS:-auto}")

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

  log "sourcing environment file: $source_file"
  set -a
  # shellcheck disable=SC1090
  . "$source_file"
  set +a
}

create_env_interactive() {
  log "creating first-run environment file at $ENV_FILE"
  log "interactive setup will ask only for operator-owned values"

  _env_set_default REPO_URL ""
  _env_set_default REPO_REF "main"
  _env_set_default INSTALL_DIR "$SCRIPT_DIR"
  _env_set_default DEPLOY_MODE "full"
  _env_set_default RUNNER_ONLY "0"

  _env_set_default NAMESPACE "otp-relay"
  _env_set_default SERVICE_TYPE "ClusterIP"
  _env_set_default INGRESS_ENABLED "1"
  _env_set_default TLS_ENABLED "0"
  _env_set_default NFS_ENABLED "0"
  _env_set_default INSTALL_METALLB "0"
  _env_set_default REDIS_ENABLED "1"
  _env_set_default REDIS_REQUIRED "1"
  _env_set_default REDIS_URL "redis://otp-redis-haproxy:6379/0"
  _env_set_default REPLICA_COUNT "1"
  _env_set_default PHONE_PING_INTERVAL "10"
  _env_set_default PHONE_OFFLINE_THRESHOLD "30"

  _env_prompt NAMESPACE "Kubernetes namespace" 1 0
  _env_prompt SERVICE_TYPE "Service type: ClusterIP, NodePort, or LoadBalancer" 1 0
  _env_prompt INGRESS_ENABLED "Enable ingress? 1=yes, 0=no" 1 0
  _env_prompt TLS_ENABLED "Enable TLS? 1=yes, 0=no" 1 0

  if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
    _env_prompt TLS_HOST "Ingress/TLS hostname" 1 0
  fi

  _env_prompt NFS_ENABLED "Use NFS-backed app PVC? 1=yes, 0=no" 1 0
  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    _env_prompt NFS_SERVER "NFS server IP/DNS" 1 0
    _env_prompt NFS_PATH "NFS export path" 1 0
    PVC_STORAGE_CLASS="${PVC_STORAGE_CLASS:-${NFS_STORAGE_CLASS:-otp-relay-nfs}}"
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
  _env_prompt PHONE_OFFLINE_THRESHOLD "Phone offline threshold" 1 0

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
1) Network/exposure: SERVICE_TYPE, INGRESS_ENABLED, TLS_ENABLED, TLS_HOST, PORTAL_URL
2) Storage: PVC_STORAGE_CLASS, NFS_ENABLED, NFS_SERVER, NFS_PATH
3) Monitor phone: PHONE_IP, PHONE_INTERFACE, PHONE_PING_INTERVAL, PHONE_OFFLINE_THRESHOLD
4) Alerts/secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SMS_SECRET_TOKEN
5) Redis: REDIS_ENABLED, REDIS_URL, REDIS_REQUIRED, REDIS_STORAGE_CLASS
6) Placement/replicas: REPLICA_COUNT, node selectors
7) Installer behavior: DEPLOY_MODE, RUNNER_ONLY, SKIP_REPO_SYNC
8) Save and continue
EOF_MENU

    read -r -p "Choose what to change [8]: " choice
    choice="${choice:-8}"

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
        _env_prompt NFS_ENABLED "Use NFS? 1/0" 1 0
        _env_prompt NFS_SERVER "NFS server IP/DNS" 0 0
        _env_prompt NFS_PATH "NFS export path" 0 0
        ;;
      3)
        _env_prompt PHONE_IP "Monitored phone IP" 1 0
        _env_prompt PHONE_INTERFACE "Host network interface" 1 0
        _env_prompt PHONE_PING_INTERVAL "Phone ping interval seconds" 1 0
        _env_prompt PHONE_OFFLINE_THRESHOLD "Offline threshold" 1 0
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
        _env_prompt DEPLOY_MODE "Deploy mode: full, app, monitor, manifests, or none" 1 0
        _env_prompt RUNNER_ONLY "Runner-only mode? 1/0" 1 0
        _env_prompt SKIP_REPO_SYNC "Skip repo sync? auto, 1, or 0" 1 0
        ;;
      8)
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
  [ -n "${SERVICE_TYPE:-}" ] || fatal "SERVICE_TYPE is required in $ENV_FILE"
  [ -n "${PHONE_IP:-}" ] || fatal "PHONE_IP is required in $ENV_FILE because the monitor is a core component"
  [ -n "${PHONE_INTERFACE:-}" ] || fatal "PHONE_INTERFACE is required in $ENV_FILE because ARP monitoring requires a host interface"

  if [ "${INGRESS_ENABLED:-0}" = "1" ] || [ "${TLS_ENABLED:-0}" = "1" ]; then
    [ -n "${TLS_HOST:-}" ] || fatal "TLS_HOST is required in $ENV_FILE when ingress or TLS is enabled"
  fi

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    [ -n "${NFS_SERVER:-}" ] || fatal "NFS_SERVER is required in $ENV_FILE when NFS_ENABLED=1"
    [ -n "${NFS_PATH:-}" ] || fatal "NFS_PATH is required in $ENV_FILE when NFS_ENABLED=1"
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    [ -n "${METALLB_IP_RANGE:-}" ] || fatal "METALLB_IP_RANGE is required in $ENV_FILE when INSTALL_METALLB=1"
  fi

  [ -n "${SMS_SECRET_TOKEN:-}" ] || fatal "SMS_SECRET_TOKEN is required in $ENV_FILE"

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

load_or_create_env() {
  ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
  export ENV_FILE

  # Runtime overrides passed by Ansible/caller must win over persisted .env values.
  # Example: .env may contain NONINTERACTIVE=0, but Ansible deployment must run with NONINTERACTIVE=1.
  local runtime_noninteractive="${NONINTERACTIVE:-}"
  local runtime_skip_repo_sync="${SKIP_REPO_SYNC:-}"
  local runtime_git_clean="${GIT_CLEAN:-}"

  if [ -f "$ENV_FILE" ]; then
    log "loading environment from $ENV_FILE"
    source_env_file "$ENV_FILE"
    ENV_FILE_LOADED=1

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

    normalize_loaded_env

    if [ "${NONINTERACTIVE:-0}" != "1" ]; then
      if prompt_yes_no "Change saved installer environment values before continuing? [y/N]" "N"; then
        change_env_menu
        source_env_file "$ENV_FILE"

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

        normalize_loaded_env
      fi
    else
      log "NONINTERACTIVE=1; using existing .env without prompting"
    fi
  else
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      create_env_noninteractive
    else
      create_env_interactive
    fi

    source_env_file "$ENV_FILE"
    ENV_FILE_LOADED=1

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

    normalize_loaded_env
  fi

  validate_env_required
  log "environment source: $ENV_FILE"
}

normalize_loaded_env() {
  log "normalizing installer environment values"

  REPO_URL="${REPO_URL:-}"
  REPO_REF="${REPO_REF:-main}"
  INSTALL_DIR="${INSTALL_DIR:-${SCRIPT_DIR}}"
  NAMESPACE="${NAMESPACE:-otp-relay}"
  APP_IMAGE="${APP_IMAGE:-otp-relay:latest}"
  MONITOR_IMAGE="${MONITOR_IMAGE:-otp-monitor:latest}"

  SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"
  SERVICE_NODE_PORT="${SERVICE_NODE_PORT:-30080}"
  LOADBALANCER_IP="${LOADBALANCER_IP:-}"
  INGRESS_ENABLED="${INGRESS_ENABLED:-1}"
  TLS_ENABLED="${TLS_ENABLED:-0}"
  TLS_HOST="${TLS_HOST:-}"
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

  REPLICA_COUNT="${REPLICA_COUNT:-1}"
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
  REDIS_STORAGE_CLASS="${REDIS_STORAGE_CLASS:-local-path}"
  REDIS_SIZE="${REDIS_SIZE:-1Gi}"
  REDIS_SPREAD_RECREATE_PVCS="${REDIS_SPREAD_RECREATE_PVCS:-auto}"

  DISTRIBUTE_IMAGES_TO_NODES="${DISTRIBUTE_IMAGES_TO_NODES:-1}"
  IMAGE_DISTRIBUTION_PORT="${IMAGE_DISTRIBUTION_PORT:-18080}"
  IMAGE_IMPORTER_IMAGE="${IMAGE_IMPORTER_IMAGE:-redis:7-alpine}"
  SMS_SECRET_TOKEN="${SMS_SECRET_TOKEN:-$(make_secret)}"

  RESTART_APP_REQUIRED=0
  RESTART_MONITOR_REQUIRED=0

  export REPO_URL REPO_REF INSTALL_DIR NAMESPACE APP_IMAGE MONITOR_IMAGE SERVICE_TYPE SERVICE_NODE_PORT LOADBALANCER_IP INGRESS_ENABLED TLS_ENABLED TLS_HOST TLS_SECRET_NAME TLS_SELF_SIGNED
  export PVC_STORAGE_CLASS PVC_SIZE NFS_ENABLED NFS_SERVER NFS_PATH NFS_STORAGE_CLASS NFS_PV_NAME NFS_MOUNT_OPTIONS REPLICA_COUNT APP_NODE_SELECTOR_KEY APP_NODE_SELECTOR_VALUE
  export MONITOR_NODE_SELECTOR_KEY MONITOR_NODE_SELECTOR_VALUE REDIS_NODE_SELECTOR_KEY REDIS_NODE_SELECTOR_VALUE REQUIRE_METALLB INSTALL_METALLB METALLB_VERSION METALLB_MANIFEST_URL METALLB_IP_RANGE METALLB_POOL_NAME
  export SERVER_HOSTNAME SERVER_IP PORTAL_URL PORTAL_URL_EXPLICIT ASSIGNED_LOADBALANCER_ADDRESS PORTAL_URL_CONFIG_REFRESHED PHONE_IP PHONE_INTERFACE PHONE_PING_INTERVAL PHONE_OFFLINE_THRESHOLD PHONE_ARP_COUNT PHONE_ARP_TIMEOUT MONITOR_METRICS_PORT
  export OTP_RELAY_DATA_DIR USERS_EXCEL_PATH AUDIT_LOG_PATH CLAIM_EXPIRY_SEC OTP_DISPLAY_SEC CONCURRENT_RISK_SEC
  export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID RUNTIME_DATA_DIR SKIP_HELP_DOCS_BUILD GIT_CLEAN SKIP_REPO_SYNC NONINTERACTIVE INSTALL_GITHUB_RUNNER GITHUB_RUNNER_URL GITHUB_RUNNER_TOKEN
  export GITHUB_RUNNER_DIR GITHUB_RUNNER_USER RUNNER_ONLY DEPLOY_MODE DOCKER_BIN REDIS_ENABLED REDIS_URL REDIS_REQUIRED REDIS_STORAGE_CLASS REDIS_SIZE REDIS_SPREAD_RECREATE_PVCS
  export DISTRIBUTE_IMAGES_TO_NODES IMAGE_DISTRIBUTION_PORT IMAGE_IMPORTER_IMAGE SMS_SECRET_TOKEN RESTART_APP_REQUIRED RESTART_MONITOR_REQUIRED

  log "installer environment normalization completed"
}
