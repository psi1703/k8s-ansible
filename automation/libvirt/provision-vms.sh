#!/usr/bin/env bash
set -Eeuo pipefail

# OTP Relay POC VM provisioner
# Creates:
#   otp-cp      172.31.11.151
#   otp-worker1 172.31.11.152
#   otp-worker2 172.31.11.153
#
# Usage:
#   ./automation/libvirt/provision-poc-vms.sh
#
# Optional:
#   HOST_IFACE=enp0s31f6 ./automation/libvirt/provision-poc-vms.sh
#   VM_PASSWORD='your-password' ./automation/libvirt/provision-poc-vms.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BRIDGE_NAME="${BRIDGE_NAME:-br0}"
HOST_IFACE="${HOST_IFACE:-}"
HOST_IP_CIDR="${HOST_IP_CIDR:-172.31.11.111/24}"
HOST_IP="${HOST_IP_CIDR%%/*}"
GATEWAY="${GATEWAY:-172.31.11.1}"
DNS="${DNS:-172.31.11.1}"
PREFIX="${PREFIX:-24}"

VM_USER="${VM_USER:-psi}"
VM_PASSWORD="${VM_PASSWORD:-psi}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/otp-relay-poc}"
SSH_PUB_KEY="${SSH_KEY}.pub"

VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"
BASE_IMAGE="${VM_IMAGE_DIR}/debian-12-generic-amd64.qcow2"

ANSIBLE_INVENTORY="${REPO_ROOT}/automation/ansible/inventory.poc.generated.ini"

CP_NAME="${CP_NAME:-otp-cp}"
WORKER1_NAME="${WORKER1_NAME:-otp-worker1}"
WORKER2_NAME="${WORKER2_NAME:-otp-worker2}"

CP_IP="${CP_IP:-172.31.11.151}"
WORKER1_IP="${WORKER1_IP:-172.31.11.152}"
WORKER2_IP="${WORKER2_IP:-172.31.11.153}"

VM_RAM_MB="${VM_RAM_MB:-3072}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GB="${VM_DISK_GB:-30}"

BUILD_DIR="${REPO_ROOT}/automation/libvirt/build"

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing command: $1"
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
    curl \
    jq \
    openssh-client \
    iproute2 \
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
    warn "Group membership may require logout/login later. This script will use sudo virsh/virt-install where needed."
  fi
}

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    log "Creating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C "otp-relay-poc" -N ""
  fi

  [[ -f "$SSH_PUB_KEY" ]] || fatal "Missing SSH public key: $SSH_PUB_KEY"
}

check_host() {
  local vmx_count
  vmx_count="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
  [[ "$vmx_count" -gt 0 ]] || fatal "CPU virtualization is not available"

  grep -qE '(^| )kvm(_intel|_amd)?( |$)' /proc/modules || fatal "KVM module is not loaded"

  ok "KVM available: $vmx_count CPU virtualization flags found"
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
    ipv4.dns "$DNS 8.8.8.8" \
    ipv6.method ignore

  sudo nmcli con add type ethernet ifname "$iface" master "$BRIDGE_NAME" con-name "${BRIDGE_NAME}-slave-${iface}"

  sudo nmcli con down "$active_con" || true
  sudo nmcli con up "$BRIDGE_NAME"

  sleep 5
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
  sleep 5
}

ensure_bridge() {
  local iface="$1"

  log "Checking bridge/network setup..."
  log "Host NIC: $iface"
  log "Target bridge: $BRIDGE_NAME"
  log "Host bridge IP: $HOST_IP_CIDR"

  if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ok "$BRIDGE_NAME already exists"
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
  ping -c 2 "$GATEWAY" >/dev/null || fatal "Cannot ping gateway $GATEWAY after bridge setup"
  ok "Bridge network is ready"
}

download_base_image() {
  sudo mkdir -p "$VM_IMAGE_DIR"

  if [[ -f "$BASE_IMAGE" ]]; then
    ok "Base image already exists: $BASE_IMAGE"
    return 0
  fi

  log "Downloading Debian 12 cloud image..."
  sudo curl -L "$BASE_IMAGE_URL" -o "$BASE_IMAGE"
  ok "Downloaded base image: $BASE_IMAGE"
}

destroy_existing_vm_if_requested() {
  local name="$1"

  if sudo virsh dominfo "$name" >/dev/null 2>&1; then
    if [[ "${RECREATE_VMS:-0}" == "1" ]]; then
      warn "Recreating existing VM: $name"
      sudo virsh destroy "$name" >/dev/null 2>&1 || true
      sudo virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || sudo virsh undefine "$name" >/dev/null 2>&1 || true
    else
      echo "exists"
      return 0
    fi
  fi

  echo "new"
}

create_vm() {
  local name="$1"
  local ip="$2"

  local state
  state="$(destroy_existing_vm_if_requested "$name")"

  if [[ "$state" == "exists" ]]; then
    ok "VM already exists: $name"
    return 0
  fi

  local disk="${VM_IMAGE_DIR}/${name}.qcow2"
  local seed="${BUILD_DIR}/${name}-seed.iso"
  local user_data="${BUILD_DIR}/${name}-user-data"
  local meta_data="${BUILD_DIR}/${name}-meta-data"
  local network_config="${BUILD_DIR}/${name}-network-config"

  log "Creating VM: $name at $ip"

  sudo rm -f "$disk"
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "${VM_DISK_GB}G"

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
  enp1s0:
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

  cloud-localds \
    --network-config="$network_config" \
    "$seed" \
    "$user_data" \
    "$meta_data"

  sudo virt-install \
    --name "$name" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --disk path="$disk",format=qcow2,bus=virtio \
    --disk path="$seed",device=cdrom \
    --os-variant debian12 \
    --virt-type kvm \
    --graphics none \
    --noautoconsole \
    --import \
    --network bridge="$BRIDGE_NAME",model=virtio

  ok "Created VM: $name"
}

wait_for_ssh() {
  local ip="$1"
  local name="$2"

  log "Waiting for SSH on $name ($ip)..."

  for _ in $(seq 1 90); do
    if ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=3 \
      -i "$SSH_KEY" \
      "${VM_USER}@${ip}" "hostname" >/dev/null 2>&1; then
      ok "SSH ready: $name ($ip)"
      return 0
    fi
    sleep 5
  done

  fatal "SSH did not become ready for $name ($ip)"
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

[DONE] POC VMs are provisioned.

VMs:
  ${CP_NAME}       ${CP_IP}
  ${WORKER1_NAME}  ${WORKER1_IP}
  ${WORKER2_NAME}  ${WORKER2_IP}

Inventory:
  ${ANSIBLE_INVENTORY}

Next commands:

  cd ${REPO_ROOT}/automation/ansible
  ansible -i inventory.poc.generated.ini all -m ping
  ansible-playbook -i inventory.poc.generated.ini playbooks/00-os-baseline.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/10-k3s-control-plane.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/20-k3s-workers.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/30-node-labels.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/40-storage-validate.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/50-deploy-otp-relay.yml
  ansible-playbook -i inventory.poc.generated.ini playbooks/70-validate-production.yml

To recreate VMs later:
  RECREATE_VMS=1 ${REPO_ROOT}/automation/libvirt/provision-poc-vms.sh

SUMMARY
}

main() {
  cd "$REPO_ROOT"

  check_host
  install_packages
  enable_libvirt
  ensure_ssh_key

  local iface
  iface="$(detect_iface)"
  [[ -n "$iface" ]] || fatal "Could not detect default network interface"

  ensure_bridge "$iface"

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
