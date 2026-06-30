#!/usr/bin/env bash
set -Eeuo pipefail

# OTP Relay worker VM provisioner
#
# New target design:
#   - The physical/server host is the K3s control-plane and Ansible runner.
#   - This provisioner creates only two Debian cloud-image worker VMs:
#       otp-devprod-worker1
#       otp-devprod-worker2
#   - NFS is external and is not provisioned here.
#
# Default behavior:
#   - Must be run as a normal user, not with sudo bash.
#   - Uses sudo internally only where required.
#   - Creates/uses SSH key: ~/.ssh/otp-relay-cluster
#   - Repairs SSH key ownership/permissions if earlier sudo/root runs broke them.
#   - Creates VM login user: otp-relay
#   - Auto-assigns free LAN IPs by scanning IP_SCAN_PREFIX/IP_SCAN_START/IP_SCAN_END
#   - Writes Ansible inventory: automation/ansible/inventory.generated.ini
#
# Generated inventory shape:
#   [control_plane]
#   localhost ansible_connection=local
#
#   [workers]
#   worker1 ansible_host=<worker1-ip>
#   worker2 ansible_host=<worker2-ip>

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISIONER_PATH="${REPO_ROOT}/automation/libvirt/$(basename "${BASH_SOURCE[0]}")"

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
fi

BRIDGE_NAME="${BRIDGE_NAME:-br0}"
HOST_IFACE="${HOST_IFACE:-}"
HOST_IP_CIDR="${HOST_IP_CIDR:-}"
HOST_IP="${HOST_IP_CIDR%%/*}"
GATEWAY="${GATEWAY:-}"
DNS="${DNS:-}"
PREFIX="${PREFIX:-24}"

VM_USER="${VM_USER:-otp-relay}"
VM_PASSWORD="${VM_PASSWORD:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-cluster}"
SSH_PUB_KEY="${SSH_KEY}.pub"

VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-$(basename "$BASE_IMAGE_URL")}"
BASE_IMAGE="${VM_IMAGE_DIR}/${BASE_IMAGE_NAME}"
OS_VARIANT="${OS_VARIANT:-debian12}"

ANSIBLE_INVENTORY="${REPO_ROOT}/automation/ansible/inventory.generated.ini"

WORKER1_NAME="${WORKER1_NAME:-otp-devprod-worker1}"
WORKER2_NAME="${WORKER2_NAME:-otp-devprod-worker2}"

AUTO_ASSIGN_IPS="${AUTO_ASSIGN_IPS:-1}"
IP_SCAN_PREFIX="${IP_SCAN_PREFIX:-}"
IP_SCAN_START="${IP_SCAN_START:-150}"
IP_SCAN_END="${IP_SCAN_END:-199}"
RESERVED_IPS="${RESERVED_IPS:-}"
AUTO_RECREATE_INCOMPATIBLE_VMS="${AUTO_RECREATE_INCOMPATIBLE_VMS:-1}"
EXISTING_VM_SSH_CHECK_ATTEMPTS="${EXISTING_VM_SSH_CHECK_ATTEMPTS:-6}"
EXISTING_VM_SSH_CHECK_SLEEP="${EXISTING_VM_SSH_CHECK_SLEEP:-5}"

WORKER1_IP="${WORKER1_IP:-}"
WORKER2_IP="${WORKER2_IP:-}"

VM_RAM_MB="${VM_RAM_MB:-3072}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GB="${VM_DISK_GB:-20}"

BUILD_DIR="${REPO_ROOT}/automation/libvirt/build"
SEED_IMAGE_DIR="${SEED_IMAGE_DIR:-${VM_IMAGE_DIR}}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing command: $1"
}

host_dns_servers() {
  {
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
    fi

    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f IP4.DNS dev show 2>/dev/null | awk -F: '$2 != "" {print $2}' || true
    fi

    awk '/^nameserver / {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null || true
    awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null || true
  } | awk '
    NF && $1 !~ /^127\./ && $1 != "::1" && $1 !~ /^169\.254\./ && !seen[$1]++ {print $1}
  '
}

DNS_SERVERS="${DNS_SERVERS:-$(host_dns_servers | paste -sd' ' -)}"
[ -n "$DNS_SERVERS" ] || fatal "Could not detect a non-loopback DNS server from the host. Fix host DNS or set DNS_SERVERS explicitly."
DNS="$(printf '%s\n' "$DNS_SERVERS" | awk '{print $1}')"

dns_resolv_conf_content() {
  local dns
  for dns in $DNS_SERVERS; do
    printf 'nameserver %s\n' "$dns"
  done
  printf 'options timeout:2 attempts:2 rotate\n'
}

dns_yaml_nameservers() {
  local dns
  for dns in $DNS_SERVERS; do
    printf '        - %s\n' "$dns"
  done
}

: "${HOST_IP_CIDR:?HOST_IP_CIDR must be set in .env or the shell environment}"
: "${GATEWAY:?GATEWAY must be set in .env or the shell environment}"
: "${DNS:?DNS must be set in .env or the shell environment}"
: "${IP_SCAN_PREFIX:?IP_SCAN_PREFIX must be set in .env or the shell environment}"
: "${VM_PASSWORD:?VM_PASSWORD must be set in .env or the shell environment}"
 
  if [[ "$VM_PASSWORD" == "otp-relay" || "$VM_PASSWORD" == "CHANGE_ME_VM_PASSWORD" ]]; then
    fatal "VM_PASSWORD must be changed from the default before provisioning worker VMs"
  fi

require_non_root() {
  if [[ "${EUID}" -eq 0 && "${ALLOW_ROOT_RUN:-0}" != "1" ]]; then
    fatal "Do not run this script with sudo. Run it as your normal user: ./automation/libvirt/provision-vms.sh"
  fi
}

require_sudo() {
  if ! sudo -n true >/dev/null 2>&1; then
    log "sudo access is required. You may be prompted for your password."
    sudo true
  fi
}

detect_iface() {
  if [[ -n "$HOST_IFACE" ]]; then
    echo "$HOST_IFACE"
    return 0
  fi

  ip route | awk '/^default / {print $5; exit}'
}

install_packages() {
  log "Installing host virtualization packages..."
  sudo apt-get update
  sudo apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    bridge-utils \
    cloud-image-utils \
    genisoimage \
    ovmf \
    curl \
    jq \
    openssh-client \
    iproute2 \
    iptables \
    net-tools \
    dnsutils
}

enable_libvirt() {
  log "Enabling libvirt..."
  sudo systemctl enable --now libvirtd

  if groups "$USER" | grep -qw libvirt && groups "$USER" | grep -qw kvm; then
    ok "User $USER is already in libvirt/kvm groups"
  else
    log "Adding $USER to libvirt,kvm groups..."
    sudo usermod -aG libvirt,kvm "$USER"
    warn "Group membership may require logout/login later. This script uses sudo virsh/virt-install where needed."
  fi
}

repair_ssh_key_permissions() {
  local ssh_dir operator_user operator_group known_hosts

  ssh_dir="$(dirname "$SSH_KEY")"
  known_hosts="${ssh_dir}/known_hosts"
  operator_user="$(id -un)"
  operator_group="$(id -gn)"

  log "repairing SSH key ownership/permissions for $operator_user"

  mkdir -p "$ssh_dir"

  sudo chown "$operator_user:$operator_group" "$ssh_dir" 2>/dev/null || true
  chmod 700 "$ssh_dir" || true

  if [[ -f "$SSH_KEY" ]]; then
    sudo chown "$operator_user:$operator_group" "$SSH_KEY" 2>/dev/null || true
    chmod 600 "$SSH_KEY" || fatal "failed to set private key permissions on $SSH_KEY"
  fi

  if [[ -f "$SSH_PUB_KEY" ]]; then
    sudo chown "$operator_user:$operator_group" "$SSH_PUB_KEY" 2>/dev/null || true
    chmod 644 "$SSH_PUB_KEY" || true
  fi

  if [[ -f "$known_hosts" ]]; then
    sudo chown "$operator_user:$operator_group" "$known_hosts" 2>/dev/null || true
    chmod 644 "$known_hosts" || true
  fi

  [[ -f "$SSH_KEY" ]] || fatal "SSH private key does not exist: $SSH_KEY"
  [[ -r "$SSH_KEY" ]] || fatal "SSH private key exists but is not readable by $operator_user: $SSH_KEY"
}

ensure_ssh_key() {
  local ssh_dir
  ssh_dir="$(dirname "$SSH_KEY")"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [[ ! -f "$SSH_KEY" ]]; then
    log "Creating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C "otp-relay-cluster" -N ""
  fi

  [[ -f "$SSH_PUB_KEY" ]] || fatal "Missing SSH public key: $SSH_PUB_KEY"

  repair_ssh_key_permissions
}

check_host() {
  local vmx_count
  vmx_count="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
  [[ "$vmx_count" -gt 0 ]] || fatal "CPU virtualization is not available"

  if ! grep -qE '^kvm ' /proc/modules; then
    sudo modprobe kvm || true
    sudo modprobe kvm_intel || sudo modprobe kvm_amd || true
  fi

  grep -qE '^kvm ' /proc/modules || fatal "KVM module is not loaded"

  ok "KVM available: $vmx_count CPU virtualization flags found"
}

wait_for_bridge_activation() {
  for _ in $(seq 1 30); do
    sudo ip link set "$BRIDGE_NAME" up >/dev/null 2>&1 || true

    if ip -br addr show "$BRIDGE_NAME" | grep -q "$HOST_IP"; then
      return 0
    fi

    sleep 2
  done

  warn "$BRIDGE_NAME did not show expected IP $HOST_IP quickly. Continuing with diagnostics."
  ip -br addr show "$BRIDGE_NAME" || true
}

ensure_bridge_networkmanager() {
  local iface="$1"
  local active_con

  need_cmd nmcli

  if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ok "Bridge already exists: $BRIDGE_NAME"
    return 0
  fi

  active_con="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')"
  [[ -n "$active_con" ]] || fatal "Could not find active NetworkManager connection for $iface"

  warn "Creating bridge $BRIDGE_NAME over $iface using NetworkManager."
  warn "Network may briefly disconnect. Current active connection: $active_con"

  sudo nmcli con add type bridge ifname "$BRIDGE_NAME" con-name "$BRIDGE_NAME"
  sudo nmcli con modify "$BRIDGE_NAME" \
    ipv4.method manual \
    ipv4.addresses "$HOST_IP_CIDR" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_SERVERS" \
    ipv6.method ignore

  sudo nmcli con add type ethernet ifname "$iface" master "$BRIDGE_NAME" con-name "${BRIDGE_NAME}-slave-${iface}"

  sudo nmcli con down "$active_con" || true
  sudo nmcli con up "$BRIDGE_NAME" || true
  sudo nmcli con up "${BRIDGE_NAME}-slave-${iface}" || true
  sudo nmcli con up "$BRIDGE_NAME" || true

  wait_for_bridge_activation
}

ensure_bridge_interfaces_file() {
  local iface="$1"

  if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ok "Bridge already exists: $BRIDGE_NAME"
    return 0
  fi

  [[ -f /etc/network/interfaces ]] || fatal "/etc/network/interfaces not found"

  warn "Creating bridge $BRIDGE_NAME over $iface using /etc/network/interfaces."
  warn "Network may briefly disconnect."

  sudo cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"

  sudo tee /etc/network/interfaces >/dev/null <<NETEOF
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet manual

auto ${BRIDGE_NAME}
iface ${BRIDGE_NAME} inet static
    address ${HOST_IP_CIDR}
    gateway ${GATEWAY}
    bridge_ports ${iface}
    bridge_stp off
    bridge_fd 0
    dns-nameservers ${DNS_SERVERS}
NETEOF

  sudo systemctl restart networking
  wait_for_bridge_activation
}

ensure_bridge() {
  local iface="$1"

  log "Checking bridge/network setup..."
  log "Host NIC: $iface"
  log "Target bridge: $BRIDGE_NAME"
  log "Host bridge IP: $HOST_IP_CIDR"

  if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ok "$BRIDGE_NAME already exists"
    sudo ip link set "$BRIDGE_NAME" up >/dev/null 2>&1 || true
  else
    if systemctl is-active --quiet NetworkManager; then
      ensure_bridge_networkmanager "$iface"
    elif [[ -f /etc/network/interfaces ]]; then
      ensure_bridge_interfaces_file "$iface"
    else
      fatal "No supported network manager detected. Need NetworkManager or /etc/network/interfaces."
    fi
  fi

  ip -br addr show "$BRIDGE_NAME" || fatal "$BRIDGE_NAME does not exist after setup"

  if ping -c 2 "$GATEWAY" >/dev/null 2>&1; then
    ok "Bridge network can reach gateway $GATEWAY"
  else
    warn "Bridge/gateway ping failed immediately after setup."
    warn "Continuing because NetworkManager bridges can take time to activate."
    warn "If VMs are unreachable later, inspect br0 and the bridge slave connection."
  fi

  ok "Bridge network check completed"
}

ip_is_reserved() {
  local ip="$1"
  local reserved

  for reserved in $HOST_IP "$GATEWAY" $RESERVED_IPS; do
    [[ -n "$reserved" && "$ip" == "$reserved" ]] && return 0
  done

  return 1
}

ip_is_in_use() {
  local ip="$1"

  ip_is_reserved "$ip" && return 0

  if ip -4 addr show | grep -qw "$ip"; then
    return 0
  fi

  if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    return 0
  fi

  if ip neigh show "$ip" 2>/dev/null | grep -qE 'lladdr|REACHABLE|STALE|DELAY|PROBE'; then
    return 0
  fi

  return 1
}

next_free_ip() {
  local start="$1"
  local end="$2"
  local i
  local ip

  for i in $(seq "$start" "$end"); do
    ip="${IP_SCAN_PREFIX}.${i}"

    if ! ip_is_in_use "$ip"; then
      echo "$ip"
      return 0
    fi
  done

  fatal "No free IP found in ${IP_SCAN_PREFIX}.${start}-${IP_SCAN_PREFIX}.${end}"
}

validate_fixed_ips() {
  [[ -n "$WORKER1_IP" ]] || fatal "WORKER1_IP is empty"
  [[ -n "$WORKER2_IP" ]] || fatal "WORKER2_IP is empty"

  [[ "$WORKER1_IP" != "$WORKER2_IP" ]] || fatal "WORKER1_IP and WORKER2_IP are identical"
}

assign_vm_ips() {
  if [[ "$AUTO_ASSIGN_IPS" == "0" ]]; then
    log "Using pre-assigned worker VM IPs"
    [[ -n "$WORKER1_IP" ]] || fatal "AUTO_ASSIGN_IPS=0 requires WORKER1_IP"
    [[ -n "$WORKER2_IP" ]] || fatal "AUTO_ASSIGN_IPS=0 requires WORKER2_IP"
    validate_fixed_ips
  else
    log "Auto-assigning worker VM IPs from ${IP_SCAN_PREFIX}.${IP_SCAN_START}-${IP_SCAN_PREFIX}.${IP_SCAN_END}"

    WORKER1_IP="${WORKER1_IP:-$(next_free_ip "$IP_SCAN_START" "$IP_SCAN_END")}"
    RESERVED_IPS="${RESERVED_IPS} ${WORKER1_IP}"

    WORKER2_IP="${WORKER2_IP:-$(next_free_ip "$IP_SCAN_START" "$IP_SCAN_END")}"
    RESERVED_IPS="${RESERVED_IPS} ${WORKER2_IP}"

    validate_fixed_ips
  fi

  cat <<IPINFO

[INFO] Worker VM IP assignment:
  ${WORKER1_NAME}:  ${WORKER1_IP}
  ${WORKER2_NAME}:  ${WORKER2_IP}

[INFO] Control-plane:
  localhost / this server

IPINFO
}

is_qcow2_image() {
  local image="$1"

  [[ -f "$image" ]] || return 1
  sudo qemu-img info --output=json "$image" 2>/dev/null | grep -q '"format"[[:space:]]*:[[:space:]]*"qcow2"'
}

validate_qcow2_or_remove() {
  local image="$1"
  local label="$2"

  if [[ ! -f "$image" ]]; then
    return 1
  fi

  if is_qcow2_image "$image"; then
    return 0
  fi

  warn "$label exists but is not a valid qcow2 image; removing: $image"
  sudo rm -f "$image"
  return 1
}

download_base_image() {
  local tmp_image="${BASE_IMAGE}.tmp.$$"

  sudo mkdir -p "$VM_IMAGE_DIR"

  if validate_qcow2_or_remove "$BASE_IMAGE" "Base image"; then
    ok "Base image already exists and is valid qcow2: $BASE_IMAGE"
    return 0
  fi

  log "Downloading Debian cloud image..."
  log "Base image URL: $BASE_IMAGE_URL"

  sudo rm -f "$tmp_image"
  sudo curl -fL --retry 3 --retry-delay 3 "$BASE_IMAGE_URL" -o "$tmp_image"

  if ! is_qcow2_image "$tmp_image"; then
    sudo rm -f "$tmp_image"
    fatal "Downloaded base image is not qcow2. Check BASE_IMAGE_URL: $BASE_IMAGE_URL"
  fi

  sudo mv "$tmp_image" "$BASE_IMAGE"
  ok "Downloaded base image: $BASE_IMAGE"
}

ssh_ready_for_expected_identity() {
  local ip="$1"

  repair_ssh_key_permissions

  ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 \
    -i "$SSH_KEY" \
    "${VM_USER}@${ip}" "hostname" >/dev/null 2>&1
}

existing_vm_matches_expected_identity() {
  local name="$1"
  local ip="$2"
  local attempt

  log "Checking existing VM compatibility: $name ($ip) as ${VM_USER}"

  repair_ssh_key_permissions

  for attempt in $(seq 1 "$EXISTING_VM_SSH_CHECK_ATTEMPTS"); do
    if ssh_ready_for_expected_identity "$ip"; then
      ok "Existing VM is compatible: $name ($ip)"
      return 0
    fi

    sleep "$EXISTING_VM_SSH_CHECK_SLEEP"
  done

  warn "Existing VM is not reachable with expected identity: $name ($ip), user=${VM_USER}, key=${SSH_KEY}"
  return 1
}

remove_existing_vm() {
  local name="$1"
  local disk="${VM_IMAGE_DIR}/${name}.qcow2"
  local seed="${SEED_IMAGE_DIR}/${name}-seed.iso"
  local nvram="/var/lib/libvirt/qemu/nvram/${name}_VARS.fd"

  warn "Removing existing VM: $name"

  if sudo virsh dominfo "$name" >/dev/null 2>&1; then
    sudo virsh destroy "$name" >/dev/null 2>&1 || true

    sudo virsh undefine "$name" \
      --nvram \
      --managed-save \
      --snapshots-metadata \
      >/dev/null 2>&1 || true

    sudo virsh undefine "$name" \
      --remove-all-storage \
      --nvram \
      --managed-save \
      --snapshots-metadata \
      >/dev/null 2>&1 || true
  fi

  if sudo virsh dominfo "$name" >/dev/null 2>&1; then
    warn "libvirt domain still exists after removal attempt: $name"
    sudo virsh dumpxml "$name" | grep -E 'source file|nvram|loader|name' || true
    fatal "refusing to recreate disk while libvirt domain still exists: $name"
  fi

  sudo rm -f "$disk" "$seed" "$nvram" 2>/dev/null || true

  if sudo virsh list --all --name 2>/dev/null | grep -qx "$name"; then
    fatal "libvirt domain still registered after cleanup: $name"
  fi
}

prepare_vm_slot() {
  local name="$1"
  local ip="$2"

  if sudo virsh dominfo "$name" >/dev/null 2>&1; then
    if [[ "${RECREATE_VMS:-0}" == "1" ]]; then
      warn "RECREATE_VMS=1 set; recreating VM: $name"
      remove_existing_vm "$name"
      echo "new"
      return 0
    fi

    if existing_vm_matches_expected_identity "$name" "$ip"; then
      echo "exists"
      return 0
    fi

    if [[ "$AUTO_RECREATE_INCOMPATIBLE_VMS" == "1" ]]; then
      warn "AUTO_RECREATE_INCOMPATIBLE_VMS=1; old/incompatible VM will be replaced: $name"
      remove_existing_vm "$name"
      echo "new"
      return 0
    fi

    fatal "Existing VM $name is incompatible. Set RECREATE_VMS=1 or AUTO_RECREATE_INCOMPATIBLE_VMS=1 to replace it."
  fi

  echo "new"
}

deterministic_vm_mac() {
  local name="$1"
  local ip="$2"
  local hex

  hex="$(printf '%s' "${name}-${ip}" | sha256sum | awk '{print $1}')"
  printf '52:54:%s:%s:%s:%s' "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}"
}

prepare_seed_iso_for_libvirt() {
  local seed="$1"

  sudo mkdir -p "$SEED_IMAGE_DIR"
  sudo chown root:libvirt-qemu "$SEED_IMAGE_DIR" 2>/dev/null || sudo chown root:qemu "$SEED_IMAGE_DIR" 2>/dev/null || true
  sudo chmod 0755 "$SEED_IMAGE_DIR" || true

  sudo chown root:libvirt-qemu "$seed" 2>/dev/null || sudo chown root:qemu "$seed" 2>/dev/null || sudo chown root:root "$seed" || true
  sudo chmod 0644 "$seed" || true

  if sudo -u libvirt-qemu test -r "$seed" 2>/dev/null; then
    return 0
  fi

  if sudo -u qemu test -r "$seed" 2>/dev/null; then
    return 0
  fi

  test -r "$seed" || fatal "seed ISO is not readable: $seed"
}

create_vm() {
  local name="$1"
  local ip="$2"

  local state
  state="$(prepare_vm_slot "$name" "$ip")"

  if [[ "$state" == "exists" ]]; then
    ok "VM already exists: $name"
    return 0
  fi

  local disk="${VM_IMAGE_DIR}/${name}.qcow2"
  local seed="${SEED_IMAGE_DIR}/${name}-seed.iso"
  local user_data="${BUILD_DIR}/${name}-user-data"
  local meta_data="${BUILD_DIR}/${name}-meta-data"
  local network_config="${BUILD_DIR}/${name}-network-config"
  local mac

  mac="$(deterministic_vm_mac "$name" "$ip")"

  log "Creating VM: $name at $ip"

  mkdir -p "$BUILD_DIR"
  sudo mkdir -p "$SEED_IMAGE_DIR"
  rm -f "$user_data" "$meta_data" "$network_config"
  sudo rm -f "$seed"

  repair_ssh_key_permissions

  if sudo virsh list --all --name 2>/dev/null | grep -qx "$name"; then
    fatal "refusing to create disk while libvirt domain still exists: $name"
  fi

  validate_qcow2_or_remove "$disk" "Existing VM disk" || true
  sudo rm -f "$disk"

  validate_qcow2_or_remove "$BASE_IMAGE" "Base image" || fatal "Base image is missing or invalid after download step: $BASE_IMAGE"
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "${VM_DISK_GB}G"
  validate_qcow2_or_remove "$disk" "New VM disk" || fatal "Failed to create valid qcow2 disk: $disk"

  local DNS_RESOLV_ESCAPED
  DNS_RESOLV_ESCAPED="$(dns_resolv_conf_content | sed ':a;N;$!ba;s/\n/\\n/g')"

  cat > "$user_data" <<CLOUDUSER
#cloud-config
hostname: ${name}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    gecos: OTP Relay Cluster User
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    plain_text_passwd: "${VM_PASSWORD}"
    ssh_authorized_keys:
      - $(cat "$SSH_PUB_KEY")

ssh_pwauth: true
disable_root: true
package_update: false
package_upgrade: false

bootcmd:
  - [ sh, -c, "systemctl enable serial-getty@ttyS0.service || true" ]

runcmd:
  - [ sh, -c, "mkdir -p /etc/systemd/resolved.conf.d" ]
  - [ sh, -c, "printf '[Resolve]\nDNS=${DNS_SERVERS}\nFallbackDNS=${DNS_SERVERS}\nDNSSEC=no\nDNSOverTLS=no\n' > /etc/systemd/resolved.conf.d/otp-relay-dns.conf" ]
  - [ sh, -c, "rm -f /etc/resolv.conf && printf '${DNS_RESOLV_ESCAPED}' > /etc/resolv.conf" ]
  - [ sh, -c, "systemctl restart systemd-resolved || true" ]
  - [ sh, -c, "rm -f /etc/resolv.conf && printf '${DNS_RESOLV_ESCAPED}' > /etc/resolv.conf" ]
  - [ sh, -c, "systemctl enable --now ssh || systemctl enable --now sshd || true" ]
CLOUDUSER

  cat > "$meta_data" <<CLOUDMETA
instance-id: ${name}
local-hostname: ${name}
CLOUDMETA

  cat > "$network_config" <<CLOUDNET
version: 2
ethernets:
  eth0:
    match:
      macaddress: "${mac}"
    set-name: eth0
    dhcp4: false
    addresses:
      - ${ip}/${PREFIX}
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses:
$(dns_yaml_nameservers)
CLOUDNET

  local seed_tmp="${BUILD_DIR}/${name}-seed.iso"
  rm -f "$seed_tmp"
  cloud-localds --network-config="$network_config" "$seed_tmp" "$user_data" "$meta_data"
  sudo install -m 0644 "$seed_tmp" "$seed"
  prepare_seed_iso_for_libvirt "$seed"

  sudo virt-install \
    --name "$name" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --disk path="$disk",format=qcow2,bus=virtio \
    --disk path="$seed",device=cdrom,readonly=on \
    --os-variant "$OS_VARIANT" \
    --virt-type kvm \
    --machine q35 \
    --boot uefi \
    --graphics none \
    --serial pty \
    --console pty,target_type=serial \
    --noautoconsole \
    --import \
    --network bridge="$BRIDGE_NAME",model=virtio,mac="$mac"

  ok "Created VM: $name"
}

wait_for_ssh() {
  local ip="$1"
  local name="$2"
  local elapsed=0

  log "Waiting for SSH on $name ($ip)..."

  repair_ssh_key_permissions

  for _ in $(seq 1 90); do
    if ssh_ready_for_expected_identity "$ip"; then
      ok "SSH ready: $name ($ip)"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))

    if [ $((elapsed % 30)) -eq 0 ]; then
      log "Still waiting for SSH on $name ($ip), elapsed ${elapsed}s"
    fi
  done

  warn "SSH did not become ready for $name ($ip) within timeout."
  warn "VM may still be booting/cloud-init may still be running."
  warn "Try manually: ssh -i ${SSH_KEY} ${VM_USER}@${ip}"
  return 1
}

repair_guest_dns_and_validate() {
  local ip="$1"
  local name="$2"
  local attempt

  log "Repairing and validating DNS inside $name ($ip)..."
  log "Host DNS servers for $name: ${DNS_SERVERS}"

  repair_ssh_key_permissions

  for attempt in $(seq 1 12); do
    if ssh \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -i "$SSH_KEY" \
      "${VM_USER}@${ip}" \
      "sudo sh -s" <<DNS_REMOTE >/dev/null 2>&1
set -eu
dns_servers='${DNS_SERVERS}'
rm -f /etc/resolv.conf
: >/etc/resolv.conf
for dns in \$dns_servers; do
  case "\$dns" in
    ''|127.*|::1|169.254.*) continue ;;
  esac
  printf 'nameserver %s\n' "\$dns" >>/etc/resolv.conf
done
printf 'options timeout:2 attempts:2 rotate\n' >>/etc/resolv.conf
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/otp-relay-dns.conf <<EOF_RESOLVED
[Resolve]
DNS=${DNS_SERVERS}
FallbackDNS=${DNS_SERVERS}
DNSSEC=no
DNSOverTLS=no
EOF_RESOLVED
systemctl restart systemd-resolved >/dev/null 2>&1 || true
rm -f /etc/resolv.conf
: >/etc/resolv.conf
for dns in \$dns_servers; do
  case "\$dns" in
    ''|127.*|::1|169.254.*) continue ;;
  esac
  printf 'nameserver %s\n' "\$dns" >>/etc/resolv.conf
done
printf 'options timeout:2 attempts:2 rotate\n' >>/etc/resolv.conf
timeout 10 getent hosts deb.debian.org >/dev/null
DNS_REMOTE
    then
      ok "DNS validated: $name ($ip) can resolve deb.debian.org"
      return 0
    fi

    sleep 5
  done

  warn "DNS validation failed for $name ($ip). Diagnostics:"
  repair_ssh_key_permissions
  ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -i "$SSH_KEY" \
    "${VM_USER}@${ip}" \
    "hostname; ip route; cat /etc/resolv.conf || true; resolvectl status 2>/dev/null || true; getent hosts deb.debian.org || true" || true

  fatal "VM DNS is not working on $name ($ip); refusing to write inventory"
}

write_ansible_inventory() {
  mkdir -p "$(dirname "$ANSIBLE_INVENTORY")"

  repair_ssh_key_permissions

  cat > "$ANSIBLE_INVENTORY" <<INVEOF
[control_plane]
localhost ansible_connection=local

[workers]
worker1 ansible_host=${WORKER1_IP}
worker2 ansible_host=${WORKER2_IP}

[k3s_cluster:children]
control_plane
workers

[all:vars]
ansible_python_interpreter=/usr/bin/python3

[workers:vars]
ansible_user=${VM_USER}
ansible_become=true
ansible_ssh_private_key_file=${SSH_KEY}
INVEOF

  ok "Wrote Ansible inventory: $ANSIBLE_INVENTORY"
}

print_summary() {
  cat <<SUMMARY

[DONE] worker VM provisioning step finished.

Control-plane:
  Host:      this server / localhost
  Inventory: localhost ansible_connection=local

Worker VM access:
  User:      ${VM_USER}
  Password:  ${VM_PASSWORD}
  SSH key:   ${SSH_KEY}
  DNS:       ${DNS_SERVERS}

Worker VMs:
  Hostname: ${WORKER1_NAME}
  IP:       ${WORKER1_IP}
  SSH:      ssh -i ${SSH_KEY} ${VM_USER}@${WORKER1_IP}

  Hostname: ${WORKER2_NAME}
  IP:       ${WORKER2_IP}
  SSH:      ssh -i ${SSH_KEY} ${VM_USER}@${WORKER2_IP}

Inventory:
  ${ANSIBLE_INVENTORY}

Automation note:
  This provisioner now creates or repairs only the worker VM layer.
  The physical/server host remains the K3s control-plane.
  The workflow should continue with Ansible ping, OS baseline, K3s setup,
  storage validation, OTP Relay deployment, and final validation.

To force worker VM recreation later:
  RECREATE_VMS=1 VM_USER=${VM_USER} ${PROVISIONER_PATH}

SUMMARY
}

main() {
  cd "$REPO_ROOT"

  require_non_root
  require_sudo
  check_host
  install_packages
  enable_libvirt
  ensure_ssh_key
  repair_ssh_key_permissions

  log "Host DNS servers for worker VMs: ${DNS_SERVERS}"

  local iface
  iface="$(detect_iface)"
  [[ -n "$iface" ]] || fatal "Could not detect default network interface"

  ensure_bridge "$iface"
  assign_vm_ips

  mkdir -p "$BUILD_DIR"
  download_base_image

  repair_ssh_key_permissions
  create_vm "$WORKER1_NAME" "$WORKER1_IP"

  repair_ssh_key_permissions
  create_vm "$WORKER2_NAME" "$WORKER2_IP"

  repair_ssh_key_permissions
  wait_for_ssh "$WORKER1_IP" "$WORKER1_NAME"

  repair_ssh_key_permissions
  wait_for_ssh "$WORKER2_IP" "$WORKER2_NAME"

  repair_ssh_key_permissions
  repair_guest_dns_and_validate "$WORKER1_IP" "$WORKER1_NAME"

  repair_ssh_key_permissions
  repair_guest_dns_and_validate "$WORKER2_IP" "$WORKER2_NAME"

  write_ansible_inventory
  sudo virsh list --all

  print_summary
}

main "$@"
