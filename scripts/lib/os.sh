#!/usr/bin/env bash
# Layer: host operating-system helper functions.
#
# This file is sourced by install-otp-relay-k8s.sh. Do not execute it directly.
#
# Responsibilities:
# - Detect the host operating system and package-manager capabilities.
# - Provide safe package-install helper behavior for installer prerequisites.
# - Keep host-level checks separate from Kubernetes, Docker, and application deployment logic.
#
# Non-responsibilities:
# - It does not install or configure K3s workloads.
# - It does not build container images.
# - It does not render or apply Kubernetes manifests.
# - It does not install observability Helm charts.
# - It does not sync the repository.
# - It does not install GitHub runners.

is_debian_family() {
  case "${OS_ID:-} ${OS_LIKE:-}" in
    *debian*|*ubuntu*) return 0 ;;
    *) return 1 ;;
  esac
}
