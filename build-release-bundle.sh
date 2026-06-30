#!/usr/bin/env bash
# OTP Relay Kubernetes release bundle builder.
#
# Bundle-only contract:
#   - Build/stage release artifacts on the dev/build host.
#   - Render Kubernetes manifests into a staging directory.
#   - Build/export Docker image archives when requested by the artifact selector.
#   - Create a sealed production release tarball and checksum.
#   - Do not install K3s.
#   - Do not run kubectl apply.
#   - Do not run Helm install/upgrade.
#   - Do not import images into a live cluster.
#   - Do not restart deployments.
#   - Do not install GitHub runners.
#   - Do not provision VMs.
#   - Do not validate a live cluster.
#
# The production server receives only the finished bundle.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_CURRENT_PHASE="startup"

# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/scripts/lib/env.sh"
# shellcheck source=scripts/lib/os.sh
. "$SCRIPT_DIR/scripts/lib/os.sh"
# shellcheck source=scripts/lib/docker.sh
. "$SCRIPT_DIR/scripts/lib/docker.sh"
# shellcheck source=scripts/lib/deploy-mode.sh
. "$SCRIPT_DIR/scripts/lib/deploy-mode.sh"
# shellcheck source=scripts/lib/manifests.sh
. "$SCRIPT_DIR/scripts/lib/manifests.sh"
# shellcheck source=scripts/lib/images.sh
. "$SCRIPT_DIR/scripts/lib/images.sh"
# shellcheck source=scripts/lib/preflight.sh
. "$SCRIPT_DIR/scripts/lib/preflight.sh"
# shellcheck source=scripts/lib/repo-sync.sh
. "$SCRIPT_DIR/scripts/lib/repo-sync.sh"
# shellcheck source=scripts/lib/build-stage.sh
. "$SCRIPT_DIR/scripts/lib/build-stage.sh"
# shellcheck source=scripts/lib/release-bundle.sh
. "$SCRIPT_DIR/scripts/lib/release-bundle.sh"
# shellcheck source=scripts/lib/summary.sh
. "$SCRIPT_DIR/scripts/lib/summary.sh"

normalize_bundle_mode_inputs() {
  RELEASE_MODE="bundle"

  SKIP_CLUSTER_DEPLOY="1"
  SKIP_K3S_INSTALL="1"
  SKIP_HELM_INSTALL="1"
  SKIP_KUBECTL_APPLY="1"
  SKIP_IMAGE_IMPORT="1"
  SKIP_ROLLOUT_RESTART="1"
  SKIP_LIVE_CLUSTER_VALIDATE="1"
  SKIP_GITHUB_RUNNER_INSTALL="1"
  SKIP_VM_PROVISIONING="1"

  DEPLOY_OTP_RELAY="0"
  VALIDATE_OTP_RELAY="0"
  INSTALL_GITHUB_RUNNER="0"
  RUNNER_ONLY="0"
  DISTRIBUTE_IMAGES_TO_NODES="0"

  DEPLOY_MODE="${DEPLOY_MODE:-full}"

  export RELEASE_MODE
  export SKIP_CLUSTER_DEPLOY
  export SKIP_K3S_INSTALL
  export SKIP_HELM_INSTALL
  export SKIP_KUBECTL_APPLY
  export SKIP_IMAGE_IMPORT
  export SKIP_ROLLOUT_RESTART
  export SKIP_LIVE_CLUSTER_VALIDATE
  export SKIP_GITHUB_RUNNER_INSTALL
  export SKIP_VM_PROVISIONING
  export DEPLOY_OTP_RELAY
  export VALIDATE_OTP_RELAY
  export INSTALL_GITHUB_RUNNER
  export RUNNER_ONLY
  export DISTRIBUTE_IMAGES_TO_NODES
  export DEPLOY_MODE
}

assert_bundle_only_runtime_contract() {
  [ "${RELEASE_MODE:-bundle}" = "bundle" ] || fatal "RELEASE_MODE must be bundle"

  [ "${SKIP_CLUSTER_DEPLOY:-1}" = "1" ] || fatal "SKIP_CLUSTER_DEPLOY must remain 1"
  [ "${SKIP_K3S_INSTALL:-1}" = "1" ] || fatal "SKIP_K3S_INSTALL must remain 1"
  [ "${SKIP_HELM_INSTALL:-1}" = "1" ] || fatal "SKIP_HELM_INSTALL must remain 1"
  [ "${SKIP_KUBECTL_APPLY:-1}" = "1" ] || fatal "SKIP_KUBECTL_APPLY must remain 1"
  [ "${SKIP_IMAGE_IMPORT:-1}" = "1" ] || fatal "SKIP_IMAGE_IMPORT must remain 1"
  [ "${SKIP_ROLLOUT_RESTART:-1}" = "1" ] || fatal "SKIP_ROLLOUT_RESTART must remain 1"
  [ "${SKIP_LIVE_CLUSTER_VALIDATE:-1}" = "1" ] || fatal "SKIP_LIVE_CLUSTER_VALIDATE must remain 1"
  [ "${SKIP_GITHUB_RUNNER_INSTALL:-1}" = "1" ] || fatal "SKIP_GITHUB_RUNNER_INSTALL must remain 1"
  [ "${SKIP_VM_PROVISIONING:-1}" = "1" ] || fatal "SKIP_VM_PROVISIONING must remain 1"

  [ "${DEPLOY_OTP_RELAY:-0}" = "0" ] || fatal "DEPLOY_OTP_RELAY must remain 0"
  [ "${VALIDATE_OTP_RELAY:-0}" = "0" ] || fatal "VALIDATE_OTP_RELAY must remain 0"
  [ "${INSTALL_GITHUB_RUNNER:-0}" = "0" ] || fatal "INSTALL_GITHUB_RUNNER must remain 0"
  [ "${RUNNER_ONLY:-0}" = "0" ] || fatal "RUNNER_ONLY must remain 0"
  [ "${DISTRIBUTE_IMAGES_TO_NODES:-0}" = "0" ] || fatal "DISTRIBUTE_IMAGES_TO_NODES must remain 0"
}

run_phase() {
  local phase_name="$1"
  shift

  INSTALLER_CURRENT_PHASE="$phase_name"
  export INSTALLER_CURRENT_PHASE

  assert_bundle_only_runtime_contract
  log "phase start: $phase_name"

  "$@"

  normalize_bundle_mode_inputs
  assert_bundle_only_runtime_contract
  log "phase complete: $phase_name"
}

usage() {
  cat <<EOF_USAGE
Usage:
  bash build-release-bundle.sh [options]

Options:
  --mode MODE              Artifact selector: full, app, monitor, none
  --env-file PATH          Environment file to load/create
  --skip-repo-sync VALUE   auto, 1, or 0
  --git-clean VALUE        1 or 0
  --noninteractive         Do not prompt; use env/.env/defaults
  --dist-dir PATH          Output directory for final release tarball
  -h, --help               Show this help

Bundle-only contract:
  This command creates a sealed release bundle only.
  It does not deploy, install K3s, run Helm, run kubectl apply,
  import images, provision VMs, install runners, or validate a live cluster.
EOF_USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        shift
        [ "$#" -gt 0 ] || fatal "--mode requires a value"
        DEPLOY_MODE="$1"
        export DEPLOY_MODE
        ;;
      --mode=*)
        DEPLOY_MODE="${1#*=}"
        export DEPLOY_MODE
        ;;
      --env-file)
        shift
        [ "$#" -gt 0 ] || fatal "--env-file requires a value"
        ENV_FILE="$1"
        export ENV_FILE
        ;;
      --env-file=*)
        ENV_FILE="${1#*=}"
        export ENV_FILE
        ;;
      --skip-repo-sync)
        shift
        [ "$#" -gt 0 ] || fatal "--skip-repo-sync requires a value"
        SKIP_REPO_SYNC="$1"
        export SKIP_REPO_SYNC
        ;;
      --skip-repo-sync=*)
        SKIP_REPO_SYNC="${1#*=}"
        export SKIP_REPO_SYNC
        ;;
      --git-clean)
        shift
        [ "$#" -gt 0 ] || fatal "--git-clean requires a value"
        GIT_CLEAN="$1"
        export GIT_CLEAN
        ;;
      --git-clean=*)
        GIT_CLEAN="${1#*=}"
        export GIT_CLEAN
        ;;
      --noninteractive)
        NONINTERACTIVE="1"
        export NONINTERACTIVE
        ;;
      --dist-dir)
        shift
        [ "$#" -gt 0 ] || fatal "--dist-dir requires a value"
        DIST_DIR="$1"
        export DIST_DIR
        ;;
      --dist-dir=*)
        DIST_DIR="${1#*=}"
        export DIST_DIR
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --local|--reprovision-vms|--no-ansible|--ansible|--deploy|--validate|--install-k3s|--install-runner|--runner-only|--provision-vms)
        fatal "unsupported old deployment option in bundle-only builder: $1"
        ;;
      *)
        fatal "unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  normalize_bundle_mode_inputs
  assert_bundle_only_runtime_contract

  log "OTP Relay Kubernetes bundle-only release builder starting"
  log "script directory: $SCRIPT_DIR"
  log "production server receives only the finished bundle"

  run_phase "load environment" load_or_create_env
  run_phase "validate artifact selector" validate_deploy_mode
  run_phase "explain artifact selector" explain_deploy_mode
  run_phase "detect build host" detect_host_environment
  run_phase "bundle preflight" validate_bundle_preflight_only
  run_phase "prepare source repository" sync_deployment_repo

  log "active release source directory: $(pwd)"

  run_phase "validate source tree" validate_source_tree
  run_phase "build app assets" build_app_assets_if_required
  run_phase "stage and validate manifests" stage_and_validate_manifests
  run_phase "export image archives" export_release_images_if_required
  run_phase "create sealed release bundle" stage_release_bundle_if_required
  run_phase "check working tree cleanliness" check_working_tree_cleanliness
  run_phase "print release summary" print_release_bundle_summary

  log "bundle-only release build completed"
}

main "$@"
