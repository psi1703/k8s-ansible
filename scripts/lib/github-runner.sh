#!/usr/bin/env bash
# GitHub Actions runner helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Do not install GitHub Actions runners.
#   - Do not configure runner services.
#   - Do not register runners.
#   - Do not download runner packages.
#   - Do not create runner users.
#
# The production server receives only the finished bundle.

_github_runner_forbid_action() {
  local action="$1"

  fatal "forbidden GitHub runner action in bundle-only mode: $action"
}

normalize_github_runner_settings() {
  INSTALL_GITHUB_RUNNER="0"
  RUNNER_ONLY="0"
  GITHUB_RUNNER_URL=""
  GITHUB_RUNNER_TOKEN=""
  GITHUB_RUNNER_DIR=""
  GITHUB_RUNNER_USER=""

  export INSTALL_GITHUB_RUNNER
  export RUNNER_ONLY
  export GITHUB_RUNNER_URL
  export GITHUB_RUNNER_TOKEN
  export GITHUB_RUNNER_DIR
  export GITHUB_RUNNER_USER

  log "GitHub runner setup disabled in bundle-only mode"
}

validate_github_runner_settings() {
  normalize_github_runner_settings
}

prompt_optional_runner_setup() {
  normalize_github_runner_settings
}

install_github_runner_if_requested() {
  normalize_github_runner_settings
  log "skipping GitHub Actions runner installation in bundle-only mode"
}

install_github_runner() {
  _github_runner_forbid_action "install GitHub Actions runner"
}

create_github_runner_user() {
  _github_runner_forbid_action "create GitHub runner user"
}

download_github_runner() {
  _github_runner_forbid_action "download GitHub runner package"
}

configure_github_runner() {
  _github_runner_forbid_action "configure/register GitHub runner"
}

install_github_runner_service() {
  _github_runner_forbid_action "install GitHub runner service"
}

start_github_runner_service() {
  _github_runner_forbid_action "start GitHub runner service"
}

print_github_runner_status() {
  log "GitHub runner status skipped in bundle-only mode"
}
