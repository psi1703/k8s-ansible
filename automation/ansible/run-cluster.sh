#!/usr/bin/env bash
set -Eeuo pipefail

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ANSIBLE_DIR}/../.." && pwd)"
INVENTORY="${INVENTORY:-${ANSIBLE_DIR}/inventory.generated.ini}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-cluster}"
SSH_USER="${VM_USER:-otp-relay}"

DEPLOY_OTP_RELAY="${DEPLOY_OTP_RELAY:-1}"
VALIDATE_OTP_RELAY="${VALIDATE_OTP_RELAY:-0}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

cd "$ANSIBLE_DIR"

[[ -f "$INVENTORY" ]] || fatal "Missing inventory: $INVENTORY. Run automation/libvirt/provision-vms.sh first."

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
fi

BRIDGE_NAME="${BRIDGE_NAME:-br0}"

fix_local_ssh_permissions() {
  local ssh_dir="$HOME/.ssh"
  local known_hosts="$ssh_dir/known_hosts"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir" || true

  if [[ -n "${USER:-}" ]]; then
    sudo chown -R "$USER:$USER" "$ssh_dir" 2>/dev/null || true
  fi

  touch "$known_hosts"
  chmod 644 "$known_hosts" || true

  if [[ -f "$SSH_KEY" ]]; then
    chmod 600 "$SSH_KEY" || true
  fi

  if [[ -f "${SSH_KEY}.pub" ]]; then
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
  ' "$INVENTORY"
}

inventory_ips() {
  inventory_hosts | awk '{print $2}' | sort -u
}

cleanup_known_hosts() {
  log "Removing stale SSH known_hosts entries for inventory hosts"

  inventory_ips | while read -r host; do
    [[ -n "$host" ]] || continue
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$host" >/dev/null 2>&1 || true
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$host]:22" >/dev/null 2>&1 || true
  done
}

write_ansible_ssh_defaults() {
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o ConnectTimeout=15"
}

raw_ssh_check() {
  log "Checking raw SSH reachability for each inventory host"

  inventory_hosts | while read -r host ip; do
    log "checking SSH: ${host} (${ip})"

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$ip]:22" >/dev/null 2>&1 || true

    ssh \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
      -o ConnectTimeout=15 \
      -i "$SSH_KEY" \
      "${SSH_USER}@${ip}" \
      'hostname; cloud-init status --long 2>/dev/null || true' >/dev/null ||
      fatal "SSH failed for ${host} (${ip}). Check VM power, IP, key, and inventory before continuing."

    ok "SSH reachable: ${host} (${ip})"
  done
}

ensure_ansible_installed() {
  if ! command -v ansible >/dev/null 2>&1; then
    log "Installing Ansible on runner host..."
    sudo apt-get update
    sudo apt-get install -y ansible
  fi
}

detect_host_bridge_ip() {
  local ip=""

  if [[ -n "${HOST_IP_CIDR:-}" ]]; then
    ip="${HOST_IP_CIDR%%/*}"
  fi

  if [[ -z "$ip" && -n "$BRIDGE_NAME" ]]; then
    ip="$(ip -o -4 addr show dev "$BRIDGE_NAME" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1 || true)"
  fi

  if [[ -z "$ip" ]]; then
    ip="$(ip route get "$(inventory_ips | head -1)" 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
  fi

  [[ -n "$ip" ]] || fatal "Could not detect host bridge IP for VM DNS forwarding"
  printf '%s\n' "$ip"
}

host_dns_servers() {
  {
    # Prefer the host's real upstream resolver list. Avoid /etc/resolv.conf first,
    # because on systemd-resolved hosts it is commonly only 127.0.0.53.
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns 2>/dev/null | awk '
        {
          for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $i ~ /:/) print $i
          }
        }'
    fi

    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f IP4.DNS dev show 2>/dev/null | awk -F: '/IP4.DNS/ {print $2}'
    fi

    awk '/^nameserver / {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null || true
    awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null || true
  } | awk '
    $1 == "" { next }
    $1 ~ /^127\./ { next }
    $1 == "::1" { next }
    $1 ~ /^169\.254\./ { next }
    !seen[$1]++ { print $1 }
  '
}

configure_host_dns_forwarder() {
  local host_ip
  local dns_servers
  local config="/etc/dnsmasq.d/otp-relay-cluster-vm-dns.conf"

  host_ip="$(detect_host_bridge_ip)"
  dns_servers="$(host_dns_servers | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  [[ -n "$dns_servers" ]] || fatal "Could not detect non-loopback DNS servers from host"

  log "Configuring host DNS forwarder for VMs"
  log "Host VM DNS listen address: ${host_ip}"
  log "Host upstream DNS servers: ${dns_servers}"

  if ! command -v dnsmasq >/dev/null 2>&1; then
    log "Installing dnsmasq on host..."
    sudo apt-get update
    sudo apt-get install -y dnsmasq
  fi

  {
    echo "# Managed by k8s-ansible automation/ansible/run-cluster.sh"
    echo "interface=${BRIDGE_NAME}"
    echo "listen-address=${host_ip}"
    echo "bind-interfaces"
    echo "domain-needed"
    echo "bogus-priv"
    echo "cache-size=1000"
    for server in $dns_servers; do
      echo "server=${server}"
    done
  } | sudo tee "$config" >/dev/null

  sudo systemctl restart dnsmasq
  sudo systemctl enable dnsmasq >/dev/null 2>&1 || true

  if command -v dig >/dev/null 2>&1; then
    dig @"$host_ip" deb.debian.org +time=3 +tries=1 >/dev/null ||
      fatal "Host dnsmasq is not resolving deb.debian.org on ${host_ip}"
  else
    timeout 5 getent hosts deb.debian.org >/dev/null ||
      warn "Host can not validate deb.debian.org with getent; VM validation will be authoritative"
  fi

  VM_DNS_SERVER="$host_ip"
  export VM_DNS_SERVER
}

repair_and_validate_vm_dns() {
  local host_ip="${VM_DNS_SERVER:?VM_DNS_SERVER is not set}"

  log "Repairing and validating DNS on all cluster VMs..."
  log "VM DNS server: ${host_ip} (host bridge DNS forwarder)"

  ansible -i "$INVENTORY" all -b -m shell -a "
set -eux

cat >/etc/resolv.conf <<EOF
nameserver ${host_ip}
options timeout:2 attempts:2
EOF

cat /etc/resolv.conf
ip route
timeout 10 getent hosts deb.debian.org
"
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
echo '===== apt term.log ====='
tail -${limit} /var/log/apt/term.log 2>/dev/null || true
echo '===== apt/dpkg/cloud-init processes ====='
ps aux | grep -E 'apt|dpkg|cloud-init|unattended' | grep -v grep || true
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
    tail -200 /var/log/cloud-init-output.log 2>/dev/null || true
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
  log "This can take several minutes on first boot; apt has 30s network timeouts and 2 retries."

  ansible -i "$INVENTORY" all -b -m shell -a '
set -eux

export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a || true

apt-get \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o Acquire::Retries=2 \
  update

apt-get \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o Acquire::Retries=2 \
  install -f -y

apt-get \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o Acquire::Retries=2 \
  install -y \
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

run_playbook_if_present() {
  local label="$1"
  local playbook="$2"

  if [[ ! -f "$playbook" ]]; then
    warn "Skipping missing playbook: $playbook"
    return 0
  fi

  log "$label"
  ansible-playbook -i "$INVENTORY" "$playbook"
}

cleanup_known_hosts_for_inventory_after_dns() {
  cleanup_known_hosts
}

main() {
  ensure_ansible_installed
  fix_local_ssh_permissions
  cleanup_known_hosts
  write_ansible_ssh_defaults

  raw_ssh_check

  log "Waiting for Ansible SSH connection on all cluster VMs..."
  ansible -i "$INVENTORY" all -m wait_for_connection -a "timeout=180 sleep=5"

  wait_for_cloud_init_and_locks
  configure_host_dns_forwarder
  repair_and_validate_vm_dns
  repair_apt_if_needed

  log "Running Ansible ping..."
  ansible -i "$INVENTORY" all -m ping

  run_playbook_if_present "Running OS baseline..." "playbooks/00-os-baseline.yml"
  run_playbook_if_present "Installing K3s control-plane..." "playbooks/10-k3s-control-plane.yml"
  run_playbook_if_present "Installing K3s workers..." "playbooks/20-k3s-workers.yml"
  run_playbook_if_present "Applying node labels..." "playbooks/30-node-labels.yml"

  if [[ -n "${NFS_SERVER:-}" || -n "${NFS_EXPORT:-}" || -n "${STORAGE_SERVER_IP:-}" ]]; then
    run_playbook_if_present "Validating storage..." "playbooks/40-storage-validate.yml"
  else
    log "Skipping storage validation because no NFS/storage variables are configured"
  fi

  if [[ "${DEPLOY_OTP_RELAY:-0}" == "1" ]]; then
    run_playbook_if_present "Deploying OTP Relay..." "playbooks/50-deploy-otp-relay.yml"
  fi

  if [[ "${VALIDATE_OTP_RELAY:-0}" == "1" ]]; then
    run_playbook_if_present "Validating production state..." "playbooks/70-validate-production.yml"
  fi

  ok "Cluster automation completed."
}

main "$@"
