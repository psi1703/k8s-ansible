#!/usr/bin/env bash
set -Eeuo pipefail

# Deprecated worker VM provisioner.
#
# This file is intentionally kept only as a safety guard for old references.
#
# Bundle-only policy:
#   - Do not install virtualization packages
#   - Do not enable or configure libvirt
#   - Do not create bridges
#   - Do not modify NetworkManager or /etc/network/interfaces
#   - Do not download cloud images
#   - Do not create qcow2 disks
#   - Do not create seed ISOs
#   - Do not create, destroy, or repair VMs
#   - Do not write live Ansible inventory for deployment
#   - Do not validate SSH, DNS, apt, or cloud-init on worker VMs
#
# The production server receives only the finished bundle.
#
# Correct entrypoint:
#   bash setup.sh
#
# Optional explicit compatibility mode:
#   bash automation/libvirt/provision-vms.sh --explain
#
# Any attempt to run old VM provisioning through this file fails safely.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() {
  printf '[provision-vms] %s\n' "$*"
}

fatal() {
  printf '[provision-vms] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  automation/libvirt/provision-vms.sh --explain
  automation/libvirt/provision-vms.sh -h|--help

This provisioner used to create live worker VMs. It is now disabled.

Bundle-only policy:
  - no worker VM provisioning
  - no libvirt installation/configuration
  - no bridge/network mutation
  - no cloud image download
  - no qcow2/seed ISO creation
  - no Ansible inventory generation for live deployment
  - no SSH/DNS/apt/cloud-init validation against VMs

Use the bundle-only release entrypoint instead:

  bash setup.sh

The production server receives only the finished bundle.
USAGE
}

explain() {
  log "worker VM provisioning is disabled"
  log "repository root: ${REPO_ROOT}"
  log "libvirt directory: ${SCRIPT_DIR}"
  log "correct entrypoint: bash setup.sh"
  log "expected result: sealed release tarball under ./releases"
  log "nothing was provisioned, installed, changed, downloaded, created, or validated"
}

main() {
  if [ "$#" -eq 0 ]; then
    usage >&2
    fatal "refusing to run deprecated VM provisioner; use 'bash setup.sh' to build a sealed release bundle"
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
        fatal "unsupported argument for disabled VM provisioner: $1"
        ;;
    esac
  done
}

main "$@"
