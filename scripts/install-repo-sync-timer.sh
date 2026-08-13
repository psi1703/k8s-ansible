#!/usr/bin/env bash
set -Eeuo pipefail

# Install a systemd timer that runs scripts/sync-repo.sh periodically.
# This replaces the GitHub Actions self-hosted runner sync model.
# It only syncs the local repository by default; it does not deploy.

REPO_DIR="${REPO_DIR:-/opt/k8s-ansible}"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/psi1703/k8s-ansible.git}"
SYNC_INTERVAL="${SYNC_INTERVAL:-1min}"
SERVICE_NAME="${SERVICE_NAME:-k8s-ansible-repo-sync}"
RUN_AFTER_SYNC="${RUN_AFTER_SYNC:-0}"
AFTER_SYNC_CMD="${AFTER_SYNC_CMD:-}"

log() { printf '[repo-sync-timer] %s\n' "$*"; }
fatal() { printf '[repo-sync-timer] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$REPO_DIR/scripts/sync-repo.sh" ]] || fatal "Missing $REPO_DIR/scripts/sync-repo.sh"

sudo install -m 0755 "$REPO_DIR/scripts/sync-repo.sh" /usr/local/sbin/k8s-ansible-repo-sync

sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<SERVICEEOF
[Unit]
Description=Sync k8s-ansible local checkout from GitHub
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
Environment=REPO_URL=${REPO_URL}
Environment=REPO_DIR=${REPO_DIR}
Environment=BRANCH=${BRANCH}
Environment=RUN_AFTER_SYNC=${RUN_AFTER_SYNC}
Environment=AFTER_SYNC_CMD=${AFTER_SYNC_CMD}
ExecStart=/usr/local/sbin/k8s-ansible-repo-sync
SERVICEEOF

sudo tee "/etc/systemd/system/${SERVICE_NAME}.timer" >/dev/null <<TIMEREOF
[Unit]
Description=Run k8s-ansible repo sync periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=${SYNC_INTERVAL}
AccuracySec=10s
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
TIMEREOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}.timer"

log "Installed and started ${SERVICE_NAME}.timer"
log "Timer status: systemctl status ${SERVICE_NAME}.timer --no-pager"
log "Manual sync:   sudo systemctl start ${SERVICE_NAME}.service"
log "Sync logs:     sudo tail -f /var/log/k8s-ansible/repo-sync.log"
