#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

requires_docker() {
  case "$DEPLOY_MODE" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_app_image() {
  case "$DEPLOY_MODE" in
    full|app) return 0 ;;
    *) return 1 ;;
  esac
}

requires_monitor_image() {
  case "$DEPLOY_MODE" in
    full|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

requires_manifests_apply() {
  case "$DEPLOY_MODE" in
    full|app|monitor|manifests) return 0 ;;
    *) return 1 ;;
  esac
}

