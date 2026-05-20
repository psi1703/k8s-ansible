#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

log() { printf '[otp-relay-k8s] %s\n' "$*"; }

warn() { printf '[otp-relay-k8s] WARNING: %s\n' "$*" >&2; }

fatal() { printf '[otp-relay-k8s] ERROR: %s\n' "$*" >&2; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() { [ "$(id -u)" -eq 0 ] || fatal "run as root: sudo bash $0"; }

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer=""
  if [ "$NONINTERACTIVE" = "1" ]; then
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

