#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ANSIBLE_DIR}/../.." && pwd)"
INVENTORY="${INVENTORY:-${ANSIBLE_DIR}/inventory.generated.ini}"
ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-${ANSIBLE_DIR}/ansible.cfg}"
export ANSIBLE_CONFIG

DEPLOY_OTP_RELAY="${DEPLOY_OTP_RELAY:-1}"
VALIDATE_OTP_RELAY="${VALIDATE_OTP_RELAY:-0}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

cd "$ANSIBLE_DIR"

[[ -f "$INVENTORY" ]] || fatal "Missing inventory: $INVENTORY. Run automation/libvirt/provision-vms.sh first."

if [[ -f "${REPO_ROOT}/.env" ]]; then
  log "Loading environment from ${REPO_ROOT}/.env"
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
else
  warn "No ${REPO_ROOT}/.env found; continuing with exported/default variables only"
fi

SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-cluster}"
SSH_USER="${VM_USER:-otp-relay}"
BRIDGE_NAME="${BRIDGE_NAME:-br0}"
PREFIX="${PREFIX:-24}"

resolve_iptables_bin() {
  if command -v iptables >/dev/null 2>&1; then
    command -v iptables
    return 0
  fi

  for candidate in /usr/sbin/iptables /sbin/iptables /usr/bin/iptables /bin/iptables; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

resolve_dnsmasq_bin() {
  if command -v dnsmasq >/dev/null 2>&1; then
    command -v dnsmasq
    return 0
  fi

  for candidate in /usr/sbin/dnsmasq /sbin/dnsmasq /usr/bin/dnsmasq /bin/dnsmasq; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_server_networking_helpers() {
  local missing=0

  if ! resolve_iptables_bin >/dev/null 2>&1; then
    missing=1
  fi

  if ! resolve_dnsmasq_bin >/dev/null 2>&1; then
    missing=1
  fi

  if ! command -v dig >/dev/null 2>&1; then
    missing=1
  fi

  if [[ "$missing" = "1" ]]; then
    log "Installing missing server networking helpers: iptables dnsmasq dnsutils"
    sudo apt-get update
    sudo apt-get install -y iptables dnsmasq dnsutils
  fi

  resolve_iptables_bin >/dev/null 2>&1 || fatal "iptables binary was not found after installation. Checked PATH, /usr/sbin, /sbin, /usr/bin, and /bin."
  resolve_dnsmasq_bin >/dev/null 2>&1 || fatal "dnsmasq binary was not found after installation. Checked PATH, /usr/sbin, /sbin, /usr/bin, and /bin."
}

fix_local_ssh_permissions() {
  local real_user="${SUDO_USER:-${USER:-$(id -un)}}"
  local real_group
  local real_home
  local ssh_dir
  local known_hosts

  real_group="$(id -gn "$real_user" 2>/dev/null || printf '%s' "$real_user")"
  real_home="$(getent passwd "$real_user" | cut -d: -f6)"
  ssh_dir="$real_home/.ssh"
  known_hosts="$ssh_dir/known_hosts"

  log "Ensuring local SSH directory/key permissions are safe for ${real_user}"

  sudo mkdir -p "$ssh_dir"
  sudo chmod 700 "$ssh_dir" || true
  sudo chown "$real_user:$real_group" "$ssh_dir" 2>/dev/null || sudo chown "$real_user" "$ssh_dir" 2>/dev/null || true

  sudo touch "$known_hosts"
  sudo chmod 644 "$known_hosts" || true
  sudo chown "$real_user:$real_group" "$known_hosts" 2>/dev/null || sudo chown "$real_user" "$known_hosts" 2>/dev/null || true

  if [[ -f "$SSH_KEY" ]]; then
    sudo chown "$real_user:$real_group" "$SSH_KEY" 2>/dev/null || sudo chown "$real_user" "$SSH_KEY" 2>/dev/null || true
    sudo chmod 600 "$SSH_KEY" || true
  fi

  if [[ -f "${SSH_KEY}.pub" ]]; then
    sudo chown "$real_user:$real_group" "${SSH_KEY}.pub" 2>/dev/null || sudo chown "$real_user" "${SSH_KEY}.pub" 2>/dev/null || true
    sudo chmod 644 "${SSH_KEY}.pub" || true
  fi

  [[ ! -f "$SSH_KEY" || -r "$SSH_KEY" ]] || fatal "SSH key exists but is not readable by ${real_user}: $SSH_KEY"
}

worker_inventory_hosts() {
  awk '
    BEGIN { in_workers=0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^\[/ {
      in_workers = ($0 == "[workers]")
      next
    }
    in_workers {
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

worker_inventory_ips() {
  worker_inventory_hosts | awk '{print $2}' | sort -u
}

have_workers() {
  worker_inventory_hosts | grep -q .
}

cleanup_known_hosts() {
  log "Removing stale SSH known_hosts entries for worker VMs"

  if ! have_workers; then
    warn "No workers found in inventory; skipping known_hosts cleanup"
    return 0
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" || true
  touch "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts" || true

  worker_inventory_ips | while read -r host; do
    [[ -n "$host" ]] || continue
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$host" >/dev/null 2>&1 || true
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$host]:22" >/dev/null 2>&1 || true
  done

  ok "known_hosts cleanup completed"
}

write_ansible_ssh_defaults() {
  log "Configuring Ansible SSH defaults"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o ConnectTimeout=15"
  log "Using ANSIBLE_CONFIG=$ANSIBLE_CONFIG"
}

raw_ssh_check_workers() {
  log "Checking raw SSH reachability for worker VMs"

  if ! have_workers; then
    fatal "No [workers] entries found in inventory. Provision worker VMs first."
  fi

  fix_local_ssh_permissions
  [[ -f "$SSH_KEY" ]] || fatal "Missing SSH key: $SSH_KEY"

  worker_inventory_hosts | while read -r host ip; do
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
      fatal "SSH failed for worker ${host} (${ip}). Check VM power, IP, key, and inventory before continuing."

    ok "SSH reachable: ${host} (${ip})"
  done
}

ensure_ansible_installed() {
  if ! command -v ansible >/dev/null 2>&1; then
    log "Installing Ansible on server/control-plane; this may take a few minutes"
    sudo apt-get update
    sudo apt-get install -y ansible iptables dnsmasq dnsutils
    ok "Ansible installed"
  else
    log "Ansible already installed: $(command -v ansible)"
  fi

  ensure_server_networking_helpers
}

ensure_ansible_collections_installed() {
  local requirements_file="${REPO_ROOT}/collections/requirements.yml"

  [[ -f "$requirements_file" ]] ||
    fatal "Missing Ansible collection requirements file: $requirements_file"

  command -v ansible-galaxy >/dev/null 2>&1 ||
    fatal "ansible-galaxy is required but was not found after Ansible installation"

  log "Installing Ansible collection dependencies from ${requirements_file}"
  ansible-galaxy collection install -r "$requirements_file"
  ok "Ansible collection dependencies are installed"
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
    ip="$(ip route get "$(worker_inventory_ips | head -1)" 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
  fi

  [[ -n "$ip" ]] || fatal "Could not detect host bridge IP for VM DNS forwarding"
  printf '%s\n' "$ip"
}

detect_host_uplink_iface() {
  local iface=""

  iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"

  if [[ -z "$iface" ]]; then
    iface="$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
  fi

  [[ -n "$iface" ]] || fatal "Could not detect host uplink/default interface"
  printf '%s\n' "$iface"
}

host_dns_servers() {
  {
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

ensure_ipv4_forwarding() {
  log "Ensuring server IPv4 forwarding is enabled"

  if [[ -w /proc/sys/net/ipv4/ip_forward ]]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
  else
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
  fi

  sudo mkdir -p /etc/sysctl.d
  echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-otp-relay-cluster-forwarding.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-otp-relay-cluster-forwarding.conf >/dev/null 2>&1 || true
}

ensure_vm_bridge_forwarding() {
  local bridge="${BRIDGE_NAME:-br0}"
  local uplink
  local vm_cidr
  local iptables_bin

  uplink="$(detect_host_uplink_iface)"
  vm_cidr="${IP_SCAN_PREFIX:-}"

  if [[ -n "$vm_cidr" ]]; then
    vm_cidr="${vm_cidr}.0/${PREFIX:-24}"
  elif [[ -n "${HOST_IP_CIDR:-}" ]]; then
    vm_cidr="${HOST_IP_CIDR%.*}.0/${HOST_IP_CIDR#*/}"
  else
    vm_cidr="$(ip -o -4 addr show dev "$bridge" 2>/dev/null | awk '{print $4; exit}' | awk -F. '{print $1"."$2"."$3".0/24"}')"
  fi

  [[ -n "$vm_cidr" ]] || fatal "Could not determine VM CIDR for forwarding/NAT"

  log "Ensuring server firewall allows worker VM bridge traffic"
  log "Bridge: ${bridge}"
  log "Uplink: ${uplink}"
  log "VM CIDR: ${vm_cidr}"

  ensure_ipv4_forwarding
  ensure_server_networking_helpers

  if ! iptables_bin="$(resolve_iptables_bin)"; then
    fatal "iptables binary was not found. Checked PATH, /usr/sbin/iptables, /sbin/iptables, /usr/bin/iptables, and /bin/iptables."
  fi

  log "Using iptables binary: ${iptables_bin}"

  sudo "$iptables_bin" -C FORWARD -i "$bridge" -j ACCEPT 2>/dev/null || \
    sudo "$iptables_bin" -I FORWARD 1 -i "$bridge" -j ACCEPT

  sudo "$iptables_bin" -C FORWARD -o "$bridge" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    sudo "$iptables_bin" -I FORWARD 1 -o "$bridge" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  sudo "$iptables_bin" -t nat -C POSTROUTING -s "$vm_cidr" -o "$uplink" -j MASQUERADE 2>/dev/null || \
    sudo "$iptables_bin" -t nat -A POSTROUTING -s "$vm_cidr" -o "$uplink" -j MASQUERADE

  ok "Worker VM bridge forwarding/NAT rules are present"
}

configure_host_dns_forwarder() {
  local host_ip
  local dns_servers
  local config="/etc/dnsmasq.d/otp-relay-cluster-vm-dns.conf"

  host_ip="$(detect_host_bridge_ip)"
  dns_servers="$(host_dns_servers | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  [[ -n "$dns_servers" ]] || fatal "Could not detect non-loopback DNS servers from host"

  log "Configuring server DNS forwarder for worker VMs"
  log "VM DNS listen address: ${host_ip}"
  log "Upstream DNS servers: ${dns_servers}"

  ensure_server_networking_helpers

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

  log "Restarting dnsmasq"
  sudo systemctl restart dnsmasq
  sudo systemctl enable dnsmasq >/dev/null 2>&1 || true

  if command -v dig >/dev/null 2>&1; then
    dig @"$host_ip" deb.debian.org +time=3 +tries=1 >/dev/null ||
      fatal "Host dnsmasq is not resolving deb.debian.org on ${host_ip}"
  else
    timeout 5 getent hosts deb.debian.org >/dev/null ||
      warn "Host cannot validate deb.debian.org with getent; VM validation will be authoritative"
  fi

  VM_DNS_SERVER="$host_ip"
  export VM_DNS_SERVER
  ok "Server DNS forwarder is ready for worker VMs"
}

repair_and_validate_worker_dns() {
  local host_ip="${VM_DNS_SERVER:?VM_DNS_SERVER is not set}"

  log "Repairing and validating DNS on worker VMs"
  log "Worker VM DNS server: ${host_ip} (server bridge DNS forwarder)"

  ansible -i "$INVENTORY" workers -b -m shell -a "
set -eux

cat >/etc/resolv.conf <<EOF
nameserver ${host_ip}
options timeout:2 attempts:2
EOF

cat /etc/resolv.conf
ip route
timeout 10 getent hosts deb.debian.org
"

  ok "Worker DNS repair/validation completed"
}

validate_worker_outbound_https() {
  local iptables_bin=""

  log "Validating outbound HTTPS from worker VMs"

  ansible -i "$INVENTORY" workers -b -m shell -a '
set -eux
hostname
ip route
getent ahostsv4 deb.debian.org
timeout 15 bash -c "cat < /dev/null > /dev/tcp/deb.debian.org/443"
' || {
    warn "Worker DNS resolves, but outbound HTTPS to deb.debian.org:443 failed"
    warn "Server forwarding/firewall/NAT rules are below for diagnostics"

    iptables_bin="$(resolve_iptables_bin || true)"
    if [[ -n "$iptables_bin" ]]; then
      sudo "$iptables_bin" -S FORWARD || true
      sudo "$iptables_bin" -t nat -S || true
    else
      warn "iptables binary not found for diagnostics"
    fi

    fatal "Worker outbound HTTPS failed; refusing to run apt until forwarding is fixed"
  }

  ok "Outbound HTTPS validation completed on worker VMs"
}

print_worker_cloud_init_diagnostics() {
  local limit="${1:-120}"

  ansible -i "$INVENTORY" workers -b -m shell -a "
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

wait_for_worker_cloud_init_and_locks() {
  log "Checking cloud-init status on worker VMs"
  log "cloud-init wait timeout: approximately 15 minutes"

  ansible -i "$INVENTORY" workers -b -m shell -a '
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
    warn "cloud-init failed or timed out on at least one worker VM"
    print_worker_cloud_init_diagnostics 200
    fatal "cloud-init did not complete successfully on worker VMs"
  }

  ok "cloud-init completed on worker VMs"

  log "Waiting for apt/dpkg locks on worker VMs"
  log "apt/dpkg lock wait timeout: approximately 15 minutes"

  ansible -i "$INVENTORY" workers -b -m shell -a '
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
    warn "apt/dpkg locks did not clear on at least one worker VM"
    print_worker_cloud_init_diagnostics 200
    fatal "apt/dpkg lock wait failed on worker VMs"
  }

  ok "apt/dpkg locks are clear on worker VMs"
}

repair_worker_apt_if_needed() {
  log "Repairing apt/dpkg state on worker VMs if needed"
  log "This can take several minutes on first boot; apt has 30s network timeouts and 2 retries"

  ansible -i "$INVENTORY" workers -b -m shell -a '
set -eux

export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a || true

apt-get \
  -o Acquire::ForceIPv4=true \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o Acquire::Retries=2 \
  update

apt-get \
  -o Acquire::ForceIPv4=true \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o Acquire::Retries=2 \
  install -f -y

apt-get \
  -o Acquire::ForceIPv4=true \
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

  ok "Worker apt/dpkg repair and required package install completed"
}

detect_k3s_server_url() {
  local host_ip=""

  if [[ -n "${K3S_SERVER_URL:-}" ]]; then
    printf '%s\n' "$K3S_SERVER_URL"
    return 0
  fi

  if [[ -n "${HOST_IP_CIDR:-}" ]]; then
    host_ip="${HOST_IP_CIDR%%/*}"
  fi

  if [[ -z "$host_ip" && -n "${BRIDGE_NAME:-}" ]]; then
    host_ip="$(ip -o -4 addr show dev "$BRIDGE_NAME" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1 || true)"
  fi

  if [[ -z "$host_ip" ]]; then
    host_ip="$(ip route get "$(worker_inventory_ips | head -1)" 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi

  [[ -n "$host_ip" ]] || fatal "Could not determine K3s server URL for worker join."

  printf 'https://%s:6443\n' "$host_ip"
}

read_k3s_node_token() {
  local token=""

  if [[ -n "${K3S_NODE_TOKEN:-}" ]]; then
    printf '%s\n' "$K3S_NODE_TOKEN"
    return 0
  fi

  if [[ -n "${K3S_TOKEN:-}" ]]; then
    printf '%s\n' "$K3S_TOKEN"
    return 0
  fi

  if sudo test -f /var/lib/rancher/k3s/server/node-token; then
    token="$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || true)"
  elif sudo test -f /var/lib/rancher/k3s/server/token; then
    token="$(sudo cat /var/lib/rancher/k3s/server/token 2>/dev/null || true)"
  fi

  if [[ -z "$token" ]]; then
    warn "K3s token file was not found/readable. Diagnostics:"
    sudo systemctl status k3s --no-pager || true
    sudo ls -la /var/lib/rancher/k3s/server 2>/dev/null || true
    fatal "K3s node token was not found/readable. Control-plane install may not have completed correctly."
  fi

  printf '%s\n' "$token"
}

run_playbook_if_present() {
  local label="$1"
  local playbook="$2"
  local k3s_server_url=""
  local k3s_node_token=""

  if [[ ! -f "$playbook" ]]; then
    warn "Skipping missing playbook: $playbook"
    return 0
  fi

  log "$label"

  case "$playbook" in
    playbooks/20-k3s-workers.yml)
      k3s_server_url="$(detect_k3s_server_url)"
      k3s_node_token="$(read_k3s_node_token)"

      log "Passing K3s worker join values to worker playbook"
      log "K3s server URL: ${k3s_server_url}"

      ansible-playbook -i "$INVENTORY" "$playbook" \
        -e "k3s_server_url=${k3s_server_url}" \
        -e "k3s_node_token=${k3s_node_token}" \
        -e "k3s_token=${k3s_node_token}"
      ;;
    *)
      ansible-playbook -i "$INVENTORY" "$playbook"
      ;;
  esac

  ok "$label completed"
}

main() {
  log "Starting cluster automation"
  log "Repository root: $REPO_ROOT"
  log "Ansible directory: $ANSIBLE_DIR"
  log "Inventory: $INVENTORY"
  log "SSH key: $SSH_KEY"
  log "Worker SSH user: $SSH_USER"
  log "Control-plane: localhost / this server"
  log "PATH: $PATH"

  ensure_ansible_installed
  ensure_ansible_collections_installed
  fix_local_ssh_permissions
  cleanup_known_hosts
  write_ansible_ssh_defaults

  raw_ssh_check_workers

  log "Waiting for Ansible connection to localhost control-plane"
  ansible -i "$INVENTORY" control_plane -m ping
  ok "Local control-plane Ansible connection is ready"

  log "Waiting for Ansible SSH connection on worker VMs"
  ansible -i "$INVENTORY" workers -m wait_for_connection -a "timeout=180 sleep=5"
  ok "Ansible SSH connection is ready on worker VMs"

  wait_for_worker_cloud_init_and_locks
  ensure_vm_bridge_forwarding
  configure_host_dns_forwarder
  repair_and_validate_worker_dns
  validate_worker_outbound_https
  repair_worker_apt_if_needed

  log "Running Ansible ping for K3s cluster hosts"
  ansible -i "$INVENTORY" k3s_cluster -m ping
  ok "Ansible ping completed for K3s cluster hosts"

  run_playbook_if_present "Running OS baseline" "playbooks/00-os-baseline.yml"
  run_playbook_if_present "Installing K3s control-plane on localhost/server" "playbooks/10-k3s-control-plane.yml"
  run_playbook_if_present "Installing K3s workers" "playbooks/20-k3s-workers.yml"
  run_playbook_if_present "Applying node labels" "playbooks/30-node-labels.yml"

  if [[ -n "${NFS_SERVER:-}" && -n "${NFS_PATH:-}" ]]; then
    run_playbook_if_present "Validating external NFS storage" "playbooks/40-storage-validate.yml"
  else
    log "Skipping storage validation because NFS_SERVER/NFS_PATH are not fully configured"
  fi

  if [[ "${DEPLOY_OTP_RELAY:-0}" == "1" ]]; then
    run_playbook_if_present "Deploying OTP Relay from localhost control-plane" "playbooks/50-deploy-otp-relay.yml"
  else
    log "DEPLOY_OTP_RELAY=${DEPLOY_OTP_RELAY:-0}; skipping OTP Relay deployment"
  fi

  if [[ "${VALIDATE_OTP_RELAY:-0}" == "1" ]]; then
    run_playbook_if_present "Validating production state" "playbooks/70-validate-production.yml"
  else
    log "VALIDATE_OTP_RELAY=${VALIDATE_OTP_RELAY:-0}; skipping production validation"
  fi

  ok "Cluster automation completed."
}

main "$@"
