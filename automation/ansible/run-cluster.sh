#!/usr/bin/env bash
# Disabled legacy Ansible cluster runner.
#
# Historical behavior:
#   This script used to prepare hosts, install K3s, configure workers,
#   deploy OTP Relay, and validate a live cluster.
#
# Current DEVtoPROD contract:
#   - The dev/build side creates a sealed production release bundle only.
#   - No cluster provisioning is allowed from this path.
#   - No Ansible deployment is allowed from this path.
#   - No K3s install is allowed from this path.
#   - No kubectl/Helm apply/install is allowed from this path.
#   - No live validation is allowed from this path.
#
# The production server receives only the finished bundle.

set -Eeuo pipefail

log() {
  printf '[run-cluster] %s\n' "$*"
}

fatal() {
  printf '[run-cluster] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF_USAGE
Usage:
  automation/ansible/run-cluster --explain

This legacy Ansible cluster runner is disabled.

Use the bundle-only release builder instead:

  bash setup.sh
  # or
  bash build-release-bundle.sh

Bundle-only contract:
  - no Ansible cluster run
  - no K3s install
  - no worker configuration
  - no node labeling
  - no storage validation against a live cluster
  - no Kubernetes manifest apply
  - no Helm install/upgrade
  - no rollout restart
  - no live production validation

The production server receives only the finished release bundle.
EOF_USAGE
}

case "${1:-}" in
  --explain|-h|--help)
    usage
    exit 0
    ;;
  "")
    log "legacy Ansible cluster runner is disabled"
    log "use: bash setup.sh"
    fatal "refusing to run live cluster automation from bundle-only path"
    ;;
  *)
    fatal "unsupported option for disabled legacy runner: $1"
    ;;
esac
