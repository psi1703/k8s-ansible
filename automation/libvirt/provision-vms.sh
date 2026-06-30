#!/usr/bin/env bash
# Disabled legacy libvirt worker VM provisioner.
#
# Historical behavior:
#   This script used to create worker1/worker2 VMs, configure libvirt networking,
#   generate cloud-init seed images, and write Ansible inventory.
#
# Current DEVtoPROD contract:
#   - The dev/build side creates a sealed production release bundle only.
#   - No VM provisioning is allowed from this path.
#   - No libvirt bridge creation is allowed from this path.
#   - No cloud-init seed creation is allowed from this path.
#   - No worker inventory generation is allowed from this path.
#
# The production server receives only the finished bundle.

set -Eeuo pipefail

log() {
  printf '[provision-vms] %s\n' "$*"
}

fatal() {
  printf '[provision-vms] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF_USAGE
Usage:
  automation/libvirt/provision-vms.sh --explain

This legacy libvirt worker VM provisioner is disabled.

Use the bundle-only release builder instead:

  bash setup.sh
  # or
  bash build-release-bundle.sh

Bundle-only contract:
  - no libvirt package installation
  - no bridge creation
  - no NAT/firewall changes
  - no VM disk creation
  - no cloud-init seed creation
  - no worker VM creation
  - no SSH probing
  - no Ansible inventory generation
  - no K3s worker preparation

The production server receives only the finished release bundle.
EOF_USAGE
}

case "${1:-}" in
  --explain|-h|--help)
    usage
    exit 0
    ;;
  "")
    log "legacy libvirt worker VM provisioner is disabled"
    log "use: bash setup.sh"
    fatal "refusing to provision VMs from bundle-only path"
    ;;
  *)
    fatal "unsupported option for disabled VM provisioner: $1"
    ;;
esac
