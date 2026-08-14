#!/usr/bin/env bash
# Layer: Docker CLI and daemon readiness for local image builds.
#
# This file is sourced by install-otp-relay-k8s.sh. Do not execute it directly.
#
# Responsibilities:
# - Locate a usable Docker CLI.
# - Install docker.io with apt-get when Docker is missing.
# - Enable and start the Docker service when local image builds require it.
# - Validate Docker daemon connectivity before image build/import begins.
#
# Non-responsibilities:
# - It does not build OTP Relay images.
# - It does not import images into K3s.
# - It does not distribute images to worker nodes.
# - It does not install K3s, Helm, MetalLB, or observability components.
# - It does not sync the repository.
# - It does not install GitHub runners.

resolve_docker_bin() {
  if [ -n "${DOCKER_BIN:-}" ] && [ -x "$DOCKER_BIN" ]; then
    return 0
  fi

  if cmd_exists docker; then
    DOCKER_BIN="$(command -v docker)"
    return 0
  fi

  for candidate in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker; do
    if [ -x "$candidate" ]; then
      DOCKER_BIN="$candidate"
      return 0
    fi
  done

  return 1
}

ensure_docker() {
  log "checking Docker CLI availability"

  if ! resolve_docker_bin; then
    log "Docker CLI was not found; installing docker.io because local image builds require Docker"
    log "updating apt package index before Docker install; this may take a few minutes"
    apt-get update

    log "installing docker.io with apt-get"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io
    log "docker.io package installation completed"
  fi

  if ! resolve_docker_bin; then
    fatal "Docker CLI is still not available after installing docker.io. Confirm the package provides /usr/bin/docker or install Docker CE CLI."
  fi

  log "using Docker CLI: $DOCKER_BIN"

  command -v systemctl >/dev/null 2>&1 || fatal "systemctl is required to manage the Docker service on this host."

  if ! systemctl is-active --quiet docker; then
    log "starting/enabling Docker service because local image builds require it"
    systemctl enable --now docker
    log "Docker service start requested"
  else
    log "Docker already active; no restart performed"
  fi

  log "validating Docker daemon connectivity"
  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    fatal "Docker CLI is available at $DOCKER_BIN, but Docker daemon is not responding."
  fi

  log "Docker is ready for local image builds"
}
