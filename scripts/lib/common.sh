#!/usr/bin/env bash
# Shared common helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - no root requirement
#   - no package installation
#   - no K3s installation
#   - no Kubernetes apply
#   - no Helm install/upgrade
#   - no image import into a live cluster
#   - no VM provisioning
#
# The production server receives only the finished bundle.

log() {
  printf '[otp-relay-k8s] %s\n' "$*"
}

warn() {
  printf '[otp-relay-k8s] WARNING: %s\n' "$*" >&2
}

fatal() {
  printf '[otp-relay-k8s] ERROR: %s\n' "$*" >&2
  exit 1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [ "$(id -u)" -eq 0 ]; then
    warn "running as root is not required for bundle creation"
  else
    log "root privileges are not required for bundle creation"
  fi
}

log_wait() {
  log "$1"
}

log_done() {
  log "completed: $1"
}

run_logged() {
  local message="$1"
  shift

  log "$message"
  "$@"
}

run_logged_shell() {
  local message="$1"
  shift

  log "$message"
  bash -c "$*"
}

wait_with_progress() {
  local message="$1"
  local timeout_seconds="$2"
  local interval_seconds="$3"
  shift 3

  local elapsed=0

  log "$message"

  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if "$@"; then
      log "completed: $message"
      return 0
    fi

    sleep "$interval_seconds"
    elapsed=$((elapsed + interval_seconds))

    if [ "$elapsed" -gt 0 ] && [ $((elapsed % 30)) -eq 0 ]; then
      log "still waiting after ${elapsed}s: $message"
    fi
  done

  fatal "timed out after ${timeout_seconds}s: $message"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer=""

  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    [ "$default" = "Y" ]
    return $?
  fi

  printf '%s ' "$prompt"
  read -r answer || answer=""
  answer="${answer:-$default}"

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

make_secret() {
  python3 - <<'PY' 2>/dev/null || tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 64
import secrets
print(secrets.token_hex(32))
PY
}
