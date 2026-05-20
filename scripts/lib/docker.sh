#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

resolve_docker_bin() {
  if [ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ]; then
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

install_package_if_available() {
  local pkg="$1"
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends "$pkg"
  fi
}

ensure_docker() {
  if ! resolve_docker_bin; then
    log "installing Docker because it is required to build and import local images"
    apt-get install -y --no-install-recommends docker.io
    install_package_if_available docker-cli
  fi

  if ! resolve_docker_bin; then
    fatal "Docker CLI is still not available after installing docker.io/docker-cli. On Debian 13, confirm the package provides /usr/bin/docker or install Docker CE CLI."
  fi

  if ! systemctl is-active --quiet docker; then
    log "starting Docker because it is required to build local images"
    systemctl enable --now docker
  else
    log "Docker already active; no restart performed"
  fi

  log "using Docker CLI: $DOCKER_BIN"
}

