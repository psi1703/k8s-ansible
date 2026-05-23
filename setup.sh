#!/usr/bin/env bash
set -Eeuo pipefail

# Smart single operator entrypoint for OTP Relay Kubernetes / Ansible setup.
# Normal use: ./setup.sh
#
# This version does not select Ansible merely because an inventory file exists.
# It verifies that inventory hosts are SSH reachable first. If not, it runs the
# VM provisioner in repair/recreate mode so stale shut-off domains, missing seed
# ISOs, stale inventories, and broken VM identities do not trap the installer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FORCE_ENV_MENU="0"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
DRY_RUN="0"
FORCE_LOCAL="0"
FORCE_REPROVISION_VMS="0"
SKIP_ANSIBLE="0"

DEPLOY_OTP_RELAY="${DEPLOY_OTP_RELAY:-1}"
VALIDATE_OTP_RELAY="${VALIDATE_OTP_RELAY:-0}"

log() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
fatal() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./setup.sh

Optional overrides:
  --edit-env          Open the saved .env change menu before continuing.
  --dry-run           Detect state and print planned action without changing the system.
  --local             Force local K3s/app installer path for this run.
  --reprovision-vms   Force VM recreation/repair even if inventory/VMs already exist.
  --no-ansible        Provision/update VMs only; skip Ansible cluster setup.
  --noninteractive    Do not prompt where supported; requires complete .env/exported env.
  -h, --help          Show this help.

Default behavior:
  ./setup.sh creates or reuses .env, validates real runtime state, and chooses
  the correct setup path automatically. .env stores configuration values only;
  it does not decide workflow mode.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --edit-env) FORCE_ENV_MENU="1" ;;
    --dry-run) DRY_RUN="1" ;;
    --local) FORCE_LOCAL="1" ;;
    --reprovision-vms) FORCE_REPROVISION_VMS="1" ;;
    --no-ansible) SKIP_ANSIBLE="1" ;;
    --noninteractive) NONINTERACTIVE="1"; export NONINTERACTIVE ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "unknown argument: $1" ;;
  esac
  shift
done

restore_setup_logging() {
  eval 'log() { printf '\''[setup] %s\n'\'' "$*"; }'
  eval 'warn() { printf '\''[setup] WARNING: %s\n'\'' "$*" >&2; }'
  eval 'fatal() { printf '\''[setup] ERROR: %s\n'\'' "$*" >&2; exit 1; }'
}

source_installer_env_libs() {
  [ -f "$SCRIPT_DIR/scripts/lib/common.sh" ] || fatal "missing scripts/lib/common.sh"
  [ -f "$SCRIPT_DIR/scripts/lib/env.sh" ] || fatal "missing scripts/lib/env.sh"

  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/env.sh"
  restore_setup_logging
}

chown_env_to_original_user() {
  local file="${ENV_FILE:-$SCRIPT_DIR/.env}"
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != "root" ] && [ -f "$file" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$file" 2>/dev/null || chown "$SUDO_USER" "$file" 2>/dev/null || true
    chmod 0600 "$file" || true
  fi
}

source_env_if_present() {
  if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/.env"
    set +a
  fi
}

run_as_original_user() {
  local cmd=("$@")
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != "root" ]; then
    sudo -H -u "$SUDO_USER" env \
      HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)" \
      USER="$SUDO_USER" \
      LOGNAME="$SUDO_USER" \
      PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}" \
      "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

run_with_sudo_or_root() {
  local cmd=("$@")
  if [ "$(id -u)" -eq 0 ]; then
    "${cmd[@]}"
  else
    sudo "${cmd[@]}"
  fi
}

ensure_base_env() {
  source_installer_env_libs
  export SCRIPT_DIR ENV_FILE NONINTERACTIVE
  ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

  load_or_create_env

  if [ "$FORCE_ENV_MENU" = "1" ]; then
    change_env_menu
    source_env_file "$ENV_FILE"
    normalize_loaded_env
    validate_env_required
  fi

  chown_env_to_original_user
  source_env_if_present
}

_env_escape_sed() {
  printf '%s' "$1" | sed 's/[\\&]/\\&/g'
}

quote_env_value() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

set_env_key() {
  local key="$1"
  local value="$2"
  local file="${ENV_FILE:-$SCRIPT_DIR/.env}"
  local quoted escaped

  quoted="$(quote_env_value "$value")"
  escaped="$(_env_escape_sed "$key=$quoted")"

  touch "$file"
  chmod 0600 "$file" || true
  chown_env_to_original_user

  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$quoted" >> "$file"
  fi

  printf -v "$key" '%s' "$value"
  export "$key"
}

prompt_value() {
  local key="$1"
  local label="$2"
  local required="${3:-1}"
  local secret="${4:-0}"
  local default="${!key:-}"
  local input=""

  if [ "$NONINTERACTIVE" = "1" ]; then
    if [ "$required" = "1" ] && [ -z "$default" ]; then
      fatal "$key is required; set it in .env or export it"
    fi
    set_env_key "$key" "$default"
    return 0
  fi

  while true; do
    if [ "$secret" = "1" ]; then
      if [ -n "$default" ]; then
        read -r -s -p "$label [currently set, press Enter to keep]: " input || input=""
      else
        read -r -s -p "$label: " input || input=""
      fi
      printf '\n'
    else
      if [ -n "$default" ]; then
        read -r -p "$label [$default]: " input || input=""
      else
        read -r -p "$label: " input || input=""
      fi
    fi

    input="${input:-$default}"
    if [ -n "$input" ] || [ "$required" != "1" ]; then
      set_env_key "$key" "$input"
      return 0
    fi
    warn "$key is required"
  done
}

default_gateway() {
  ip route show default 2>/dev/null | awk '{print $3; exit}'
}

default_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

default_dns() {
  local dns=""

  dns="$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"

  case "$dns" in
    ""|127.*|::1)
      dns="$(default_gateway)"
      ;;
  esac

  case "$dns" in
    ""|127.*|::1)
      dns="1.1.1.1"
      ;;
  esac

  printf '%s\n' "$dns"
}

sanitize_dns_value() {
  local dns="${1:-}"

  case "$dns" in
    ""|127.*|::1)
      dns="$(default_gateway)"
      ;;
  esac

  case "$dns" in
    ""|127.*|::1)
      dns="1.1.1.1"
      ;;
  esac

  printf '%s\n' "$dns"
}

default_host_cidr() {
  local iface="${HOST_IFACE:-}"
  [ -n "$iface" ] || iface="$(default_iface)"
  [ -n "$iface" ] || return 0
  ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}'
}

default_scan_prefix() {
  local cidr="${HOST_IP_CIDR:-}"
  local ip="${cidr%%/*}"
  if printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s.%s.%s' \
      "$(printf '%s' "$ip" | cut -d. -f1)" \
      "$(printf '%s' "$ip" | cut -d. -f2)" \
      "$(printf '%s' "$ip" | cut -d. -f3)"
  fi
}

ensure_vm_env() {
  source_env_if_present

  BRIDGE_NAME="${BRIDGE_NAME:-br0}"
  HOST_IFACE="${HOST_IFACE:-$(default_iface)}"
  HOST_IP_CIDR="${HOST_IP_CIDR:-$(default_host_cidr)}"
  GATEWAY="${GATEWAY:-$(default_gateway)}"
  DNS="$(sanitize_dns_value "${DNS:-$(default_dns)}")"
  PREFIX="${PREFIX:-24}"
  IP_SCAN_PREFIX="${IP_SCAN_PREFIX:-$(default_scan_prefix)}"
  IP_SCAN_START="${IP_SCAN_START:-100}"
  IP_SCAN_END="${IP_SCAN_END:-249}"
  VM_USER="${VM_USER:-otp-relay}"
  VM_PASSWORD="${VM_PASSWORD:-otp-relay}"
  VM_RAM_MB="${VM_RAM_MB:-3072}"
  VM_VCPUS="${VM_VCPUS:-2}"
  VM_DISK_GB="${VM_DISK_GB:-20}"
  AUTO_ASSIGN_IPS="${AUTO_ASSIGN_IPS:-1}"

  cat <<'EOF_VM_INFO'

VM provisioning settings
EOF_VM_INFO
  prompt_value BRIDGE_NAME "Libvirt bridge name" 1 0
  prompt_value HOST_IFACE "Host interface to bridge for VMs" 1 0
  prompt_value HOST_IP_CIDR "Host bridge IP/CIDR" 1 0
  prompt_value GATEWAY "Network gateway" 1 0
  prompt_value DNS "DNS server for VMs" 1 0
  prompt_value PREFIX "Network prefix length" 1 0
  prompt_value IP_SCAN_PREFIX "IP scan prefix for VM auto assignment, for example 172.31.11" 1 0
  prompt_value IP_SCAN_START "IP scan start octet" 1 0
  prompt_value IP_SCAN_END "IP scan end octet" 1 0
  prompt_value VM_USER "VM login user" 1 0
  prompt_value VM_PASSWORD "VM login password" 1 1
  prompt_value VM_RAM_MB "VM RAM MB" 1 0
  prompt_value VM_VCPUS "VM vCPUs" 1 0
  prompt_value VM_DISK_GB "VM disk GB" 1 0
  prompt_value AUTO_ASSIGN_IPS "Auto assign free VM IPs? 1=yes, 0=no" 1 0

  if [ "${AUTO_ASSIGN_IPS:-1}" != "1" ]; then
    prompt_value CP_IP "Control-plane VM IP" 1 0
    prompt_value WORKER1_IP "Worker 1 VM IP" 1 0
    prompt_value WORKER2_IP "Worker 2 VM IP" 1 0
  fi

  source_env_if_present
}

provisioner_path() {
  local p="$SCRIPT_DIR/automation/libvirt/provision-vms.sh"
  [ -f "$p" ] && printf '%s\n' "$p"
}

ansible_runner_path() {
  local candidate
  for candidate in \
    "$SCRIPT_DIR/automation/ansible/run-cluster" \
    "$SCRIPT_DIR/automation/ansible/run-cluster.sh" \
    "$SCRIPT_DIR/automation/ansible/run-poc-cluster.sh"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ansible_inventory_path() {
  local candidate
  for candidate in \
    "$SCRIPT_DIR/automation/ansible/inventory.generated.ini" \
    "$SCRIPT_DIR/automation/ansible/inventory.poc.generated.ini"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

inventory_hosts() {
  local inventory="$1"

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
  ' "$inventory"
}

ssh_ready_for_inventory_host() {
  local host="$1"
  local ip="$2"
  local user="${VM_USER:-otp-relay}"
  local key="${SSH_KEY:-$HOME/.ssh/otp-relay-poc}"

  [ -n "$host" ] || return 1
  [ -n "$ip" ] || return 1
  [ -f "$key" ] || return 1

  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true

  ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    -o ConnectTimeout=5 \
    -i "$key" \
    "${user}@${ip}" \
    'hostname >/dev/null 2>&1' >/dev/null 2>&1
}

inventory_ssh_ready() {
  local inventory="$1"
  local host ip
  local count=0

  [ -f "$inventory" ] || return 1

  while read -r host ip; do
    [ -n "$host" ] || continue
    count=$((count + 1))
    if ! ssh_ready_for_inventory_host "$host" "$ip"; then
      return 1
    fi
  done <<EOF_INVENTORY_HOSTS
$(inventory_hosts "$inventory")
EOF_INVENTORY_HOSTS

  [ "$count" -gt 0 ]
}

print_inventory_reachability() {
  local inventory="$1"
  local host ip

  [ -f "$inventory" ] || return 0

  while read -r host ip; do
    [ -n "$host" ] || continue
    if ssh_ready_for_inventory_host "$host" "$ip"; then
      log "  inventory host ${host} (${ip}): ssh reachable"
    else
      log "  inventory host ${host} (${ip}): ssh unreachable"
    fi
  done <<EOF_INVENTORY_HOSTS
$(inventory_hosts "$inventory")
EOF_INVENTORY_HOSTS
}

local_kubectl() {
  if command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  elif command -v kubectl >/dev/null 2>&1; then
    kubectl "$@"
  else
    return 127
  fi
}

local_k3s_reachable() {
  local_kubectl get nodes >/dev/null 2>&1
}

local_k3s_installed() {
  command -v k3s >/dev/null 2>&1 && return 0
  systemctl list-unit-files k3s.service >/dev/null 2>&1 && return 0
  [ -d /var/lib/rancher/k3s ] && return 0
  return 1
}

namespace_exists() {
  local ns="${NAMESPACE:-otp-relay}"
  local_kubectl get namespace "$ns" >/dev/null 2>&1
}

app_deployed() {
  local ns="${NAMESPACE:-otp-relay}"
  local_kubectl get deploy otp-relay -n "$ns" >/dev/null 2>&1
}

redis_deployed() {
  local ns="${NAMESPACE:-otp-relay}"
  local_kubectl get statefulset otp-redis -n "$ns" >/dev/null 2>&1
}

virsh_cmd() {
  if command -v virsh >/dev/null 2>&1; then
    if virsh list --all >/dev/null 2>&1; then
      virsh "$@"
    else
      sudo virsh "$@"
    fi
  else
    return 127
  fi
}

libvirt_vm_exists() {
  command -v virsh >/dev/null 2>&1 || return 1
  local cp_name="${CP_NAME:-otp-master}"
  local w1_name="${WORKER1_NAME:-otp-worker1}"
  local w2_name="${WORKER2_NAME:-otp-worker2}"

  virsh_cmd list --all --name 2>/dev/null | grep -Eq "^(${cp_name}|${w1_name}|${w2_name})$"
}

detect_setup_path() {
  local provisioner=""
  local runner=""
  local inventory=""

  provisioner="$(provisioner_path || true)"
  runner="$(ansible_runner_path || true)"
  inventory="$(ansible_inventory_path || true)"

  if [ "$FORCE_LOCAL" = "1" ]; then
    printf '%s\n' "local-forced"
    return 0
  fi

  if [ "$FORCE_REPROVISION_VMS" = "1" ]; then
    [ -n "$provisioner" ] || fatal "--reprovision-vms requested but automation/libvirt/provision-vms.sh is missing"
    [ -n "$runner" ] || fatal "--reprovision-vms requested but no Ansible runner was found"
    printf '%s\n' "vm-provision"
    return 0
  fi

  if [ -n "$inventory" ] && [ -n "$runner" ]; then
    if inventory_ssh_ready "$inventory"; then
      printf '%s\n' "ansible-existing"
      return 0
    fi

    warn "generated inventory exists, but one or more inventory hosts are not SSH reachable"
    if [ -n "$provisioner" ]; then
      printf '%s\n' "vm-provision"
      return 0
    fi

    fatal "inventory hosts are unreachable and VM provisioner is missing"
  fi

  if local_k3s_reachable; then
    printf '%s\n' "local-existing"
    return 0
  fi

  if libvirt_vm_exists && [ -n "$provisioner" ] && [ -n "$runner" ]; then
    printf '%s\n' "vm-provision"
    return 0
  fi

  if [ -n "$provisioner" ] && [ -n "$runner" ] && ! local_k3s_installed; then
    printf '%s\n' "vm-provision"
    return 0
  fi

  printf '%s\n' "local-fresh"
}

print_detected_state() {
  local provisioner="$(provisioner_path || true)"
  local runner="$(ansible_runner_path || true)"
  local inventory="$(ansible_inventory_path || true)"

  log "detected state:"
  log "  .env: $([ -f "$SCRIPT_DIR/.env" ] && echo present || echo missing)"
  log "  provisioner: ${provisioner:-missing}"
  log "  ansible runner: ${runner:-missing}"
  log "  ansible inventory: ${inventory:-missing}"
  if [ -n "$inventory" ]; then
    print_inventory_reachability "$inventory"
  fi
  if local_k3s_reachable; then
    log "  local cluster: reachable"
  elif local_k3s_installed; then
    log "  local cluster: installed but not reachable"
  else
    log "  local cluster: missing"
  fi
  if libvirt_vm_exists; then
    log "  libvirt OTP Relay VMs: present"
  else
    log "  libvirt OTP Relay VMs: missing or virsh unavailable"
  fi
  if local_k3s_reachable && namespace_exists; then
    log "  namespace ${NAMESPACE:-otp-relay}: present"
  else
    log "  namespace ${NAMESPACE:-otp-relay}: not detected locally"
  fi
  if local_k3s_reachable && app_deployed; then
    log "  app deployment: present locally"
  else
    log "  app deployment: not detected locally"
  fi
  if local_k3s_reachable && redis_deployed; then
    log "  redis: present locally"
  else
    log "  redis: not detected locally"
  fi
}

run_local_install() {
  [ -f "$SCRIPT_DIR/install-otp-relay-k8s.sh" ] || fatal "install-otp-relay-k8s.sh is missing"
  log "running local installer: install-otp-relay-k8s.sh"
  run_with_sudo_or_root bash "$SCRIPT_DIR/install-otp-relay-k8s.sh"
}

run_vm_provisioner() {
  local provisioner inventory
  provisioner="$(provisioner_path || true)"
  [ -n "$provisioner" ] || fatal "missing VM provisioner: automation/libvirt/provision-vms.sh"

  ensure_vm_env
  chown_env_to_original_user

  inventory="$(ansible_inventory_path || true)"
  if [ "$FORCE_REPROVISION_VMS" = "1" ]; then
    export RECREATE_VMS="1"
  elif [ -n "$inventory" ] && ! inventory_ssh_ready "$inventory"; then
    warn "existing inventory is not reachable; forcing VM recreation/repair"
    export RECREATE_VMS="1"
  fi

  log "running VM provisioner: automation/libvirt/provision-vms.sh"
  run_as_original_user env RECREATE_VMS="${RECREATE_VMS:-0}" bash "$provisioner"
}

run_ansible_cluster() {
  local runner inventory
  runner="$(ansible_runner_path || true)"
  inventory="$(ansible_inventory_path || true)"

  [ -n "$runner" ] || fatal "missing Ansible runner: automation/ansible/run-cluster or run-poc-cluster.sh"
  [ -n "$inventory" ] || fatal "missing generated inventory; run VM provisioning first"

  # VMs may still be running cloud-init after provisioning. Wait up to 3 minutes
  # for all inventory hosts to become SSH-reachable before handing off to Ansible.
  log "waiting for all inventory hosts to become SSH reachable (up to 180s)..."
  local elapsed=0
  until inventory_ssh_ready "$inventory"; do
    if [ "$elapsed" -ge 180 ]; then
      fatal "inventory hosts are not SSH reachable after ${elapsed}s; check VM console or rerun setup"
    fi
    log "  not yet reachable, retrying in 10s (${elapsed}s elapsed)..."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  log "all inventory hosts are SSH reachable"

  if [ "$SKIP_ANSIBLE" = "1" ]; then
    log "Ansible cluster setup skipped by --no-ansible"
    return 0
  fi

  log "running Ansible cluster setup with inventory: $inventory"
  run_as_original_user env \
    INVENTORY="$inventory" \
    DEPLOY_OTP_RELAY="$DEPLOY_OTP_RELAY" \
    VALIDATE_OTP_RELAY="$VALIDATE_OTP_RELAY" \
    bash "$runner"
}

print_final_status() {
  log "final local status, if available"
  if local_k3s_reachable; then
    local_kubectl get nodes -o wide || true
    local_kubectl get pods -n "${NAMESPACE:-otp-relay}" -o wide || true
    local_kubectl get svc -n "${NAMESPACE:-otp-relay}" || true
    local_kubectl get ingress -n "${NAMESPACE:-otp-relay}" || true
  else
    log "no local kubectl/k3s cluster reachable from this host"
  fi
}

main() {
  local path

  ensure_base_env
  print_detected_state
  path="$(detect_setup_path)"
  log "selected setup path: $path"

  if [ "$DRY_RUN" = "1" ]; then
    log "dry-run requested; no changes will be made"
    return 0
  fi

  case "$path" in
    vm-provision)
      run_vm_provisioner
      run_ansible_cluster
      ;;
    ansible-existing)
      run_ansible_cluster
      ;;
    local-existing|local-fresh|local-forced)
      run_local_install
      ;;
    *)
      fatal "unsupported detected setup path: $path"
      ;;
  esac

  print_final_status
}

main "$@"
