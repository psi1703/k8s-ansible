#!/usr/bin/env bash
# Host detection, preflight, package install, and K3s readiness.

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

  log "detected OS/arch: $OS_NAME / $ARCH_RAW"

  if [ "$IS_RPI" = "1" ]; then
    log "detected Raspberry Pi hardware"
  fi

  return 0
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

run_preflight_and_prepare_cluster() {
  validate_k8s_topology_settings

  log "detected OS/arch: $OS_NAME / $ARCH_RAW"

  if [ "$IS_RPI" = "1" ]; then
    log "detected Raspberry Pi hardware"
  fi

  is_debian_family || fatal "this installer currently supports Debian-family systems only"

  log "running non-invasive preflight checks"

  if ! ss -lnt 2>/dev/null | grep -qE '(^|[[:space:]]|:)22[[:space:]]'; then
    warn "SSH does not appear to be listening on TCP/22. I will not change SSH, but confirm console access before continuing."
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

  log "saving network/firewall state snapshots under /var/backups/otp-relay-k8s"
  mkdir -p /var/backups/otp-relay-k8s
  ip route > /var/backups/otp-relay-k8s/ip-route.before 2>/dev/null || true
  ip addr > /var/backups/otp-relay-k8s/ip-addr.before 2>/dev/null || true
  iptables-save > /var/backups/otp-relay-k8s/iptables.before 2>/dev/null || true
  nft list ruleset > /var/backups/otp-relay-k8s/nft.before 2>/dev/null || true
  log "network/firewall state snapshots saved"

  if [ "$IS_RPI" = "1" ]; then
    if ! grep -qw cgroup_memory /proc/cmdline 2>/dev/null || ! grep -qw cgroup_enable=memory /proc/cmdline 2>/dev/null; then
      warn "Raspberry Pi memory cgroup flags are not active. K3s may fail without them."
      warn "This installer will not edit boot files automatically. Add cgroup_memory=1 cgroup_enable=memory and reboot if K3s fails."
    fi
  fi

  log "updating apt package index; this may take a few minutes on a fresh host"
  apt-get update

  log "installing base OS packages required for repository sync and optional runner setup with apt-get"
  apt-get install -y --no-install-recommends ca-certificates curl git tar gzip sudo python3 openssl
  log "base OS package installation completed"
}

install_kubernetes_tooling_and_k3s() {
  log "installing Kubernetes/deployment OS packages with apt-get"
  apt-get install -y --no-install-recommends iproute2 iptables nftables python3-venv jq nodejs npm
  log "Kubernetes/deployment OS package installation completed"

  if requires_docker; then
    log "Docker is required for DEPLOY_MODE=$DEPLOY_MODE; checking Docker installation"
    ensure_docker
    log "Docker check/install completed"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require Docker image build; skipping Docker check/install"
  fi

  if ! cmd_exists k3s; then
    log "installing K3s server on this server/control-plane; this may take a few minutes"

    K3S_EXEC_ARGS="server --write-kubeconfig-mode 644"

    # SCH-aligned default: do not use K3s Klipper/serviceLB. Keep Traefik unless explicitly disabled elsewhere.
    if [ "${K3S_DISABLE_SERVICELB:-1}" = "1" ]; then
      K3S_EXEC_ARGS="$K3S_EXEC_ARGS --disable servicelb"
    fi

    if [ "${K3S_DISABLE_TRAEFIK:-0}" = "1" ]; then
      K3S_EXEC_ARGS="$K3S_EXEC_ARGS --disable traefik"
    fi

    log "K3s install args: $K3S_EXEC_ARGS"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$K3S_EXEC_ARGS" sh -
    log "K3s server installation completed"
  else
    log "K3s already installed; no reinstall performed"
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "waiting for Kubernetes node readiness; timeout approximately 120s"
  for i in $(seq 1 60); do
    if k3s kubectl get nodes >/dev/null 2>&1 && k3s kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
      log "Kubernetes nodes are Ready"
      break
    fi

    if [ $((i % 15)) -eq 0 ]; then
      log "still waiting for Kubernetes node readiness after $((i * 2))s"
      k3s kubectl get nodes -o wide 2>/dev/null || true
    fi

    sleep 2

    if [ "$i" -ge 60 ]; then
      fatal "K3s node did not become Ready"
    fi
  done

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
