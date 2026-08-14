#!/usr/bin/env bash
# Layer: deployment mode detection and change classification.
#
# This file is sourced by install-otp-relay-k8s.sh. Do not execute it directly.
#
# Responsibilities:
# - Classify repository changes into safe deployment/update categories.
# - Help the installer decide whether app rebuild, monitor rebuild, help-doc rebuild, manifest apply, or observability apply is needed.
# - Keep deployment decisions explicit instead of hiding them inside GitHub Actions or repo-sync.
# - Support operator-controlled updates after the repository has already been synced.
#
# Non-responsibilities:
# - It does not sync the repository.
# - It does not build images.
# - It does not apply Kubernetes manifests.
# - It does not install K3s, Helm, MetalLB, or observability charts.
# - It does not install GitHub runners.

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
    full|app|monitor|manifests|observability|none) return 0 ;;
    *) return 1 ;;
  esac
}

validate_deploy_mode() {
  local mode
  mode="$(current_deploy_mode)"

  if ! valid_deploy_mode "$mode"; then
    fatal "unsupported DEPLOY_MODE=$mode. Use one of: full, app, monitor, manifests, observability, none."
  fi

  DEPLOY_MODE="$mode"
  export DEPLOY_MODE

  log "deployment mode validated: $DEPLOY_MODE"
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
  case "$(current_deploy_mode)" in
    full|app|monitor|manifests) return 0 ;;
    *) return 1 ;;
  esac
}

explain_deploy_mode() {
  case "$(current_deploy_mode)" in
    full)
      log "DEPLOY_MODE=full: build/import app and monitor images, render/apply manifests, deploy all components"
      ;;
    app)
      log "DEPLOY_MODE=app: build/import app image and apply app-related manifests"
      ;;
    monitor)
      log "DEPLOY_MODE=monitor: build/import monitor image and apply monitor-related manifests"
      ;;
    manifests)
      log "DEPLOY_MODE=manifests: render/apply Kubernetes manifests without rebuilding images"
      ;;
    observability)
      log "DEPLOY_MODE=observability: install/update Prometheus, Grafana, Loki, Alloy, dashboard, ServiceMonitor, and Grafana ingress only"
      ;;
    none)
      log "DEPLOY_MODE=none: validate environment only; no Docker, K3s, image, or manifest work"
      ;;
    *)
      warn "DEPLOY_MODE=$(current_deploy_mode): invalid mode; validation should fail before deployment work"
      ;;
  esac
}
