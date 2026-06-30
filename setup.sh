#!/usr/bin/env bash
# Compatibility launcher for the OTP Relay Kubernetes bundle-only release builder.
#
# Historical note:
#   setup.sh used to provision/deploy infrastructure.
#   That behavior is permanently disabled in this DEVtoPROD separation design.
#
# Current contract:
#   - Build a sealed production release bundle only.
#   - Do not install K3s.
#   - Do not run Ansible deployment.
#   - Do not provision worker VMs.
#   - Do not install GitHub runners.
#   - Do not run Helm install/upgrade.
#   - Do not run kubectl apply.
#   - Do not import images into a live cluster.
#   - Do not restart deployments.
#   - Do not validate a live cluster.
#
# The production server receives only the finished bundle.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_BUILDER="$SCRIPT_DIR/build-release-bundle.sh"

log() {
  printf '[setup] %s\n' "$*"
}

fatal() {
  printf '[setup] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF_USAGE
Usage:
  bash setup.sh [bundle-builder-options]

This is now a bundle-only compatibility launcher.

It forwards supported options to:

  build-release-bundle.sh

Common examples:

  bash setup.sh
  bash setup.sh --noninteractive
  bash setup.sh --mode full
  bash setup.sh --mode app
  bash setup.sh --mode monitor
  bash setup.sh --mode none
  bash setup.sh --env-file .env
  bash setup.sh --dist-dir dist

Bundle-only contract:
  - no K3s install
  - no Ansible deployment
  - no VM provisioning
  - no GitHub runner installation
  - no Helm install/upgrade
  - no kubectl apply
  - no image import
  - no rollout restart
  - no live cluster validation

The production server receives only the finished release bundle.
EOF_USAGE
}

reject_old_deploy_options() {
  local arg=""

  for arg in "$@"; do
    case "$arg" in
      --local|--reprovision-vms|--no-ansible|--ansible|--deploy|--validate|--install-k3s|--install-runner|--runner-only|--provision-vms)
        fatal "unsupported old deployment option in bundle-only mode: $arg"
        ;;
    esac
  done
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  reject_old_deploy_options "$@"

  [ -f "$BUNDLE_BUILDER" ] || fatal "bundle builder is missing: $BUNDLE_BUILDER"

  log "starting bundle-only release build"
  log "forwarding to: $BUNDLE_BUILDER"
  log "production server receives only the finished bundle"

  exec bash "$BUNDLE_BUILDER" "$@"
}

main "$@"
