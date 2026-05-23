#!/usr/bin/env bash
set -Eeuo pipefail

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-${ANSIBLE_DIR}/inventory.generated.ini}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-cluster}"
SSH_USER="${VM_USER:-otp-relay}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"

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

fix_local_ssh_permissions() {
  local ssh_dir
  ssh_dir="$(dirname "$KNOWN_HOSTS")"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir" || true

  if [ -n "${USER:-}" ]; then
    sudo chown -R "$USER:$USER" "$ssh_dir" 2>/dev/null || true
  fi

  touch "$KNOWN_HOSTS"
  chmod 644 "$KNOWN_HOSTS" || true

  if [ -f "$SSH_KEY" ]; then
    chmod 600 "$SSH_KEY" || true
  fi

  if [ -f "${SSH_KEY}.pub" ]; then
    chmod 644 "${SSH_KEY}.pub" || true
  fi
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
  ' "$INVENTORY" | sort -u
}

cleanup_known_hosts() {
  log "Removing stale SSH known_hosts entries for inventory hosts"

  inventory_hosts | while read -r host ip; do
    [ -n "$ip" ] || continue
    ssh-keygen -f "$KNOWN_HOSTS" -R "$ip" >/dev/null 2>&1 || true
    ssh-keygen -f "$KNOWN_HOSTS" -R "[$ip]:22" >/dev/null 2>&1 || true
  done
}

write_ansible_ssh_defaults() {
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=15"
}

raw_ssh_check() {
  log "Checking raw SSH reachability for each inventory host..."

  inventory_hosts | while read -r host ip; do
    log "checking SSH: ${host} (${ip})"

    if ssh \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o ConnectTimeout=15 \
      -i "$SSH_KEY" \
      "${SSH_USER}@${ip}" \
      'hostname; cloud-init status --long 2>/dev/null || true' >/tmp/otp-relay-ssh-check.$$ 2>&1; then
      sed 's/^/[ssh-check] /' /tmp/otp-relay-ssh-check.$$ || true
      ok "SSH reachable: ${host} (${ip})"
    else
      sed 's/^/[ssh-check] /' /tmp/otp-relay-ssh-check.$$ >&2 || true
      rm -f /tmp/otp-relay-ssh-check.$$
      fatal "SSH failed for ${host} (${ip}). Check VM console/network before continuing."
    fi

    rm -f /tmp/otp-relay-ssh-check.$$
  done
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
echo '===== resolv.conf ====='
cat /etc/resolv.conf || true
echo '===== resolved status ====='
resolvectl status 2>/dev/null || true
echo '===== apt term.log ====='
tail -${limit} /var/log/apt/term.log 2>/dev/null || true
echo '===== apt history.log ====='
tail -${limit} /var/log/apt/history.log 2>/dev/null || true
echo '===== apt/dpkg/cloud-init processes ====='
ps aux | grep -E 'apt-get|apt |dpkg|cloud-init|unattended' | grep -v grep || true
echo '===== dpkg audit ====='
dpkg --audit || true
" || true
}

wait_for_cloud_init_and_locks() {
  log "Checking cloud-init status on all cluster VMs..."

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

  log "Waiting for apt/dpkg locks on all cluster VMs..."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eu

for i in $(seq 1 120); do
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
ps aux | grep -E "apt-get|apt |dpkg|cloud-init|unattended" | grep -v grep || true
exit 52
' || {
    warn "apt/dpkg locks did not clear on at least one VM"
    print_cloud_init_diagnostics 200
    fatal "apt/dpkg lock wait failed"
  }
}

repair_dns_on_guests() {
  log "Repairing and validating DNS on all cluster VMs..."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eux

mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/otp-relay-dns.conf <<DNSCONF
[Resolve]
DNS=172.31.11.1 1.1.1.1 8.8.8.8
FallbackDNS=1.1.1.1 8.8.8.8
DNSSEC=no
DNSOverTLS=no
DNSCONF

rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved || true

cat /etc/resolv.conf
getent hosts deb.debian.org
'
}

repair_apt_if_needed() {
  log "Repairing apt/dpkg state if needed..."
  log "This can take several minutes if Debian mirrors are slow. Apt timeouts are capped at 30s with retries."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eux

export DEBIAN_FRONTEND=noninteractive

apt_opts="-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2"

dpkg --configure -a || true

apt-get $apt_opts update
apt-get $apt_opts install -f -y
apt-get $apt_opts install -y \
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

run_playbook() {
  local label="$1"
  local playbook="$2"

  log "$label"
  ansible-playbook -i "$INVENTORY" "$playbook"
}

fix_local_ssh_permissions
cleanup_known_hosts
write_ansible_ssh_defaults
raw_ssh_check

log "Waiting for Ansible SSH connection on all cluster VMs..."
ansible -i "$INVENTORY" all -m wait_for_connection -a "timeout=180 sleep=5" -vv

wait_for_cloud_init_and_locks
repair_dns_on_guests
repair_apt_if_needed

log "Running Ansible ping..."
ansible -i "$INVENTORY" all -m ping

run_playbook "Running OS baseline..." playbooks/00-os-baseline.yml
run_playbook "Installing K3s control-plane..." playbooks/10-k3s-control-plane.yml
run_playbook "Installing K3s workers..." playbooks/20-k3s-workers.yml
run_playbook "Applying node labels..." playbooks/30-node-labels.yml

if [ -f playbooks/40-storage-validate.yml ]; then
  if [ -n "${NFS_SERVER:-}" ] || [ -n "${STORAGE_SERVER:-}" ] || [ -n "${NFS_EXPORT:-}" ]; then
    run_playbook "Validating storage..." playbooks/40-storage-validate.yml
  else
    log "Skipping storage validation because no NFS/storage variables are configured."
  fi
fi

if [[ "${DEPLOY_OTP_RELAY:-0}" == "1" ]]; then
  run_playbook "Deploying OTP Relay..." playbooks/50-deploy-otp-relay.yml
fi

if [[ "${VALIDATE_OTP_RELAY:-0}" == "1" ]]; then
  run_playbook "Validating production state..." playbooks/70-validate-production.yml
fi

ok "Cluster automation completed."
