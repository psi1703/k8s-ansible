#!/usr/bin/env bash
# Layer: repo-sync systemd timer installation.
#
# This script installs or updates a local systemd service and timer that run
# scripts/sync-repo.sh on a schedule.
#
# Responsibilities:
# - Install a systemd oneshot service for repository sync.
# - Install a systemd timer for scheduled repository sync.
# - Keep repo sync separate from deployment and runtime mutation.
# - Preserve the current checkout path as the service working directory.
#
# Non-responsibilities:
# - It does not deploy OTP Relay.
# - It does not run setup.sh.
# - It does not run install-otp-relay-k8s.sh.
# - It does not run Ansible, Helm, kubectl apply, or K3s installation.
# - It does not install GitHub runners.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_SCRIPT="${REPO_DIR}/scripts/sync-repo.sh"

SERVICE_NAME="otp-relay-repo-sync.service"
TIMER_NAME="otp-relay-repo-sync.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

SYNC_USER="${SYNC_USER:-$(id -un)}"
SYNC_GROUP="${SYNC_GROUP:-$(id -gn)}"
ON_BOOT_SEC="${ON_BOOT_SEC:-5min}"
ON_UNIT_ACTIVE_SEC="${ON_UNIT_ACTIVE_SEC:-15min}"
RANDOMIZED_DELAY_SEC="${RANDOMIZED_DELAY_SEC:-30s}"

log() {
  printf '[repo-sync-timer] %s %s\n' "$(date -Is)" "$*"
}

fail() {
  printf '[repo-sync-timer] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || fail "sudo is required when not running as root"
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

validate_inputs() {
  [ -d "$REPO_DIR/.git" ] || fail "repository root not found at $REPO_DIR"
  [ -f "$SYNC_SCRIPT" ] || fail "sync script not found: $SYNC_SCRIPT"
  [ -x "$SYNC_SCRIPT" ] || chmod 755 "$SYNC_SCRIPT"
  id "$SYNC_USER" >/dev/null 2>&1 || fail "sync user does not exist: $SYNC_USER"
  getent group "$SYNC_GROUP" >/dev/null 2>&1 || fail "sync group does not exist: $SYNC_GROUP"
}

write_service() {
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp" <<EOF_SERVICE
[Unit]
Description=OTP Relay repository sync
Documentation=file://${REPO_DIR}/systemd/README-repo-sync-timer
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${SYNC_USER}
Group=${SYNC_GROUP}
WorkingDirectory=${REPO_DIR}
ExecStart=${SYNC_SCRIPT}
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# Safety boundary: repository sync only. The sync script must not deploy,
# restart workloads, install K3s, run Helm, run Ansible, or apply manifests.
NoNewPrivileges=true
EOF_SERVICE

  as_root install -m 0644 "$tmp" "$SERVICE_PATH"
  rm -f "$tmp"
}

write_timer() {
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp" <<EOF_TIMER
[Unit]
Description=Run OTP Relay repository sync periodically
Documentation=file://${REPO_DIR}/systemd/README-repo-sync-timer

[Timer]
OnBootSec=${ON_BOOT_SEC}
OnUnitActiveSec=${ON_UNIT_ACTIVE_SEC}
RandomizedDelaySec=${RANDOMIZED_DELAY_SEC}
Persistent=true
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF_TIMER

  as_root install -m 0644 "$tmp" "$TIMER_PATH"
  rm -f "$tmp"
}

install_timer() {
  log "Installing systemd service: $SERVICE_PATH"
  write_service

  log "Installing systemd timer: $TIMER_PATH"
  write_timer

  log "Reloading systemd"
  as_root systemctl daemon-reload

  log "Enabling and starting timer: $TIMER_NAME"
  as_root systemctl enable --now "$TIMER_NAME"

  log "Timer status"
  as_root systemctl --no-pager --full status "$TIMER_NAME" || true

  log "Installed repo-sync timer for $REPO_DIR"
  log "Schedule: OnBootSec=${ON_BOOT_SEC}, OnUnitActiveSec=${ON_UNIT_ACTIVE_SEC}, RandomizedDelaySec=${RANDOMIZED_DELAY_SEC}"
}

main() {
  need_cmd date
  need_cmd getent
  need_cmd id
  need_cmd install
  need_cmd mktemp
  need_cmd systemctl
  require_root_or_sudo
  validate_inputs
  install_timer
}

main "$@"
