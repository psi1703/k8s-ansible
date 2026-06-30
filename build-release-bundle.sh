#!/usr/bin/env bash
set -Eeuo pipefail

# Thin launcher for the OTP Relay Kubernetes production release bundle builder.
# All site-specific input is loaded from .env through scripts/lib/env.sh.
#
# Bundle-only architecture:
#   - This script runs on the dev/build host.
#   - It produces a sealed release tarball under dist/.
#   - It does not deploy to any Kubernetes cluster.
#   - It does not install K3s, Helm, MetalLB, GitHub runners, or runtime tooling.
#   - It does not import images into a live cluster.
#   - It does not apply manifests.
#   - It does not restart deployments.
#
# Output:
#   dist/otp-relay-k8s-release-YYYYMMDD-HHMMSS-<gitsha>.tar.gz
#
# The production server receives only the finished bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_CURRENT_PHASE="startup"

INSTALLER_LIBS=(
  common.sh
  env.sh
  os.sh
  docker.sh
  deploy-mode.sh
  manifests.sh
  images.sh
  preflight.sh
  repo-sync.sh
  build-stage.sh
  summary.sh
)

_bootstrap_log() { printf '[otp-relay-k8s] %s\n' "$*"; }
_bootstrap_warn() { printf '[otp-relay-k8s] WARNING: %s\n' "$*" >&2; }
_bootstrap_fatal() { printf '[otp-relay-k8s] ERROR: %s\n' "$*" >&2; exit 1; }

validate_launcher_layout() {
  local installer_lib installer_lib_path

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

require_function() {
  local fn="$1"

  declare -F "$fn" >/dev/null 2>&1 || _bootstrap_fatal "required bundle-builder function is missing after loading libraries: $fn"
}

require_bundle_builder_functions() {
  local fn
  local required_functions=(
    need_root
    log
    warn
    fatal
    load_or_create_env
    normalize_loaded_env
    validate_deploy_mode
    explain_deploy_mode
    detect_host_environment
    sync_deployment_repo
    validate_source_tree
    build_app_assets_if_required
    stage_release_manifests_if_required
    export_release_images_if_required
    stage_release_bundle_if_required
    check_working_tree_cleanliness
    print_release_bundle_summary
  )

  for fn in "${required_functions[@]}"; do
    require_function "$fn"
  done
}

normalize_bundle_mode_inputs() {
  # DEPLOY_MODE is kept only as a packaging selector:
  #   full    -> package app + monitor runtime artifacts
  #   app     -> package app runtime artifacts
  #   monitor -> package monitor runtime artifacts
  #   none    -> validate environment only, no artifacts
  #
  # It no longer means "deploy".
  DEPLOY_MODE="${DEPLOY_MODE:-full}"
  export DEPLOY_MODE

  RELEASE_MODE="bundle"
  export RELEASE_MODE

  SKIP_CLUSTER_DEPLOY="1"
  SKIP_K3S_INSTALL="1"
  SKIP_HELM_INSTALL="1"
  SKIP_KUBECTL_APPLY="1"
  SKIP_IMAGE_IMPORT="1"
  SKIP_ROLLOUT_RESTART="1"

  export SKIP_CLUSTER_DEPLOY
  export SKIP_K3S_INSTALL
  export SKIP_HELM_INSTALL
  export SKIP_KUBECTL_APPLY
  export SKIP_IMAGE_IMPORT
  export SKIP_ROLLOUT_RESTART
}

print_bundle_mode_summary() {
  log "release mode: bundle-only"
  log "bundle behavior: build, render, export, checksum, and package final runtime artifacts"
  log "cluster behavior: disabled"
  log "K3s install/import/apply/rollout: disabled"
  log "deploy mode selector: ${DEPLOY_MODE:-full}"
}

print_failure_context() {
  _bootstrap_warn "failure phase: ${INSTALLER_CURRENT_PHASE:-unknown}"
  _bootstrap_warn "script directory: $SCRIPT_DIR"
  _bootstrap_warn "env file: ${ENV_FILE:-$SCRIPT_DIR/.env}"
  _bootstrap_warn "release mode: bundle-only"
  _bootstrap_warn "deploy mode selector: ${DEPLOY_MODE:-full}"
  _bootstrap_warn "namespace default: ${NAMESPACE:-otp-relay}"
  _bootstrap_warn "cluster diagnostics skipped because this builder must not deploy anywhere"
}

on_error() {
  local exit_code="$?"
  local line_no="${1:-unknown}"

  printf '[otp-relay-k8s] ERROR: bundle builder failed during phase "%s" at line %s with exit code %s\n' \
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
  normalize_bundle_mode_inputs
  require_bundle_builder_functions

  need_root

  export DEBIAN_FRONTEND=noninteractive
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
  export SCRIPT_DIR

  log "starting OTP Relay Kubernetes release bundle builder"
  log "script directory: $SCRIPT_DIR"
  log "noninteractive mode: ${NONINTERACTIVE:-0}"
  log "env file: ${ENV_FILE:-$SCRIPT_DIR/.env}"
  print_bundle_mode_summary

  if [ -n "${INSTALLER_DEPLOY_MODE:-}" ]; then
    log "using artifact selector override from INSTALLER_DEPLOY_MODE: ${INSTALLER_DEPLOY_MODE}"
    DEPLOY_MODE="$INSTALLER_DEPLOY_MODE"
    export DEPLOY_MODE
  fi

  run_phase "load or create installer environment" load_or_create_env
  normalize_bundle_mode_inputs
  run_phase "validate artifact selector" validate_deploy_mode
  explain_deploy_mode

  run_phase "detect host environment" detect_host_environment
  run_phase "sync source tree if configured" sync_deployment_repo
  run_phase "validate source tree" validate_source_tree
  run_phase "build app assets if required" build_app_assets_if_required
  run_phase "stage release manifests" stage_release_manifests_if_required
  run_phase "export release container images" export_release_images_if_required
  run_phase "stage release bundle" stage_release_bundle_if_required
  run_phase "check working tree cleanliness" check_working_tree_cleanliness
  run_phase "print release bundle summary" print_release_bundle_summary

  INSTALLER_CURRENT_PHASE="completed"
  log "OTP Relay Kubernetes release bundle completed successfully"
}

main "$@"
