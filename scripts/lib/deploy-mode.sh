#!/usr/bin/env bash
# Shared artifact-selector helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Historical note:
#   DEPLOY_MODE is retained only for .env/backward compatibility.
#   In this project it no longer means "deploy".
#
# Supported DEPLOY_MODE values as bundle artifact selectors:
#   full    - build/export app and monitor image archives, render/package manifests
#   app     - build/export app image archive, render/package app runtime manifests
#   monitor - build/export monitor image archive, render/package monitor runtime manifests
#   none    - load/validate environment and package metadata only
#
# Forbidden old meanings:
#   - no image import into a live cluster
#   - no kubectl apply
#   - no Helm install/upgrade
#   - no rollout restart
#   - no live validation
#
# The production server receives only the finished bundle.

current_deploy_mode() {
  local mode="${DEPLOY_MODE:-full}"

  # Trim accidental whitespace from .env/operator input.
  mode="$(printf '%s' "$mode" | xargs)"

  if [ -z "$mode" ]; then
    mode="full"
  fi

  printf '%s\n' "$mode"
}

valid_deploy_mode() {
  case "${1:-}" in
    full|app|monitor|none) return 0 ;;
    *) return 1 ;;
  esac
}

validate_deploy_mode() {
  local mode
  mode="$(current_deploy_mode)"

  if ! valid_deploy_mode "$mode"; then
    fatal "unsupported DEPLOY_MODE artifact selector: $mode. Use one of: full, app, monitor, none."
  fi

  DEPLOY_MODE="$mode"
  export DEPLOY_MODE

  enforce_bundle_only_deploy_mode_flags

  log "artifact selector validated: $DEPLOY_MODE"
}

enforce_bundle_only_deploy_mode_flags() {
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
  DISTRIBUTE_IMAGES_TO_NODES="0"
  INSTALL_GITHUB_RUNNER="0"

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
  export DISTRIBUTE_IMAGES_TO_NODES
  export INSTALL_GITHUB_RUNNER
}

requires_docker() {
  case "$(current_deploy_mode)" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_app_image() {
  case "$(current_deploy_mode)" in
    full|app) return 0 ;;
    *) return 1 ;;
  esac
}

requires_monitor_image() {
  case "$(current_deploy_mode)" in
    full|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_manifests_apply() {
  # Kept for backward compatibility with older function names.
  # In bundle-only mode this means "requires rendered manifests to be packaged",
  # never "apply manifests".
  case "$(current_deploy_mode)" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_manifests_package() {
  case "$(current_deploy_mode)" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_observability_package() {
  case "$(current_deploy_mode)" in
    full) return 0 ;;
    *) return 1 ;;
  esac
}

explain_deploy_mode() {
  enforce_bundle_only_deploy_mode_flags

  case "$(current_deploy_mode)" in
    full)
      log "DEPLOY_MODE=full artifact selector: build/export app and monitor image archives, render/package runtime manifests, and include bundle metadata"
      ;;
    app)
      log "DEPLOY_MODE=app artifact selector: build/export app image archive and render/package app runtime artifacts"
      ;;
    monitor)
      log "DEPLOY_MODE=monitor artifact selector: build/export monitor image archive and render/package monitor runtime artifacts"
      ;;
    none)
      log "DEPLOY_MODE=none artifact selector: validate build inputs and package metadata only; no image archives or runtime manifests"
      ;;
    *)
      warn "DEPLOY_MODE=$(current_deploy_mode): invalid artifact selector; validation should fail before bundle work"
      ;;
  esac

  log "bundle-only enforcement: no K3s install, no Helm install/upgrade, no kubectl apply, no image import, no rollout restart, no live validation"
}
