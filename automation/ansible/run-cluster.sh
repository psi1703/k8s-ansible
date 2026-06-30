#!/usr/bin/env bash
set -Eeuo pipefail

# Deprecated live-cluster runner.
#
# This file is intentionally kept only as a safety guard for old references.
#
# Bundle-only policy:
#   - Do not provision worker VMs
#   - Do not install Ansible dependencies
#   - Do not modify host networking, DNS, NAT, firewall, or SSH state
#   - Do not install K3s
#   - Do not join workers to a cluster
#   - Do not run ansible-playbook
#   - Do not deploy OTP Relay
#   - Do not validate a live cluster
#
# The production server receives only the finished bundle.
#
# Correct entrypoint:
#   bash setup.sh
#
# Optional explicit compatibility mode:
#   bash automation/ansible/run-cluster --explain
#
# Any attempt to run old cluster automation through this file fails safely.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() {
  printf '[run-cluster] %s\n' "$*"
}

fatal() {
  printf '[run-cluster] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  automation/ansible/run-cluster --explain
  automation/ansible/run-cluster -h|--help

This runner used to execute live cluster automation. It is now disabled.

Bundle-only policy:
  - no VM provisioning
  - no Ansible cluster execution
  - no K3s installation
  - no Kubernetes apply
  - no Helm install/upgrade
  - no image import into a live cluster
  - no live production validation

Use the bundle-only release entrypoint instead:

  bash setup.sh

The production server receives only the finished bundle.
USAGE
}

explain() {
  log "live-cluster automation is disabled"
  log "repository root: ${REPO_ROOT}"
  log "ansible directory: ${SCRIPT_DIR}"
  log "correct entrypoint: bash setup.sh"
  log "expected result: sealed release tarball under ./releases"
  log "nothing was provisioned, installed, deployed, or validated"
}

main() {
  if [ "$#" -eq 0 ]; then
    usage >&2
    fatal "refusing to run deprecated live-cluster automation; use 'bash setup.sh' to build a sealed release bundle"
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --explain)
        explain
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        fatal "unsupported argument for disabled runner: $1"
        ;;
    esac
  done
}

main "$@"
