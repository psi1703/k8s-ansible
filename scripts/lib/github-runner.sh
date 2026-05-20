#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

write_runner_sudoers() {
  id -u "$GITHUB_RUNNER_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$GITHUB_RUNNER_USER"

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

install_github_runner() {
  [ "$INSTALL_GITHUB_RUNNER" = "1" ] || return 0

  write_runner_sudoers

  if systemctl list-unit-files | grep -q 'actions.runner'; then
    warn "an actions.runner systemd unit already exists; leaving existing runner registration untouched"
    return 0
  fi

  [ -n "$RUNNER_ARCH" ] || fatal "unsupported architecture for GitHub runner: $ARCH_RAW"
  [ -n "$GITHUB_RUNNER_URL" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_URL"
  [ -n "$GITHUB_RUNNER_TOKEN" ] || fatal "INSTALL_GITHUB_RUNNER=1 requires GITHUB_RUNNER_TOKEN"

  log "installing GitHub Actions self-hosted runner before Docker/K3s deployment work"
  mkdir -p "$GITHUB_RUNNER_DIR"
  chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$GITHUB_RUNNER_DIR"

  local runner_version="${GITHUB_RUNNER_VERSION:-2.328.0}"
  local runner_tar="actions-runner-linux-${RUNNER_ARCH}-${runner_version}.tar.gz"
  local runner_url="https://github.com/actions/runner/releases/download/v${runner_version}/${runner_tar}"
  curl -fL "$runner_url" -o "/tmp/$runner_tar"
  tar -xzf "/tmp/$runner_tar" -C "$GITHUB_RUNNER_DIR"
  rm -f "/tmp/$runner_tar"
  chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$GITHUB_RUNNER_DIR"

  sudo -u "$GITHUB_RUNNER_USER" bash -lc "cd '$GITHUB_RUNNER_DIR' && ./config.sh --unattended --url '$GITHUB_RUNNER_URL' --token '$GITHUB_RUNNER_TOKEN' --work _work"
  bash -lc "cd '$GITHUB_RUNNER_DIR' && ./svc.sh install '$GITHUB_RUNNER_USER' && ./svc.sh start"
}

