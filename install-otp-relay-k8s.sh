#!/usr/bin/env bash
set -Eeuo pipefail

# Thin launcher for the modular OTP Relay Kubernetes installer.
# All site-specific input is loaded from .env through scripts/lib/env.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for installer_lib in \
  common.sh \
  env.sh \
  os.sh \
  github-runner.sh \
  docker.sh \
  deploy-mode.sh \
  k3s.sh \
  metallb.sh \
  tls.sh \
  manifests.sh \
  observability.sh \
  images.sh \
  preflight.sh \
  repo-sync.sh \
  build-stage.sh \
  apply-deploy.sh \
  summary.sh; do
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/scripts/lib/$installer_lib"
done

run_phase() {
  local phase_name="$1"
  shift

  log "starting: $phase_name"
  "$@"
  log "completed: $phase_name"
}

main() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

  log "starting OTP Relay Kubernetes installer"
  log "script directory: $SCRIPT_DIR"
  log "noninteractive mode: ${NONINTERACTIVE:-0}"
  log "env file: ${ENV_FILE:-$SCRIPT_DIR/.env}"

  run_phase "load or create installer environment" load_or_create_env
  run_phase "normalize installer environment" normalize_loaded_env
  run_phase "detect host environment" detect_host_environment
  run_phase "check optional GitHub runner setup" prompt_optional_runner_setup
  run_phase "run preflight checks and prepare cluster host" run_preflight_and_prepare_cluster
  run_phase "install or validate GitHub runner" install_github_runner

  if [ "$RUNNER_ONLY" = "1" ]; then
    log "RUNNER_ONLY=1 set; GitHub runner setup complete. Skipping Docker, K3s, image build, and deployment."
    exit 0
  fi

  case "$DEPLOY_MODE" in
    full|app|monitor|manifests|none) ;;
    *) fatal "unsupported DEPLOY_MODE=$DEPLOY_MODE. Use full, app, monitor, manifests, or none." ;;
  esac
  log "deployment mode: $DEPLOY_MODE"

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

  log "OTP Relay Kubernetes installer completed successfully"
}

main "$@"
