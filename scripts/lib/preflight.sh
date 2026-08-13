#!/usr/bin/env bash
# Host detection and bundle-builder preflight checks.
# Source this file from build-release-bundle.sh; do not execute it directly.
#
# Bundle-only policy:
#   - Detect the dev/build host environment.
#   - Check for required local build tools.
#   - Print all missing dependencies at once.
#   - Optionally install build-host dependencies only.
#   - Do not install K3s.
#   - Do not wait for Kubernetes readiness.
#   - Do not query Kubernetes nodes, storage classes, PVCs, or pods.
#   - Do not configure MetalLB, firewall, networking, production, or runners.
#
# INSTALL_BUILD_DEPS behavior:
#   - auto/default: ask in interactive terminal, fail in non-interactive terminal
#   - 1/yes/true: install missing build dependencies automatically
#   - 0/no/false: never install; only print guidance and fail
#
# The production server receives only the finished bundle.

OS_ID="${OS_ID:-unknown}"
OS_NAME="${OS_NAME:-unknown}"
OS_VERSION_ID="${OS_VERSION_ID:-unknown}"
OS_LIKE="${OS_LIKE:-}"
ARCH_RAW="${ARCH_RAW:-}"
RUNNER_ARCH="${RUNNER_ARCH:-}"
IS_RPI="${IS_RPI:-0}"
BUILD_DEPS_INSTALLED="${BUILD_DEPS_INSTALLED:-0}"

_preflight_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

_preflight_require_root() {
  fatal "root is not required and is not requested by the bundle-only preflight path"
}

_preflight_retry() {
  local attempts="${1:-3}"
  local delay="${2:-5}"
  local i=1

  shift 2
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
  local lock_paths="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock"
  local waited=0
  local max_wait="${APT_LOCK_WAIT_SEC:-300}"
  local lock_path=""

  if ! _preflight_cmd_exists fuser; then
    log "fuser is unavailable; skipping apt lock wait"
    return 0
  fi

  while [ "$waited" -lt "$max_wait" ]; do
    local locked=0
    for lock_path in $lock_paths; do
      if [ -e "$lock_path" ] && sudo fuser "$lock_path" >/dev/null 2>&1; then
        locked=1
        break
      fi
    done

    if [ "$locked" = "0" ]; then
      return 0
    fi

    warn "apt/dpkg lock is busy; waiting 5s"
    sleep 5
    waited=$((waited + 5))
  done

  fatal "timed out waiting for apt/dpkg locks"
}

run_apt_get() {
  if [ "$#" -eq 0 ]; then
    fatal "run_apt_get called without arguments"
  fi

  if ! is_debian_family; then
    fatal "apt-get install is supported only on Debian-family build hosts"
  fi

  if ! _preflight_cmd_exists sudo; then
    fatal "sudo is required to install build dependencies automatically"
  fi

  _wait_for_apt_locks
  sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_host_environment() {
  log "detecting build host OS, architecture, and hardware profile"

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
  if grep -qi 'raspberry pi' /proc/cpuinfo 2>/dev/null || \
    grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
    IS_RPI=1
  fi

  export OS_ID OS_NAME OS_VERSION_ID OS_LIKE ARCH_RAW RUNNER_ARCH IS_RPI

  log "detected build host OS/arch: $OS_NAME / $ARCH_RAW"
  if [ "$IS_RPI" = "1" ]; then
    log "detected Raspberry Pi hardware"
  fi

  check_bundle_builder_tools
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
  INSTALL_GITHUB_RUNNER=0
  export INSTALL_GITHUB_RUNNER
  log "GitHub runner setup disabled in bundle-only mode"
}

save_network_firewall_snapshots() {
  log "skipping network/firewall snapshots in bundle-only mode"
}

check_basic_network_for_install() {
  log "skipping package/K3s network checks in bundle-only mode"
}

check_noninvasive_host_state() {
  log "running non-invasive build-host checks"

  if systemctl is-active --quiet docker 2>/dev/null; then
    log "Docker is running on build host"
  else
    if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
      warn "Docker service is not running or systemctl is unavailable; image archive export requires a working Docker daemon"
    else
      log "Docker service is not required for DEPLOY_MODE=${DEPLOY_MODE:-full}"
    fi
  fi

  if systemctl is-active --quiet k3s 2>/dev/null; then
    warn "K3s appears to be running on this host, but the bundle builder will not use it"
  fi

  if _preflight_cmd_exists kubectl; then
    warn "kubectl exists on this host, but the bundle builder will not use it"
  fi

  if _preflight_cmd_exists helm; then
    warn "helm exists on this host, but the bundle builder will not run helm install/upgrade"
  fi

  if [ "$IS_RPI" = "1" ]; then
    warn "build host is Raspberry Pi hardware; image builds may be slower"
  fi
}

repo_sync_or_cleanliness_needs_git() {
  if [ "${SKIP_REPO_SYNC:-auto}" != "1" ]; then
    return 0
  fi

  if [ "${GIT_CLEAN:-1}" = "1" ]; then
    return 0
  fi

  return 1
}

_preflight_append_missing() {
  local current_value="$1"
  local item="$2"

  if [ -z "$current_value" ]; then
    printf '%s' "$item"
  else
    printf '%s\n%s' "$current_value" "$item"
  fi
}

_preflight_print_missing_list() {
  local title="$1"
  local values="$2"

  if [ -z "$values" ]; then
    return 0
  fi

  warn "$title"
  printf '%s\n' "$values" | sed '/^$/d; s/^/  - /' >&2
}

_preflight_apt_packages_for_mode() {
  local packages="git python3 python3-venv tar gzip coreutils findutils grep sed gawk"

  if requires_app_image 2>/dev/null; then
    packages="$packages nodejs npm"
  fi

  if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
    packages="$packages docker.io"
  fi

  printf '%s' "$packages"
}

_preflight_print_install_guidance() {
  local apt_packages="$1"

  if is_debian_family; then
    cat >&2 <<EOF_DEPS

[otp-relay-k8s] Install missing build dependencies on this Debian-family build host with:

  sudo apt-get update
  sudo apt-get install -y $apt_packages

If Docker was newly installed or your user was newly added to the docker group, run:

  sudo systemctl enable --now docker
  sudo usermod -aG docker $(id -un)

Then log out and log back in, or run:

  newgrp docker

Then retry:

  bash build-release-bundle.sh --mode ${DEPLOY_MODE:-full}

EOF_DEPS
  else
    cat >&2 <<EOF_DEPS

[otp-relay-k8s] Missing local build dependencies were detected.
This host is not detected as Debian-family, so install equivalent packages for:

  $apt_packages

Then retry:

  bash build-release-bundle.sh --mode ${DEPLOY_MODE:-full}

EOF_DEPS
  fi
}

_preflight_validate_python_venv() {
  python3 - <<'PY_VENV_CHECK' >/dev/null 2>&1
import ensurepip
import venv
PY_VENV_CHECK
}

_preflight_validate_docker_ready() {
  if ! _preflight_cmd_exists docker; then
    return 1
  fi

  docker info >/dev/null 2>&1
}

_preflight_install_mode() {
  case "${INSTALL_BUILD_DEPS:-auto}" in
    1|yes|YES|true|TRUE|on|ON) printf 'yes' ;;
    0|no|NO|false|FALSE|off|OFF) printf 'no' ;;
    auto|AUTO|"") printf 'auto' ;;
    *) fatal "invalid INSTALL_BUILD_DEPS value: ${INSTALL_BUILD_DEPS}. Use auto, 1, or 0" ;;
  esac
}

_preflight_can_prompt() {
  [ -t 0 ] && [ -t 1 ]
}

_preflight_confirm_install() {
  local answer=""

  if ! _preflight_can_prompt; then
    return 1
  fi

  printf '[otp-relay-k8s] Install missing build dependencies now with apt-get? [Y/n]: ' >&2
  read -r answer || return 1

  case "$answer" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_preflight_install_build_deps() {
  local apt_packages="$1"

  if ! is_debian_family; then
    fatal "automatic build dependency installation is supported only on Debian-family hosts"
  fi

  if ! _preflight_cmd_exists sudo; then
    fatal "sudo is required for automatic build dependency installation"
  fi

  log "installing missing build dependencies on dev/build host"
  run_apt_get update
  run_apt_get install -y $apt_packages

  if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
    if _preflight_cmd_exists systemctl; then
      sudo systemctl enable --now docker || warn "could not enable/start docker with systemctl"
    fi

    if _preflight_cmd_exists usermod; then
      sudo usermod -aG docker "$(id -un)" || warn "could not add user $(id -un) to docker group"
    fi
  fi

  BUILD_DEPS_INSTALLED=1
  export BUILD_DEPS_INSTALLED
}

_preflight_handle_missing_deps() {
  local missing_tools="$1"
  local missing_features="$2"
  local apt_packages="$3"
  local install_mode=""

  _preflight_print_missing_list "missing required command-line tools:" "$missing_tools"
  _preflight_print_missing_list "missing required build features/services:" "$missing_features"
  _preflight_print_install_guidance "$apt_packages"

  install_mode="$(_preflight_install_mode)"

  case "$install_mode" in
    yes)
      _preflight_install_build_deps "$apt_packages"
      return 0
      ;;
    no)
      fatal "required local build dependencies are missing for DEPLOY_MODE=${DEPLOY_MODE:-full}"
      ;;
    auto)
      if _preflight_confirm_install; then
        _preflight_install_build_deps "$apt_packages"
        return 0
      fi
      fatal "required local build dependencies are missing for DEPLOY_MODE=${DEPLOY_MODE:-full}"
      ;;
  esac
}

check_bundle_builder_tools() {
  local missing_tools=""
  local missing_features=""
  local apt_packages=""

  log "checking required local build tools"

  if ! _preflight_cmd_exists bash; then missing_tools="$(_preflight_append_missing "$missing_tools" bash)"; fi
  if ! _preflight_cmd_exists date; then missing_tools="$(_preflight_append_missing "$missing_tools" date)"; fi
  if ! _preflight_cmd_exists find; then missing_tools="$(_preflight_append_missing "$missing_tools" find)"; fi
  if ! _preflight_cmd_exists grep; then missing_tools="$(_preflight_append_missing "$missing_tools" grep)"; fi
  if ! _preflight_cmd_exists sed; then missing_tools="$(_preflight_append_missing "$missing_tools" sed)"; fi
  if ! _preflight_cmd_exists awk; then missing_tools="$(_preflight_append_missing "$missing_tools" awk)"; fi
  if ! _preflight_cmd_exists sort; then missing_tools="$(_preflight_append_missing "$missing_tools" sort)"; fi
  if ! _preflight_cmd_exists tar; then missing_tools="$(_preflight_append_missing "$missing_tools" tar)"; fi
  if ! _preflight_cmd_exists gzip; then missing_tools="$(_preflight_append_missing "$missing_tools" gzip)"; fi
  if ! _preflight_cmd_exists sha256sum; then missing_tools="$(_preflight_append_missing "$missing_tools" sha256sum)"; fi
  if ! _preflight_cmd_exists python3; then missing_tools="$(_preflight_append_missing "$missing_tools" python3)"; fi

  if repo_sync_or_cleanliness_needs_git; then
    if ! _preflight_cmd_exists git; then missing_tools="$(_preflight_append_missing "$missing_tools" git)"; fi
  else
    log "git is not required because SKIP_REPO_SYNC=1 and GIT_CLEAN=0"
  fi

  if requires_app_image 2>/dev/null; then
    if ! _preflight_cmd_exists node; then missing_tools="$(_preflight_append_missing "$missing_tools" node)"; fi
    if ! _preflight_cmd_exists npm; then missing_tools="$(_preflight_append_missing "$missing_tools" npm)"; fi
  fi

  if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
    if ! _preflight_cmd_exists docker; then missing_tools="$(_preflight_append_missing "$missing_tools" docker)"; fi
  else
    log "Docker CLI is not required for DEPLOY_MODE=${DEPLOY_MODE:-full}"
  fi

  if _preflight_cmd_exists python3; then
    if ! _preflight_validate_python_venv; then
      missing_features="$(_preflight_append_missing "$missing_features" "python3 venv support")"
    fi
  fi

  if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
    if _preflight_cmd_exists docker; then
      if ! _preflight_validate_docker_ready; then
        missing_features="$(_preflight_append_missing "$missing_features" "working Docker daemon access for user $(id -un)")"
      fi
    fi
  fi

  if [ -n "$missing_tools" ] || [ -n "$missing_features" ]; then
    apt_packages="$(_preflight_apt_packages_for_mode)"
    _preflight_handle_missing_deps "$missing_tools" "$missing_features" "$apt_packages"

    missing_tools=""
    missing_features=""

    if ! _preflight_cmd_exists python3; then missing_tools="$(_preflight_append_missing "$missing_tools" python3)"; fi
    if requires_app_image 2>/dev/null; then
      if ! _preflight_cmd_exists node; then missing_tools="$(_preflight_append_missing "$missing_tools" node)"; fi
      if ! _preflight_cmd_exists npm; then missing_tools="$(_preflight_append_missing "$missing_tools" npm)"; fi
    fi
    if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
      if ! _preflight_cmd_exists docker; then missing_tools="$(_preflight_append_missing "$missing_tools" docker)"; fi
    fi
    if _preflight_cmd_exists python3 && ! _preflight_validate_python_venv; then
      missing_features="$(_preflight_append_missing "$missing_features" "python3 venv support")"
    fi
    if requires_app_image 2>/dev/null || requires_monitor_image 2>/dev/null; then
      if _preflight_cmd_exists docker && ! _preflight_validate_docker_ready; then
        missing_features="$(_preflight_append_missing "$missing_features" "working Docker daemon access for user $(id -un)")"
      fi
    fi

    if [ -n "$missing_tools" ] || [ -n "$missing_features" ]; then
      _preflight_print_missing_list "still missing required command-line tools after install attempt:" "$missing_tools"
      _preflight_print_missing_list "still missing required build features/services after install attempt:" "$missing_features"
      if printf '%s\n' "$missing_features" | grep -q 'working Docker daemon access'; then
        warn "Docker may require a new login session after group membership changes"
        warn "run: newgrp docker"
        warn "or log out and log back in, then rerun the build"
      fi
      fatal "required local build dependencies are still missing for DEPLOY_MODE=${DEPLOY_MODE:-full}"
    fi
  fi

  log "required local build tool check completed"
}

install_base_os_packages() {
  log "checking/installing build-host dependencies for bundle-only mode"
  check_bundle_builder_tools
}

run_preflight_and_prepare_cluster() {
  fatal "run_preflight_and_prepare_cluster is forbidden; bundle-only mode must not prepare a cluster"
}

install_k3s_server_if_missing() {
  fatal "install_k3s_server_if_missing is forbidden in bundle-only mode"
}

print_k3s_diagnostics() {
  log "skipping K3s diagnostics in bundle-only mode"
}

wait_for_kubernetes_ready() {
  fatal "wait_for_kubernetes_ready is forbidden in bundle-only mode"
}

install_kubernetes_tooling_and_k3s() {
  fatal "install_kubernetes_tooling_and_k3s is forbidden in bundle-only mode"
}

validate_selected_node() {
  local selector_key="${1:-}"
  local selector_value="${2:-}"
  local label="${3:-node selector}"

  if [ -n "$selector_key" ] || [ -n "$selector_value" ]; then
    [ -n "$selector_key" ] || fatal "$label node selector value is set but key is empty"
    [ -n "$selector_value" ] || fatal "$label node selector key is set but value is empty"
    log "validated configured $label node selector syntax: $selector_key=$selector_value"
  else
    log "no $label node selector configured"
  fi
}

validate_bundle_preflight_only() {
  detect_host_environment

  if ! is_debian_family; then
    warn "build host is not detected as Debian-family: ${OS_NAME:-unknown}"
    warn "continuing because bundle creation is file/tool based"
  fi

  check_noninvasive_host_state
  check_bundle_builder_tools
}
