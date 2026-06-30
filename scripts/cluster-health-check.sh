#!/usr/bin/env bash
# Disabled live-cluster health checker.
#
# Bundle-only policy:
#   - The dev/build path must not validate a live Kubernetes cluster.
#   - It must not run kubectl/k3s commands.
#   - It must not check pods, services, ingress, PVCs, Redis, Grafana, Loki, Alloy, or /readyz.
#   - It must not imply that deployment happened.
#
# The production server receives only the finished bundle.
#
# This file is retained only as a safety guard for old workflows.

set -Eeuo pipefail

log() {
  printf '[cluster-health-check] %s\n' "$*"
}

fatal() {
  printf '[cluster-health-check] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF_USAGE
Usage:
  bash scripts/cluster-health-check.sh --explain

This live-cluster health checker is disabled.

The k8s-ansible DEVtoPROD flow is bundle-only now:
  - no K3s install
  - no kubectl apply
  - no Helm install/upgrade
  - no image import
  - no rollout restart
  - no live cluster validation
  - no VM provisioning
  - no GitHub runner installation

The production server receives only the finished release bundle.
Production-side validation must be performed only by the approved production procedure.
EOF_USAGE
}

case "${1:-}" in
  --explain|-h|--help)
    usage
    exit 0
    ;;
  "")
    log "live-cluster health checking is disabled in bundle-only mode"
    log "use: bash scripts/cluster-health-check.sh --explain"
    fatal "refusing to validate a live cluster from the build path"
    ;;
  *)
    fatal "unsupported option in disabled health checker: $1"
    ;;
esac
