#!/usr/bin/env bash
# Host detection, preflight, package install, and K3s readiness.
# Source this file from install-otp-relay-k8s.sh; do not execute it directly.

OS_ID="${OS_ID:-unknown}"
OS_NAME="${OS_NAME:-unknown}"
OS_VERSION_ID="${OS_VERSION_ID:-unknown}"
OS_LIKE="${OS_LIKE:-}"
ARCH_RAW="${ARCH_RAW:-}"
RUNNER_ARCH="${RUNNER_ARCH:-}"
IS_RPI="${IS_RPI:-0}"

_preflight_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

_preflight_require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "preflight/package/K3s preparation must run as root. Run the installer through setup.sh or with sudo."
  fi
}

_preflight_retry() {
  local attempts="${1:-3}"
  local delay="${2:-5}"
  shift 2

  local i=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [ "$i" -ge "$attempts" ]; then
      return 1
    fi

    warn "command failed, retrying in ${delay}s ($i/$attempts): $*"
    sleep "$delay"
    i=$((i + 1))
  done
}

_wait_for_apt_locks() {
  local waited=0
  local lock
  local locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"

  while true; do
    local busy=0

    if _preflight_cmd_exists fuser; then
      for lock in $locks; do
        if [ -e "$lock" ] && fuser "$lock" >/dev/null 2>&1; then
          busy=1
          break
        fi
      done
    fi

    [ "$busy" = "0" ] && return 0

    if [ "$waited" -ge 180 ]; then
      fatal "apt/dpkg lock is still held after ${waited}s. Another package operation is running; stop it or wait and rerun setup."
    fi

    log "waiting for apt/dpkg lock to be released (${waited}s elapsed)"
    sleep 5
    waited=$((waited + 5))
  done
}

run_apt_get() {
  _preflight_require_root
  _wait_for_apt_locks

  DEBIAN_FRONTEND=noninteractive _preflight_retry 3 10 \
    apt-get \
      -o Acquire::Retries=3 \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
}

detect_host_environment() {
  log "detecting host OS, architecture, and hardware profile"

  OS_ID="unknown"
  OS_NAME="unknown"
  OS_VERSION_ID="unknown"
  OS_LIKE=""

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) RUNNER_ARCH="x64" ;;
    aarch64|arm64) RUNNER_ARCH="arm64" ;;
    armv7l|armv6l|armhf) RUNNER_ARCH="arm" ;;
    *) RUNNER_ARCH="" ;;
  esac

  IS_RPI=0
  if grep -qi 'raspberry pi' /proc/cpuinfo 2>/dev/null || grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
    IS_RPI=1
  fi

  export OS_ID OS_NAME OS_VERSION_ID OS_LIKE ARCH_RAW RUNNER_ARCH IS_RPI

  log "detected OS/arch: $OS_NAME / $ARCH_RAW"

  if [ "$IS_RPI" = "1" ]; then
    log "detected Raspberry Pi hardware"
  fi

  return 0
}

is_debian_family() {
  case "${OS_ID:-}" in
    debian|ubuntu|raspbian) return 0 ;;
  esac

  case " ${OS_LIKE:-} " in
    *" debian "*) return 0 ;;
  esac

  return 1
}

prompt_optional_runner_setup() {
  # Optional runner prompt before validation, matching the existing installer behavior.
  # In non-interactive mode, default to 0 without prompting.
  if [ -z "${INSTALL_GITHUB_RUNNER:-}" ]; then
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      INSTALL_GITHUB_RUNNER=0
    elif prompt_yes_no "Install a GitHub Actions self-hosted runner for CI/CD deployments from GitHub? [y/N]" "N"; then
      INSTALL_GITHUB_RUNNER=1
    else
      INSTALL_GITHUB_RUNNER=0
    fi
  fi

  export INSTALL_GITHUB_RUNNER
  log "GitHub runner setup requested: $INSTALL_GITHUB_RUNNER"
}

save_network_firewall_snapshots() {
  _preflight_require_root

  local backup_dir="/var/backups/otp-relay-k8s"

  log "saving network/firewall state snapshots under $backup_dir"
  mkdir -p "$backup_dir"

  if _preflight_cmd_exists ip; then
    ip route > "$backup_dir/ip-route.before" 2>/dev/null || true
    ip addr > "$backup_dir/ip-addr.before" 2>/dev/null || true
  else
    warn "ip command is not available yet; skipping ip route/address snapshots"
  fi

  if _preflight_cmd_exists iptables-save; then
    iptables-save > "$backup_dir/iptables.before" 2>/dev/null || true
  else
    warn "iptables-save is not available yet; skipping iptables snapshot"
  fi

  if _preflight_cmd_exists nft; then
    nft list ruleset > "$backup_dir/nft.before" 2>/dev/null || true
  else
    warn "nft is not available yet; skipping nftables snapshot"
  fi

  log "network/firewall state snapshots saved"
}

check_basic_network_for_install() {
  log "checking basic network/DNS reachability for package and K3s installation"

  if _preflight_cmd_exists getent; then
    if ! getent hosts deb.debian.org >/dev/null 2>&1 && ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
      warn "DNS lookup for common apt repositories failed. apt-get update may fail until DNS/network is fixed."
    fi

    if ! getent hosts get.k3s.io >/dev/null 2>&1; then
      warn "DNS lookup for get.k3s.io failed. K3s installation may fail until DNS/network is fixed."
    fi
  fi

  if _preflight_cmd_exists curl; then
    if ! curl -fsSL --connect-timeout 10 --max-time 20 https://get.k3s.io >/dev/null 2>&1; then
      warn "https://get.k3s.io is not reachable right now. K3s installation may fail if this host cannot access the internet."
    fi
  fi
}

check_noninvasive_host_state() {
  log "running non-invasive preflight checks"

  if _preflight_cmd_exists ss; then
    if ! ss -lnt 2>/dev/null | grep -qE '(^|[[:space:]]|:)22[[:space:]]'; then
      warn "SSH does not appear to be listening on TCP/22. I will not change SSH, but confirm console access before continuing."
    fi
  else
    warn "ss command is not available yet; skipping SSH listener check"
  fi

  if grep -qi '[[:space:]]cifs[[:space:]]' /etc/fstab 2>/dev/null; then
    warn "CIFS entries detected in /etc/fstab. This installer will not mount, unmount, or edit them."
  fi

  if mount | grep -qi ' type cifs '; then
    warn "An active CIFS mount is present. It will be left untouched."
  fi

  if systemctl is-active --quiet docker 2>/dev/null; then
    log "Docker is already running; installer will not restart it"
  fi

  if systemctl is-active --quiet k3s 2>/dev/null; then
    log "K3s is already running; installer will not restart it"
  fi

  if [ "$IS_RPI" = "1" ]; then
    if ! grep -qw cgroup_memory /proc/cmdline 2>/dev/null || ! grep -qw cgroup_enable=memory /proc/cmdline 2>/dev/null; then
      warn "Raspberry Pi memory cgroup flags are not active. K3s may fail without them."
      warn "This installer will not edit boot files automatically. Add cgroup_memory=1 cgroup_enable=memory and reboot if K3s fails."
    fi
  fi
}

install_base_os_packages() {
  log "updating apt package index; this may take a few minutes on a fresh host"
  run_apt_get update

  log "installing base OS packages required for repository sync and optional runner setup with apt-get"
  run_apt_get install -y --no-install-recommends ca-certificates curl git tar gzip sudo python3 openssl
  log "base OS package installation completed"
}

run_preflight_and_prepare_cluster() {
  _preflight_require_root

  detect_host_environment
  validate_k8s_topology_settings

  log "detected OS/arch: $OS_NAME / $ARCH_RAW"

  if [ "$IS_RPI" = "1" ]; then
    log "detected Raspberry Pi hardware"
  fi

  is_debian_family || fatal "this installer currently supports Debian-family systems only. Detected: ${OS_NAME:-unknown}"

  check_noninvasive_host_state
  save_network_firewall_snapshots
  check_basic_network_for_install
  install_base_os_packages
}

install_k3s_server_if_missing() {
  if ! cmd_exists k3s; then
    log "installing K3s server on this server/control-plane; this may take a few minutes"

    local k3s_exec_args="server --write-kubeconfig-mode 644"

    # SCH-aligned default: do not use K3s Klipper/serviceLB. Keep Traefik unless explicitly disabled elsewhere.
    if [ "${K3S_DISABLE_SERVICELB:-1}" = "1" ]; then
      k3s_exec_args="$k3s_exec_args --disable servicelb"
    fi

    if [ "${K3S_DISABLE_TRAEFIK:-0}" = "1" ]; then
      k3s_exec_args="$k3s_exec_args --disable traefik"
    fi

    log "K3s install args: $k3s_exec_args"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$k3s_exec_args" sh -
    log "K3s server installation completed"
  else
    log "K3s already installed; no reinstall performed"
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

print_k3s_diagnostics() {
  warn "collecting K3s diagnostics"
  k3s kubectl get nodes -o wide 2>/dev/null || true
  k3s kubectl get pods -A -o wide 2>/dev/null || true
  systemctl status k3s --no-pager -l 2>/dev/null || true
  journalctl -u k3s -n 120 --no-pager 2>/dev/null || true
}

wait_for_kubernetes_ready() {
  log "waiting for Kubernetes node readiness; timeout approximately 120s"

  local i
  for i in $(seq 1 60); do
    if k3s kubectl get nodes >/dev/null 2>&1 && k3s kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
      log "Kubernetes nodes are Ready"
      return 0
    fi

    if [ $((i % 15)) -eq 0 ]; then
      log "still waiting for Kubernetes node readiness after $((i * 2))s"
      k3s kubectl get nodes -o wide 2>/dev/null || true
    fi

    sleep 2
  done

  print_k3s_diagnostics
  fatal "K3s node did not become Ready"
}

install_kubernetes_tooling_and_k3s() {
  _preflight_require_root

  log "installing Kubernetes/deployment OS packages with apt-get"
  run_apt_get install -y --no-install-recommends iproute2 iptables nftables python3-venv jq nodejs npm
  log "Kubernetes/deployment OS package installation completed"

  if requires_docker; then
    log "Docker is required for DEPLOY_MODE=$DEPLOY_MODE; checking Docker installation"
    ensure_docker
    log "Docker check/install completed"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require Docker image build; skipping Docker check/install"
  fi

  install_k3s_server_if_missing
  wait_for_kubernetes_ready

  log "cluster nodes"
  k3s kubectl get nodes -o wide

  log "cluster storage classes"
  k3s kubectl get storageclass 2>/dev/null || true

  log "validating configured app node selector"
  validate_selected_node "$APP_NODE_SELECTOR_KEY" "$APP_NODE_SELECTOR_VALUE" "app"

  log "validating configured monitor node selector"
  validate_selected_node "$MONITOR_NODE_SELECTOR_KEY" "$MONITOR_NODE_SELECTOR_VALUE" "monitor"

  log "validating configured Redis node selector"
  validate_selected_node "$REDIS_NODE_SELECTOR_KEY" "$REDIS_NODE_SELECTOR_VALUE" "redis"

  log "checking/installing MetalLB if requested"
  install_metallb_if_requested

  log "checking LoadBalancer prerequisites"
  check_loadbalancer_prereqs

  log "Kubernetes tooling and K3s preparation completed"
}
