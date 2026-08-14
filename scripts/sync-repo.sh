#!/usr/bin/env bash
set -Eeuo pipefail

# k8s-ansible repository sync helper
#
# Layer: operator automation
#
# Purpose:
#   Keep the local build/server checkout aligned with GitHub origin/main.
#
# Strict behavior contract:
#   - This script only syncs repository files.
#   - It does not install K3s.
#   - It does not run Ansible.
#   - It does not run Helm.
#   - It does not apply Kubernetes manifests.
#   - It does not build/import images.
#   - It does not deploy or restart workloads.
#
# Generated/runtime files are preserved. In particular:
#   - .env remains the local runtime source of truth.
#   - automation/ansible/inventory.generated.ini remains the local inventory.
#   - automation/libvirt/build/ remains local VM/build state.
#   - node_modules/ remains generated dependency output.
#   - frontend/help/ remains generated help output.
#   - frontend/app.js remains generated frontend output.
#
# If help source files changed, this script writes:
#   .sync-state/help-docs-rebuild-required
#
# The installer/build path owns regenerating frontend/help/ and frontend/app.js.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_DIR="${REPO_DIR:-${DEFAULT_REPO_DIR}}"
REMOTE_NAME="${REMOTE_NAME:-origin}"
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-ansible}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/repo-sync.log}"
STATE_DIR="${STATE_DIR:-${REPO_DIR}/.sync-state}"

PRESERVE_PATHS=(
  ".env"
  "automation/ansible/inventory.generated.ini"
  "automation/libvirt/build"
  "dist"
  "release"
  ".sync-state"
  ".venv"
  "venv"
  "node_modules"
  "frontend/help"
  "frontend/app.js"
  "install-report.txt"
)

HELP_SOURCE_PATHS=(
  "docs/help"
  "scripts/build_help_docs.py"
)

log() {
  local message="$*"
  printf '[repo-sync] %s %s\n' "$(date -Iseconds)" "$message" | tee -a "$LOG_FILE"
}

warn() {
  local message="$*"
  printf '[repo-sync][WARN] %s %s\n' "$(date -Iseconds)" "$message" | tee -a "$LOG_FILE" >&2
}

fatal() {
  local message="$*"
  printf '[repo-sync][ERROR] %s %s\n' "$(date -Iseconds)" "$message" | tee -a "$LOG_FILE" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

ensure_log_dir() {
  if [ ! -d "$LOG_DIR" ]; then
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
      :
    elif sudo -n true >/dev/null 2>&1; then
      sudo mkdir -p "$LOG_DIR"
      sudo chown "$(id -u):$(id -g)" "$LOG_DIR" 2>/dev/null || true
    else
      LOG_DIR="${REPO_DIR}/.sync-state/logs"
      LOG_FILE="${LOG_DIR}/repo-sync.log"
      mkdir -p "$LOG_DIR"
    fi
  fi

  touch "$LOG_FILE" 2>/dev/null || {
    LOG_DIR="${REPO_DIR}/.sync-state/logs"
    LOG_FILE="${LOG_DIR}/repo-sync.log"
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
  }
}

ensure_repo() {
  [ -d "$REPO_DIR/.git" ] || fatal "Not a git checkout: $REPO_DIR"
  cd "$REPO_DIR"

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fatal "Not inside a git work tree: $REPO_DIR"
  git remote get-url "$REMOTE_NAME" >/dev/null 2>&1 || fatal "Missing git remote: $REMOTE_NAME"

  # The repository is edited mainly through the GitHub web UI, which does not
  # preserve executable-bit intent reliably. Keep local chmod repair from
  # polluting git status with mode-only changes. Content changes still show.
  git config core.fileMode false
}

restore_executable_bits() {
  local path

  log "Restoring executable bits for operator entrypoint scripts only"

  # Only direct entrypoints are made executable. Sourced library files under
  # scripts/lib/ are intentionally not chmodded; they are loaded with source.
  for path in \
    "setup.sh" \
    "install-otp-relay-k8s.sh" \
    "scripts/sync-repo.sh" \
    "scripts/install-repo-sync-timer.sh" \
    "scripts/cluster-health-check.sh" \
    "automation/libvirt/provision-vms.sh" \
    "automation/validation/resilience-validation.sh" \
    "automation/ansible/run-cluster.sh"
  do
    if [ -f "$path" ]; then
      chmod 755 "$path" 2>/dev/null || warn "Could not set executable bit on $path"
    fi
  done
}

git_clean_excludes() {
  local path

  for path in "${PRESERVE_PATHS[@]}"; do
    printf -- '-e\n%s\n' "$path"
    printf -- '-e\n%s/**\n' "$path"
  done
}

path_changed_between_commits() {
  local old_commit="$1"
  local new_commit="$2"
  local path="$3"

  if [ -z "$old_commit" ] || [ -z "$new_commit" ]; then
    return 1
  fi

  ! git diff --quiet "$old_commit" "$new_commit" -- "$path"
}

mark_help_rebuild_if_needed() {
  local old_commit="$1"
  local new_commit="$2"
  local marker="${STATE_DIR}/help-docs-rebuild-required"
  local changed=0
  local path

  mkdir -p "$STATE_DIR"

  if [ -z "$old_commit" ] || [ -z "$new_commit" ] || [ "$old_commit" = "$new_commit" ]; then
    rm -f "$marker"
    return 0
  fi

  for path in "${HELP_SOURCE_PATHS[@]}"; do
    if path_changed_between_commits "$old_commit" "$new_commit" "$path"; then
      changed=1
    fi
  done

  if [ "$changed" = "1" ]; then
    {
      printf 'Help documentation source changed during repo sync.\n'
      printf 'Previous commit: %s\n' "$old_commit"
      printf 'Current commit:  %s\n' "$new_commit"
      printf 'Generated output frontend/help/ was preserved by repo sync.\n'
      printf 'Run the installer/build path to regenerate help docs.\n'
    } > "$marker"
    log "Help source changed; wrote marker: $marker"
  else
    rm -f "$marker"
  fi
}

write_state() {
  local new_commit="$1"

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$new_commit" > "${STATE_DIR}/last-synced-commit"
  date -Iseconds > "${STATE_DIR}/last-sync-time"
}

sync_repo() {
  local current_head
  local remote_head
  local clean_args_file

  log "Using existing git checkout: $REPO_DIR"
  log "Fetching ${REMOTE_NAME}/${REMOTE_BRANCH}"

  git fetch --prune "$REMOTE_NAME" "$REMOTE_BRANCH"

  current_head="$(git rev-parse HEAD)"
  remote_head="$(git rev-parse "${REMOTE_NAME}/${REMOTE_BRANCH}")"

  log "Current HEAD: $current_head"
  log "Remote  HEAD: $remote_head"

  if [ "$current_head" = "$remote_head" ]; then
    log "Repository already matches ${REMOTE_NAME}/${REMOTE_BRANCH}"
    mark_help_rebuild_if_needed "$current_head" "$remote_head"
    write_state "$remote_head"
    restore_executable_bits
    log "Repo sync completed with no code changes"
    return 0
  fi

  log "Repository update detected. Resetting local checkout to ${REMOTE_NAME}/${REMOTE_BRANCH}."
  git reset --hard "${REMOTE_NAME}/${REMOTE_BRANCH}"

  clean_args_file="$(mktemp)"
  git_clean_excludes > "$clean_args_file"

  log "Cleaning untracked files while preserving runtime/generated artifacts"
  # shellcheck disable=SC2046
  git clean -ffd $(tr '\n' ' ' < "$clean_args_file")
  rm -f "$clean_args_file"

  mark_help_rebuild_if_needed "$current_head" "$remote_head"
  write_state "$remote_head"
  restore_executable_bits

  log "Repo sync completed: $remote_head"
}

main() {
  need_cmd git
  need_cmd date
  need_cmd find
  need_cmd chmod
  need_cmd mktemp

  ensure_log_dir
  ensure_repo
  sync_repo
}

main "$@"
