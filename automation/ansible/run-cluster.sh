#!/usr/bin/env bash
set -Eeuo pipefail

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-${ANSIBLE_DIR}/inventory.generated.ini}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-poc}"
SSH_USER="${VM_USER:-otp-relay}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

cd "$ANSIBLE_DIR"

[[ -f "$INVENTORY" ]] || fatal "Missing inventory: $INVENTORY. Run automation/libvirt/provision-vms.sh first."

if ! command -v ansible >/dev/null 2>&1; then
  log "Installing Ansible on runner host..."
  sudo apt-get update
  sudo apt-get install -y ansible
fi

cleanup_known_hosts() {
  log "Removing stale SSH known_hosts entries for inventory hosts"

  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^\[/ { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, a, "=")
          print a[2]
        }
      }
    }
  ' "$INVENTORY" | sort -u | while read -r host; do
    [ -n "$host" ] || continue
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$host" >/dev/null 2>&1 || true
  done
}

write_ansible_ssh_defaults() {
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o ConnectTimeout=15"
}

print_cloud_init_diagnostics() {
  local limit="${1:-120}"

  ansible -i "$INVENTORY" all -b -m shell -a "
echo '===== HOST ====='
hostname -f || hostname || true
echo '===== cloud-init status ====='
cloud-init status --long || true
echo '===== cloud-init-output.log ====='
tail -${limit} /var/log/cloud-init-output.log 2>/dev/null || true
echo '===== cloud-init.log ====='
tail -${limit} /var/log/cloud-init.log 2>/dev/null || true
echo '===== apt term.log ====='
tail -${limit} /var/log/apt/term.log 2>/dev/null || true
echo '===== apt history.log ====='
tail -${limit} /var/log/apt/history.log 2>/dev/null || true
echo '===== apt/dpkg/cloud-init processes ====='
ps aux | grep -E 'apt|dpkg|cloud-init|unattended' | grep -v grep || true
echo '===== dpkg audit ====='
dpkg --audit || true
" || true
}

wait_for_cloud_init_and_locks() {
  log "Checking cloud-init status on all POC VMs..."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eu

if ! command -v cloud-init >/dev/null 2>&1; then
  echo "cloud-init not installed; skipping cloud-init wait"
  exit 0
fi

for i in $(seq 1 180); do
  status="$(cloud-init status 2>/dev/null || true)"

  echo "cloud-init status: ${status}"

  if printf "%s" "$status" | grep -q "status: done"; then
    exit 0
  fi

  if printf "%s" "$status" | grep -q "status: error"; then
    echo "cloud-init is in ERROR state"
    cloud-init status --long || true
    echo "---- /var/log/cloud-init-output.log ----"
    tail -200 /var/log/cloud-init-output.log 2>/dev/null || true
    echo "---- /var/log/apt/term.log ----"
    tail -120 /var/log/apt/term.log 2>/dev/null || true
    exit 50
  fi

  sleep 5
done

echo "Timed out waiting for cloud-init"
cloud-init status --long || true
tail -200 /var/log/cloud-init-output.log 2>/dev/null || true
exit 51
' || {
    warn "cloud-init failed or timed out on at least one VM"
    print_cloud_init_diagnostics 200
    fatal "cloud-init did not complete successfully"
  }

  log "Waiting for apt/dpkg locks on all POC VMs..."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eu

for i in $(seq 1 180); do
  blocked=0

  if pgrep -x apt-get >/dev/null 2>&1; then
    echo "apt-get is still running"
    blocked=1
  fi

  if pgrep -x apt >/dev/null 2>&1; then
    echo "apt is still running"
    blocked=1
  fi

  if pgrep -x dpkg >/dev/null 2>&1; then
    echo "dpkg is still running"
    blocked=1
  fi

  # Do not block on unattended-upgrade-shutdown --wait-for-signal.
  # That helper can remain idle after boot and does not indicate an active apt/dpkg transaction.

  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "/var/lib/dpkg/lock-frontend is locked"
    blocked=1
  fi

  if fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
    echo "/var/lib/dpkg/lock is locked"
    blocked=1
  fi

  if fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
    echo "/var/cache/apt/archives/lock is locked"
    blocked=1
  fi

  if [ "$blocked" = "0" ]; then
    exit 0
  fi

  echo "Waiting for apt/dpkg locks..."
  sleep 5
done

echo "Timed out waiting for apt/dpkg locks"
ps aux | grep -E "apt|dpkg|cloud-init|unattended" | grep -v grep || true
exit 52
' || {
    warn "apt/dpkg locks did not clear on at least one VM"
    print_cloud_init_diagnostics 200
    fatal "apt/dpkg lock wait failed"
  }
}

repair_apt_if_needed() {
  log "Repairing apt/dpkg state if needed..."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eux

export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a || true

apt-get update
apt-get install -f -y

apt-get install -y \
  openssh-server \
  sudo \
  curl \
  ca-certificates \
  gnupg \
  git \
  jq \
  python3 \
  nfs-common
'
}

inventory_hosts() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^\[/ { next }
    {
      host=$1
      ip=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, a, "=")
          ip=a[2]
        }
      }
      if (host != "" && ip != "") {
        print host, ip
      }
    }
  ' "$INVENTORY"
}

check_raw_ssh_reachability() {
  log "Checking raw SSH reachability for each inventory host..."

  inventory_hosts | while read -r host ip; do
    [ -n "$host" ] || continue
    [ -n "$ip" ] || continue

    log "checking SSH: ${host} (${ip})"
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true

    if ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
        -o ConnectTimeout=15 \
        -i "$SSH_KEY" \
        "${SSH_USER}@${ip}" \
        'hostname; cloud-init status --long || true; ip -br addr || true; ip route || true; getent hosts deb.debian.org || true' ; then
      ok "SSH reachable: ${host} (${ip})"
    else
      fatal "SSH failed for ${host} (${ip}). Check VM state/network before continuing."
    fi
  done
}

cleanup_known_hosts
write_ansible_ssh_defaults
check_raw_ssh_reachability

log "Waiting for Ansible SSH connection on all POC VMs..."
ansible -i "$INVENTORY" all -m wait_for_connection -a "timeout=180 sleep=5" -vv

wait_for_cloud_init_and_locks
repair_apt_if_needed

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

ok "Cluster automation completed."
