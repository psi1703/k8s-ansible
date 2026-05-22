#!/usr/bin/env bash
set -Eeuo pipefail

# Single operator entrypoint for OTP Relay Kubernetes / Ansible setup.
#
# Default mode runs the existing local K3s installer.
# VM mode runs the existing libvirt VM provisioner and then the existing
# Ansible POC cluster runner.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SETUP_ACTION="local"
RUN_ANSIBLE="auto"
DEPLOY_OTP_RELAY="${DEPLOY_OTP_RELAY:-0}"
VALIDATE_OTP_RELAY="${VALIDATE_OTP_RELAY:-0}"
FORCE_ENV_MENU="0"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

log() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
fatal() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./setup.sh [options]

Common:
  ./setup.sh                         Run local K3s/app setup using install-otp-relay-k8s.sh
  ./setup.sh --provision-vms          Create/update POC VMs, then run Ansible cluster setup
  ./setup.sh --provision-vms --deploy Run POC VMs, Ansible cluster setup, and OTP Relay deploy

Options:
  --local                 Run the local installer flow. This is the default.
  --provision-vms         Run automation/libvirt/provision-vms.sh before Ansible.
  --ansible               Run automation/ansible/run-cluster.sh.
  --no-ansible            Only run VM provisioning; skip Ansible cluster setup.
  --deploy                Set DEPLOY_OTP_RELAY=1 for the Ansible POC runner.
  --validate              Set VALIDATE_OTP_RELAY=1 for the Ansible POC runner.
  --edit-env              Open the saved .env change menu before continuing.
  --noninteractive        Do not prompt where supported; requires a complete .env/exported env.
  -h, --help              Show this help.

Notes:
  - .env is the single source of operator input.
  - Existing valid .env values are reused and not overwritten silently.
  - VM provisioning uses automation/libvirt/provision-vms.sh.
  - The provisioner writes automation/ansible/inventory.generated.ini; setup.sh passes
    that exact inventory to automation/ansible/run-cluster.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local)
      SETUP_ACTION="local"
      ;;
    --provision-vms|--vms|--vm)
      SETUP_ACTION="provision-vms"
      ;;
    --ansible)
      RUN_ANSIBLE="1"
      ;;
    --no-ansible)
      RUN_ANSIBLE="0"
      ;;
    --deploy)
      DEPLOY_OTP_RELAY="1"
      ;;
    --validate)
      VALIDATE_OTP_RELAY="1"
      ;;
    --edit-env)
      FORCE_ENV_MENU="1"
      ;;
    --noninteractive)
      NONINTERACTIVE="1"
      export NONINTERACTIVE
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "unknown argument: $1"
      ;;
  esac
  shift
done

source_installer_env_libs() {
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/env.sh"
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
      fatal "$key is required for VM provisioning; set it in .env or export it"
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
  awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null || true
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
    printf '%s.%s.%s' "$(printf '%s' "$ip" | cut -d. -f1)" "$(printf '%s' "$ip" | cut -d. -f2)" "$(printf '%s' "$ip" | cut -d. -f3)"
  fi
}

ensure_vm_env() {
  source_env_if_present

  HOST_IFACE="${HOST_IFACE:-$(default_iface)}"
  HOST_IP_CIDR="${HOST_IP_CIDR:-$(default_host_cidr)}"
  GATEWAY="${GATEWAY:-$(default_gateway)}"
  DNS="${DNS:-$(default_dns)}"
  PREFIX="${PREFIX:-24}"
  IP_SCAN_PREFIX="${IP_SCAN_PREFIX:-$(default_scan_prefix)}"
  IP_SCAN_START="${IP_SCAN_START:-150}"
  IP_SCAN_END="${IP_SCAN_END:-199}"
  VM_USER="${VM_USER:-otp-relay}"
  VM_PASSWORD="${VM_PASSWORD:-otp-relay}"
  VM_RAM_MB="${VM_RAM_MB:-3072}"
  VM_VCPUS="${VM_VCPUS:-2}"
  VM_DISK_GB="${VM_DISK_GB:-20}"
  AUTO_ASSIGN_IPS="${AUTO_ASSIGN_IPS:-1}"

  cat <<'EOF_VM_INFO'

VM provisioning settings
EOF_VM_INFO
  prompt_value HOST_IFACE "Host interface to bridge for VMs" 1 0
  prompt_value HOST_IP_CIDR "Host bridge IP/CIDR" 1 0
  prompt_value GATEWAY "Network gateway" 1 0
  prompt_value DNS "DNS server" 1 0
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

run_local_install() {
  [ -f "$SCRIPT_DIR/install-otp-relay-k8s.sh" ] || fatal "install-otp-relay-k8s.sh is missing"
  log "running local installer: install-otp-relay-k8s.sh"
  run_with_sudo_or_root bash "$SCRIPT_DIR/install-otp-relay-k8s.sh"
}

run_vm_provisioner() {
  local provisioner="$SCRIPT_DIR/automation/libvirt/provision-vms.sh"
  [ -f "$provisioner" ] || fatal "missing VM provisioner: $provisioner"

  ensure_base_env
  chown_env_to_original_user
  ensure_vm_env
  chown_env_to_original_user

  log "running VM provisioner: automation/libvirt/provision-vms.sh"
  run_as_original_user bash "$provisioner"
}

run_ansible_cluster() {
  local runner="$SCRIPT_DIR/automation/ansible/run-cluster.sh"
  local inventory="$SCRIPT_DIR/automation/ansible/inventory.generated.ini"

  [ -f "$runner" ] || fatal "missing Ansible runner: $runner"
  [ -f "$inventory" ] || fatal "missing generated inventory: $inventory"

  log "running Ansible cluster setup with generated inventory"
  run_as_original_user env \
    INVENTORY="$inventory" \
    DEPLOY_OTP_RELAY="$DEPLOY_OTP_RELAY" \
    VALIDATE_OTP_RELAY="$VALIDATE_OTP_RELAY" \
    bash "$runner"
}

main() {
  case "$SETUP_ACTION" in
    local)
      run_local_install
      ;;
    provision-vms)
      run_vm_provisioner
      if [ "$RUN_ANSIBLE" = "auto" ]; then
        RUN_ANSIBLE="1"
      fi
      if [ "$RUN_ANSIBLE" = "1" ]; then
        run_ansible_cluster
      else
        log "VM provisioning complete; Ansible cluster setup skipped by --no-ansible"
      fi
      ;;
    *)
      fatal "unsupported setup action: $SETUP_ACTION"
      ;;
  esac
}

main "$@"
