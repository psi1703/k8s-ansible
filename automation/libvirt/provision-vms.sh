#!/usr/bin/env bash
set -Eeuo pipefail

# OTP Relay VM provisioner
#
# Creates three Debian 13 cloud-image VMs for the OTP Relay K3s-Ansible:
#   otp-master
#   otp-worker1
#   otp-worker2
#
# Default behavior:
#   - Must be run as a normal user, not with "sudo bash".
#   - Uses sudo internally only where required.
#   - Creates/uses SSH key: ~/.ssh/otp-relay-poc
#   - Creates VM login user: otp-relay
#   - Auto-assigns free LAN IPs by scanning the configured IP_SCAN_PREFIX/IP_SCAN_START/IP_SCAN_END range
#   - Writes Ansible inventory:
#       automation/ansible/inventory.generated.ini

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISIONER_PATH="${REPO_ROOT}/automation/libvirt/$(basename "${BASH_SOURCE[0]}")"

# Reuse the repository .env when present so VM provisioning can share the same
# operator-provided source file instead of carrying lab-specific values here.
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
VM_PASSWORD="${VM_PASSWORD:-otp-relay}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-poc}"
SSH_PUB_KEY="${SSH_KEY}.pub"

VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2}"
BASE_IMAGE="${VM_IMAGE_DIR}/debian-13-generic-amd64.qcow2"

ANSIBLE_INVENTORY="${REPO_ROOT}/automation/ansible/inventory.generated.ini"

CP_NAME="${CP_NAME:-otp-master}"
WORKER1_NAME="${WORKER1_NAME:-otp-worker1}"
WORKER2_NAME="${WORKER2_NAME:-otp-worker2}"

AUTO_ASSIGN_IPS="${AUTO_ASSIGN_IPS:-1}"
IP_SCAN_PREFIX="${IP_SCAN_PREFIX:-}"
IP_SCAN_START="${IP_SCAN_START:-150}"
IP_SCAN_END="${IP_SCAN_END:-199}"
RESERVED_IPS="${RESERVED_IPS:-}"
AUTO_RECREATE_INCOMPATIBLE_VMS="${AUTO_RECREATE_INCOMPATIBLE_VMS:-1}"
EXISTING_VM_SSH_CHECK_ATTEMPTS="${EXISTING_VM_SSH_CHECK_ATTEMPTS:-6}"
EXISTING_VM_SSH_CHECK_SLEEP="${EXISTING_VM_SSH_CHECK_SLEEP:-5}"

CP_IP="${CP_IP:-}"
WORKER1_IP="${WORKER1_IP:-}"
WORKER2_IP="${WORKER2_IP:-}"

VM_RAM_MB="${VM_RAM_MB:-3072}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GB="${VM_DISK_GB:-20}"

BUILD_DIR="${REPO_ROOT}/automation/libvirt/build"
# Cloud-init seed ISOs must live where the libvirt/qemu service user can read them.
# Files under /opt/k8s-ansible may be inaccessible to qemu because /opt or the repo
# can be mode 0750/root-owned after git/sudo operations.
SEED_IMAGE_DIR="${SEED_IMAGE_DIR:-${VM_IMAGE_DIR}}"

: "${HOST_IP_CIDR:?HOST_IP_CIDR must be set in .env or the shell environment}"
: "${GATEWAY:?GATEWAY must be set in .env or the shell environment}"
: "${DNS:?DNS must be set in .env or the shell environment}"
: "${IP_SCAN_PREFIX:?IP_SCAN_PREFIX must be set in .env or the shell environment}"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing command: $1"
}

require_non_root() {
  if [[ "${EUID}" -eq 0 && "${ALLOW_ROOT_RUN:-0}" != "1" ]]; then
    fatal "Do not run this script with sudo. Run it as your normal user: ./automation/libvirt/provision-poc-vms.sh"
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
  sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils cloud-image-utils genisoimage curl jq openssh-client iproute2 net-tools dnsutils
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

ensure_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY")"
  chmod 700 "$(dirname "$SSH_KEY")"

  if [[ ! -f "$SSH_KEY" ]]; then
    log "Creating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C "otp-relay-poc" -N ""
  fi

  [[ -f "$SSH_PUB_KEY" ]] || fatal "Missing SSH public key: $SSH_PUB_KEY"

  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_PUB_KEY"
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
  sudo nmcli con modify "$BRIDGE_NAME"     ipv4.method manual     ipv4.addresses "$HOST_IP_CIDR"     ipv4.gateway "$GATEWAY"     ipv4.dns "$DNS 8.8.8.8"     ipv6.method ignore

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
    dns-nameservers ${DNS} 8.8.8.8
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
  [[ -n "$CP_IP" ]] || fatal "CP_IP is empty"
  [[ -n "$WORKER1_IP" ]] || fatal "WORKER1_IP is empty"
  [[ -n "$WORKER2_IP" ]] || fatal "WORKER2_IP is empty"

  [[ "$CP_IP" != "$WORKER1_IP" ]] || fatal "CP_IP and WORKER1_IP are identical"
  [[ "$CP_IP" != "$WORKER2_IP" ]] || fatal "CP_IP and WORKER2_IP are identical"
  [[ "$WORKER1_IP" != "$WORKER2_IP" ]] || fatal "WORKER1_IP and WORKER2_IP are identical"
}

assign_vm_ips() {
  if [[ "$AUTO_ASSIGN_IPS" == "0" ]]; then
    log "Using pre-assigned VM IPs"
    [[ -n "$CP_IP" ]] || fatal "AUTO_ASSIGN_IPS=0 requires CP_IP"
    [[ -n "$WORKER1_IP" ]] || fatal "AUTO_ASSIGN_IPS=0 requires WORKER1_IP"
    [[ -n "$WORKER2_IP" ]] || fatal "AUTO_ASSIGN_IPS=0 requires WORKER2_IP"
    validate_fixed_ips
  else
    log "Auto-assigning VM IPs from ${IP_SCAN_PREFIX}.${IP_SCAN_START}-${IP_SCAN_PREFIX}.${IP_SCAN_END}"

    CP_IP="${CP_IP:-$(next_free_ip "$IP_SCAN_START" "$IP_SCAN_END")}"
    RESERVED_IPS="${RESERVED_IPS} ${CP_IP}"

    WORKER1_IP="${WORKER1_IP:-$(next_free_ip "$IP_SCAN_START" "$IP_SCAN_END")}"
    RESERVED_IPS="${RESERVED_IPS} ${WORKER1_IP}"

    WORKER2_IP="${WORKER2_IP:-$(next_free_ip "$IP_SCAN_START" "$IP_SCAN_END")}"
    RESERVED_IPS="${RESERVED_IPS} ${WORKER2_IP}"

    validate_fixed_ips
  fi

  cat <<IPINFO

[INFO] VM IP assignment:
  ${CP_NAME}:       ${CP_IP}
  ${WORKER1_NAME}:  ${WORKER1_IP}
  ${WORKER2_NAME}:  ${WORKER2_IP}

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

  log "Downloading Debian 13 cloud image..."
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

  warn "Removing existing VM: $name"
  sudo virsh destroy "$name" >/dev/null 2>&1 || true
  sudo virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || sudo virsh undefine "$name" >/dev/null 2>&1 || true
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

  # qemu must be able to traverse the directory and read the seed ISO.
  sudo chown root:libvirt-qemu "$seed" 2>/dev/null || sudo chown root:qemu "$seed" 2>/dev/null || sudo chown root:root "$seed" || true
  sudo chmod 0644 "$seed" || true

  if sudo -u libvirt-qemu test -r "$seed" 2>/dev/null; then
    return 0
  fi

  if sudo -u qemu test -r "$seed" 2>/dev/null; then
    return 0
  fi

  # Last-resort validation for distros where the qemu service user name differs.
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

  validate_qcow2_or_remove "$disk" "Existing VM disk" || true
  sudo rm -f "$disk"

  validate_qcow2_or_remove "$BASE_IMAGE" "Base image" || fatal "Base image is missing or invalid after download step: $BASE_IMAGE"
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "${VM_DISK_GB}G"
  validate_qcow2_or_remove "$disk" "New VM disk" || fatal "Failed to create valid qcow2 disk: $disk"

  cat > "$user_data" <<CLOUDUSER
#cloud-config
hostname: ${name}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    gecos: OTP Relay POC User
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    plain_text_passwd: "${VM_PASSWORD}"
    ssh_authorized_keys:
      - $(cat "$SSH_PUB_KEY")

ssh_pwauth: true
disable_root: true

package_update: true
packages:
  - openssh-server
  - sudo
  - curl
  - ca-certificates
  - gnupg
  - git
  - jq
  - python3
  - nfs-common

runcmd:
  - systemctl enable --now ssh
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
        - ${DNS}
        - 8.8.8.8
CLOUDNET

  local seed_tmp="${BUILD_DIR}/${name}-seed.iso"
  rm -f "$seed_tmp"
  cloud-localds --network-config="$network_config" "$seed_tmp" "$user_data" "$meta_data"
  sudo install -m 0644 "$seed_tmp" "$seed"
  prepare_seed_iso_for_libvirt "$seed"

  sudo virt-install --name "$name" --memory "$VM_RAM_MB" --vcpus "$VM_VCPUS" --disk path="$disk",format=qcow2,bus=virtio --disk path="$seed",device=cdrom,readonly=on --os-variant debian13 --virt-type kvm --graphics none --noautoconsole --import --network bridge="$BRIDGE_NAME",model=virtio,mac="$mac"

  ok "Created VM: $name"
}

wait_for_ssh() {
  local ip="$1"
  local name="$2"

  log "Waiting for SSH on $name ($ip)..."

  for _ in $(seq 1 90); do
    if ssh_ready_for_expected_identity "$ip"; then
      ok "SSH ready: $name ($ip)"
      return 0
    fi
    sleep 5
  done

  warn "SSH did not become ready for $name ($ip) within timeout."
  warn "VM may still be booting/cloud-init may still be running."
  warn "Try manually: ssh -i ${SSH_KEY} ${VM_USER}@${ip}"
  return 1
}

write_ansible_inventory() {
  mkdir -p "$(dirname "$ANSIBLE_INVENTORY")"

  cat > "$ANSIBLE_INVENTORY" <<INVEOF
[control_plane]
cp ansible_host=${CP_IP}

[workers]
worker1 ansible_host=${WORKER1_IP}
worker2 ansible_host=${WORKER2_IP}

[k3s_cluster:children]
control_plane
workers

[all:vars]
ansible_user=${VM_USER}
ansible_become=true
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=${SSH_KEY}
INVEOF

  ok "Wrote Ansible inventory: $ANSIBLE_INVENTORY"
}

print_summary() {
  cat <<SUMMARY

[DONE] POC VM provisioning step finished.

VM access:
  User:      ${VM_USER}
  Password:  ${VM_PASSWORD}
  SSH key:   ${SSH_KEY}

VMs:
  Hostname: ${CP_NAME}
  IP:       ${CP_IP}
  SSH:      ssh -i ${SSH_KEY} ${VM_USER}@${CP_IP}

  Hostname: ${WORKER1_NAME}
  IP:       ${WORKER1_IP}
  SSH:      ssh -i ${SSH_KEY} ${VM_USER}@${WORKER1_IP}

  Hostname: ${WORKER2_NAME}
  IP:       ${WORKER2_IP}
  SSH:      ssh -i ${SSH_KEY} ${VM_USER}@${WORKER2_IP}

Inventory:
  ${ANSIBLE_INVENTORY}

Automation note:
  This provisioner creates or repairs the VM layer and writes the generated inventory.
  The workflow should continue with Ansible ping, OS baseline, K3s setup, storage validation,
  deployment, and final validation.

To force VM recreation later:
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

  local iface
  iface="$(detect_iface)"
  [[ -n "$iface" ]] || fatal "Could not detect default network interface"

  ensure_bridge "$iface"
  assign_vm_ips

  mkdir -p "$BUILD_DIR"
  download_base_image

  create_vm "$CP_NAME" "$CP_IP"
  create_vm "$WORKER1_NAME" "$WORKER1_IP"
  create_vm "$WORKER2_NAME" "$WORKER2_IP"

  wait_for_ssh "$CP_IP" "$CP_NAME"
  wait_for_ssh "$WORKER1_IP" "$WORKER1_NAME"
  wait_for_ssh "$WORKER2_IP" "$WORKER2_NAME"

  write_ansible_inventory
  sudo virsh list --all

  print_summary
}

main "$@"
