#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

current_deploy_mode() {
  printf '%s\n' "${DEPLOY_MODE:-full}"
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
