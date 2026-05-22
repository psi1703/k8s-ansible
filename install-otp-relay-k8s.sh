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

main() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

  load_or_create_env
  normalize_loaded_env
  detect_host_environment
  prompt_optional_runner_setup
  run_preflight_and_prepare_cluster
  install_github_runner

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
}

main "$@"
