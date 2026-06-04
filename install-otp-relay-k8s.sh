#!/usr/bin/env bash
set -Eeuo pipefail

# Thin launcher for the modular OTP Relay Kubernetes installer.
# All site-specific input is loaded from .env through scripts/lib/env.sh.
#
# Current architecture:
#   - This script runs on the server/control-plane.
#   - Worker VMs are joined separately by Ansible.
#   - NFS is external and is consumed through Kubernetes PV/PVC.
#   - frontend/app.jsx is source.
#   - frontend/app.js is generated during deployment and must exist before image build.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_CURRENT_PHASE="startup"

INSTALLER_LIBS=(
  common.sh
  env.sh
  os.sh
  github-runner.sh
  docker.sh
  deploy-mode.sh
  k3s.sh
  metallb.sh
  tls.sh
  manifests.sh
  observability.sh
  images.sh
  preflight.sh
  repo-sync.sh
  build-stage.sh
  apply-deploy.sh
  summary.sh
)

_bootstrap_log() { printf '[otp-relay-k8s] %s\n' "$*"; }
_bootstrap_warn() { printf '[otp-relay-k8s] WARNING: %s\n' "$*" >&2; }
_bootstrap_fatal() { printf '[otp-relay-k8s] ERROR: %s\n' "$*" >&2; exit 1; }

validate_launcher_layout() {
  [ -d "$SCRIPT_DIR/scripts/lib" ] || _bootstrap_fatal "missing installer library directory: $SCRIPT_DIR/scripts/lib"

  for installer_lib in "${INSTALLER_LIBS[@]}"; do
    installer_lib_path="$SCRIPT_DIR/scripts/lib/$installer_lib"

    [ -f "$installer_lib_path" ] || _bootstrap_fatal "missing installer library: $installer_lib_path"
    bash -n "$installer_lib_path" >/dev/null 2>&1 || _bootstrap_fatal "installer library has shell syntax errors: $installer_lib_path"
  done
}

source_installer_libraries() {
  local installer_lib installer_lib_path

  for installer_lib in "${INSTALLER_LIBS[@]}"; do
    installer_lib_path="$SCRIPT_DIR/scripts/lib/$installer_lib"
    # shellcheck disable=SC1090
    . "$installer_lib_path"
  done
}

require_installer_functions() {
  local fn
  local required_functions=(
    need_root
    log
    warn
    fatal
    load_or_create_env
    normalize_loaded_env
    detect_host_environment
    prompt_optional_runner_setup
    run_preflight_and_prepare_cluster
    install_github_runner
    install_kubernetes_tooling_and_k3s
    sync_deployment_repo
    validate_source_tree
    build_app_assets_if_required
    stage_and_validate_manifests
    apply_secret_if_required
    build_and_import_images_if_required
    apply_kubernetes_resources_if_required
    copy_runtime_data_if_requested
    check_working_tree_cleanliness
    print_deployment_summary
  )

  for fn in "${required_functions[@]}"; do
    declare -F "$fn" >/dev/null 2>&1 || _bootstrap_fatal "required installer function is missing after loading libraries: $fn"
  done
}

print_failure_context() {
  _bootstrap_warn "failure phase: ${INSTALLER_CURRENT_PHASE:-unknown}"
  _bootstrap_warn "script directory: $SCRIPT_DIR"
  _bootstrap_warn "env file: ${ENV_FILE:-$SCRIPT_DIR/.env}"
  _bootstrap_warn "deploy mode: ${DEPLOY_MODE:-unknown}"
  _bootstrap_warn "namespace: ${NAMESPACE:-otp-relay}"

  if command -v k3s >/dev/null 2>&1; then
    _bootstrap_warn "K3s appears installed; collecting brief cluster context"
    k3s kubectl get nodes -o wide 2>/dev/null || true
    k3s kubectl get pods -n "${NAMESPACE:-otp-relay}" -o wide 2>/dev/null || true
    k3s kubectl get pvc -n "${NAMESPACE:-otp-relay}" 2>/dev/null || true
    k3s kubectl get events -n "${NAMESPACE:-otp-relay}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 25 || true
  fi
}

on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"

  printf '[otp-relay-k8s] ERROR: installer failed during phase "%s" at line %s with exit code %s\n' \
    "${INSTALLER_CURRENT_PHASE:-unknown}" "$line_no" "$exit_code" >&2
  print_failure_context
  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

run_phase() {
  local phase_name="$1"
  shift

  INSTALLER_CURRENT_PHASE="$phase_name"
  export INSTALLER_CURRENT_PHASE

  log "starting: $phase_name"
  "$@"
  log "completed: $phase_name"
}

main() {
  cd "$SCRIPT_DIR"

  validate_launcher_layout
  source_installer_libraries
  require_installer_functions

  need_root

  export DEBIAN_FRONTEND=noninteractive
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
  export SCRIPT_DIR

  log "starting OTP Relay Kubernetes installer"
  log "script directory: $SCRIPT_DIR"
  log "control-plane mode: server/localhost"
  log "noninteractive mode: ${NONINTERACTIVE:-0}"
  log "env file: ${ENV_FILE:-$SCRIPT_DIR/.env}"

  if [ -n "${INSTALLER_DEPLOY_MODE:-}" ]; then
    log "using installer deploy mode override: ${INSTALLER_DEPLOY_MODE}"
    DEPLOY_MODE="$INSTALLER_DEPLOY_MODE"
    export DEPLOY_MODE
  fi

  run_phase "load or create installer environment" load_or_create_env
  run_phase "validate deployment mode" validate_deploy_mode
  explain_deploy_mode

  run_phase "detect host environment" detect_host_environment
  run_phase "check optional GitHub runner setup" prompt_optional_runner_setup
  run_phase "run preflight checks and prepare cluster host" run_preflight_and_prepare_cluster
  run_phase "install or validate GitHub runner" install_github_runner

  if [ "${RUNNER_ONLY:-0}" = "1" ]; then
    log "RUNNER_ONLY=1 set; GitHub runner setup complete. Skipping Docker, K3s, image build, and deployment."
    exit 0
  fi

  if [ "$DEPLOY_MODE" = "none" ]; then
    log "DEPLOY_MODE=none; no deployment changes required. Exiting before Docker/K3s work."
    exit 0
  fi

  run_phase "install Kubernetes tooling and K3s" install_kubernetes_tooling_and_k3s
  run_phase "sync deployment repository" sync_deployment_repo
  run_phase "validate source tree" validate_source_tree
  run_phase "build app assets if required" build_app_assets_if_required
  run_phase "stage and validate Kubernetes manifests" stage_and_validate_manifests
  run_phase "apply secret if required" apply_secret_if_required
  run_phase "build and import container images if required" build_and_import_images_if_required
  run_phase "apply Kubernetes resources if required" apply_kubernetes_resources_if_required
  run_phase "copy runtime data if requested" copy_runtime_data_if_requested
  run_phase "check working tree cleanliness" check_working_tree_cleanliness
  run_phase "print deployment summary" print_deployment_summary

  INSTALLER_CURRENT_PHASE="completed"
  log "OTP Relay Kubernetes installer completed successfully"
}

main "$@"
