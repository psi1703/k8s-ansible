#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

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
    apt-get install -y --no-install-recommends docker.io
    log "docker.io package installation completed"
  fi

  if ! resolve_docker_bin; then
    fatal "Docker CLI is still not available after installing docker.io. Confirm the package provides /usr/bin/docker or install Docker CE CLI."
  fi

  log "using Docker CLI: $DOCKER_BIN"

  if ! systemctl is-active --quiet docker; then
    log "starting/enabling Docker service because local image builds require it"
    systemctl enable --now docker
    log "Docker service start requested"
  else
    log "Docker already active; no restart performed"
  fi

  log "validating Docker daemon connectivity"
  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    fatal "Docker CLI is available at $DOCKER_BIN, but Docker daemon is not responding"
  fi

  log "Docker is ready for local image builds"
}
