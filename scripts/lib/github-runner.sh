#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

write_runner_sudoers() {
  [ -n "${GITHUB_RUNNER_USER:-}" ] || fatal "GITHUB_RUNNER_USER is required before writing runner sudoers."
  [ -n "${GITHUB_RUNNER_DIR:-}" ] || fatal "GITHUB_RUNNER_DIR is required before writing runner sudoers."
  [ -n "${INSTALL_DIR:-}" ] || fatal "INSTALL_DIR is required before writing runner sudoers."

  if ! id -u "$GITHUB_RUNNER_USER" >/dev/null 2>&1; then
    log "creating system user $GITHUB_RUNNER_USER for GitHub Actions runner"
    useradd --system --create-home --shell /bin/bash "$GITHUB_RUNNER_USER"
  fi

  local sudoers_file="/etc/sudoers.d/otp-relay-actions-runner"
  log "granting $GITHUB_RUNNER_USER narrow passwordless sudo for the OTP Relay installer"

  cat > "$sudoers_file" <<EOF_SUDOERS
$GITHUB_RUNNER_USER ALL=(root) NOPASSWD:SETENV: /bin/bash $INSTALL_DIR/install-otp-relay-k8s.sh
$GITHUB_RUNNER_USER ALL=(root) NOPASSWD:SETENV: /usr/bin/bash $INSTALL_DIR/install-otp-relay-k8s.sh
$GITHUB_RUNNER_USER ALL=(root) NOPASSWD:SETENV: /bin/bash $GITHUB_RUNNER_DIR/_work/*/*/install-otp-relay-k8s.sh
$GITHUB_RUNNER_USER ALL=(root) NOPASSWD:SETENV: /usr/bin/bash $GITHUB_RUNNER_DIR/_work/*/*/install-otp-relay-k8s.sh
EOF_SUDOERS

  chmod 0440 "$sudoers_file"
  visudo -cf "$sudoers_file" >/dev/null
}

runner_service_exists_for_dir() {
  [ -n "${GITHUB_RUNNER_DIR:-}" ] || return 1

  if [ -f "$GITHUB_RUNNER_DIR/.service" ]; then
    return 0
  fi

  systemctl list-unit-files 'actions.runner.*.service' --no-legend 2>/dev/null | grep -q '^actions\.runner\.'
}

install_github_runner() {
  [ "${INSTALL_GITHUB_RUNNER:-0}" = "1" ] || return 0

  [ -n "${RUNNER_ARCH:-}" ] || fatal "unsupported architecture for GitHub runner: ${ARCH_RAW:-unknown}"
  [ -n "${GITHUB_RUNNER_URL:-}" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_URL."
  [ -n "${GITHUB_RUNNER_TOKEN:-}" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_TOKEN."
  [ -n "${GITHUB_RUNNER_USER:-}" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_USER."
  [ -n "${GITHUB_RUNNER_DIR:-}" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_DIR."

  write_runner_sudoers

  if runner_service_exists_for_dir; then
    warn "a GitHub Actions runner service already appears to exist; leaving existing runner registration untouched"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fatal "curl is required to download the GitHub Actions runner."
  command -v tar >/dev/null 2>&1 || fatal "tar is required to extract the GitHub Actions runner."

  log "installing GitHub Actions self-hosted runner before Docker/K3s deployment work"
  mkdir -p "$GITHUB_RUNNER_DIR"
  chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$GITHUB_RUNNER_DIR"

  local runner_version="${GITHUB_RUNNER_VERSION:-2.328.0}"
  local runner_tar="actions-runner-linux-${RUNNER_ARCH}-${runner_version}.tar.gz"
  local runner_url="https://github.com/actions/runner/releases/download/v${runner_version}/${runner_tar}"
  local runner_tmp="/tmp/$runner_tar"

  log "downloading GitHub Actions runner $runner_version for linux-$RUNNER_ARCH"
  curl -fL "$runner_url" -o "$runner_tmp"

  log "extracting GitHub Actions runner into $GITHUB_RUNNER_DIR"
  tar -xzf "$runner_tmp" -C "$GITHUB_RUNNER_DIR"
  rm -f "$runner_tmp"
  chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$GITHUB_RUNNER_DIR"

  log "configuring GitHub Actions runner registration"
  sudo -u "$GITHUB_RUNNER_USER" bash -lc "cd '$GITHUB_RUNNER_DIR' && ./config.sh --unattended --url '$GITHUB_RUNNER_URL' --token '$GITHUB_RUNNER_TOKEN' --work _work"

  log "installing and starting GitHub Actions runner service"
  bash -lc "cd '$GITHUB_RUNNER_DIR' && ./svc.sh install '$GITHUB_RUNNER_USER' && ./svc.sh start"

  log "GitHub Actions runner installation completed"
}
