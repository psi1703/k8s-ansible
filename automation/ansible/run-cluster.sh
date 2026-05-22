#!/usr/bin/env bash
set -Eeuo pipefail

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-${ANSIBLE_DIR}/inventory.poc.generated.ini}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

cd "$ANSIBLE_DIR"

[[ -f "$INVENTORY" ]] || fatal "Missing inventory: $INVENTORY. Run automation/libvirt/provision-vms.sh first."

if ! command -v ansible >/dev/null 2>&1; then
  log "Installing Ansible on runner host..."
  sudo apt-get update
  sudo apt-get install -y ansible
fi

log "Waiting for Ansible SSH connection on all POC VMs..."
ansible -i "$INVENTORY" all -m wait_for_connection -a "timeout=900 sleep=5"

log "Waiting for cloud-init and apt/dpkg locks on all POC VMs..."
ansible -i "$INVENTORY" all -b -m shell -a '
set -e

if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait || true
fi

for i in $(seq 1 180); do
  if ! pgrep -x apt-get >/dev/null 2>&1 &&
     ! pgrep -x apt >/dev/null 2>&1 &&
     ! pgrep -x dpkg >/dev/null 2>&1 &&
     ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 &&
     ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 &&
     ! fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
    exit 0
  fi

  echo "Waiting for cloud-init/apt/dpkg locks..."
  sleep 5
done

echo "Timed out waiting for apt/dpkg locks"
ps aux | grep -E "apt|dpkg|cloud-init" | grep -v grep || true
exit 1
'

log "Running Ansible ping..."
ansible -i "$INVENTORY" all -m ping

log "Running OS baseline..."
ansible-playbook -i "$INVENTORY" playbooks/00-os-baseline.yml

log "Installing K3s control-plane..."
ansible-playbook -i "$INVENTORY" playbooks/10-k3s-control-plane.yml

log "Installing K3s workers..."
ansible-playbook -i "$INVENTORY" playbooks/20-k3s-workers.yml

log "Applying node labels..."
ansible-playbook -i "$INVENTORY" playbooks/30-node-labels.yml

log "Validating storage..."
ansible-playbook -i "$INVENTORY" playbooks/40-storage-validate.yml

if [[ "${DEPLOY_OTP_RELAY:-0}" == "1" ]]; then
  log "Deploying OTP Relay..."
  ansible-playbook -i "$INVENTORY" playbooks/50-deploy-otp-relay.yml
fi

if [[ "${VALIDATE_OTP_RELAY:-0}" == "1" ]]; then
  log "Validating production/POC state..."
  ansible-playbook -i "$INVENTORY" playbooks/70-validate-production.yml
fi

ok "POC cluster automation completed."
