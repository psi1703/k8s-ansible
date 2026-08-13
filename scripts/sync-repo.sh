#!/usr/bin/env bash
set -Eeuo pipefail

# k8s-ansible local repository synchronizer
#
# Purpose:
#   Keep the build/server checkout aligned with GitHub without using a
#   self-hosted GitHub Actions runner.
#
# Behavior:
#   - clones the repo if REPO_DIR does not contain a git checkout
#   - fetches the configured remote branch
#   - hard-resets the local checkout to origin/<branch>
#   - removes untracked repo files while preserving local runtime artifacts
#   - never provisions VMs, installs K3s, applies Kubernetes resources, or deploys
#
# Defaults can be overridden with environment variables:
#   REPO_URL=https://github.com/psi1703/k8s-ansible.git
#   REPO_DIR=/opt/k8s-ansible
#   BRANCH=main
#   REMOTE=origin
#   SYNC_LOG=/var/log/k8s-ansible/repo-sync.log
#   RUN_AFTER_SYNC=0
#
# Optional post-sync command:
#   RUN_AFTER_SYNC=1 AFTER_SYNC_CMD='bash setup.sh' bash scripts/sync-repo.sh
#
# The default is sync-only. It intentionally does not run setup.sh.

REPO_URL="${REPO_URL:-https://github.com/psi1703/k8s-ansible.git}"
REPO_DIR="${REPO_DIR:-/opt/k8s-ansible}"
BRANCH="${BRANCH:-main}"
REMOTE="${REMOTE:-origin}"
SYNC_LOG="${SYNC_LOG:-/var/log/k8s-ansible/repo-sync.log}"
RUN_AFTER_SYNC="${RUN_AFTER_SYNC:-0}"
AFTER_SYNC_CMD="${AFTER_SYNC_CMD:-}"
LOCK_FILE="${LOCK_FILE:-/var/lock/k8s-ansible-repo-sync.lock}"

log() {
  printf '[repo-sync] %s %s\n' "$(date -Is)" "$*"
}

fatal() {
  log "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

as_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

prepare_logging() {
  local log_dir
  log_dir="$(dirname "$SYNC_LOG")"
  as_root_or_sudo mkdir -p "$log_dir"
  as_root_or_sudo touch "$SYNC_LOG"
  as_root_or_sudo chown "$(id -un):$(id -gn)" "$SYNC_LOG" 2>/dev/null || true
  exec > >(tee -a "$SYNC_LOG") 2>&1
}

acquire_lock() {
  as_root_or_sudo mkdir -p "$(dirname "$LOCK_FILE")"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Another repo sync is already running; exiting."
    exit 0
  fi
}

ensure_git_safe_directory() {
  git config --global --add safe.directory "$REPO_DIR" >/dev/null 2>&1 || true
}

install_git_if_missing() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  log "git is missing; installing git with apt-get"
  as_root_or_sudo apt-get update
  as_root_or_sudo apt-get install -y git ca-certificates openssh-client
}

ensure_repo_checkout() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Using existing git checkout: $REPO_DIR"
    return 0
  fi

  if [[ -e "$REPO_DIR" && -n "$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    fatal "$REPO_DIR exists but is not a git checkout and is not empty. Move it aside or set REPO_DIR to a clean path."
  fi

  log "Cloning $REPO_URL branch $BRANCH into $REPO_DIR"
  as_root_or_sudo mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$REPO_DIR"
}

show_preserved_files() {
  log "Preserved local artifacts, if present:"
  for path in \
    ".env" \
    "automation/ansible/inventory.generated.ini" \
    "automation/libvirt/build" \
    "dist" \
    "release" \
    ".sync-state"; do
    if [[ -e "$REPO_DIR/$path" ]]; then
      log "  preserved: $path"
    else
      log "  absent:    $path"
    fi
  done
}

sync_repo() {
  local before after

  cd "$REPO_DIR"
  ensure_git_safe_directory

  if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    log "Remote $REMOTE is missing; adding $REMOTE -> $REPO_URL"
    git remote add "$REMOTE" "$REPO_URL"
  fi

  log "Fetching $REMOTE/$BRANCH"
  git fetch --prune "$REMOTE" "$BRANCH"

  before="$(git rev-parse HEAD 2>/dev/null || true)"
  after="$(git rev-parse "FETCH_HEAD")"

  log "Current HEAD: ${before:-none}"
  log "Remote  HEAD: $after"

  if [[ "$before" == "$after" ]]; then
    log "Already up to date. Re-applying hard reset for consistency."
  else
    log "Repository update detected. Resetting local checkout to $REMOTE/$BRANCH."
  fi

  git reset --hard "FETCH_HEAD"

  # Remove untracked repo content but preserve local runtime/operator artifacts.
  git clean -ffd \
    -e .env \
    -e automation/ansible/inventory.generated.ini \
    -e automation/libvirt/build/ \
    -e dist/ \
    -e release/ \
    -e .sync-state/ \
    -e .venv/ \
    -e venv/

  chmod +x setup.sh 2>/dev/null || true
  chmod +x install-otp-relay-k8s.sh 2>/dev/null || true
  chmod +x scripts/*.sh 2>/dev/null || true
  chmod +x automation/libvirt/*.sh 2>/dev/null || true
  chmod +x automation/ansible/*.sh 2>/dev/null || true

  mkdir -p .sync-state
  printf '%s\n' "$after" > .sync-state/last-synced-commit
  date -Is > .sync-state/last-sync-time

  log "Sync complete. HEAD is now: $(git rev-parse --short HEAD)"
  git status --short || true
  show_preserved_files

  if [[ "$RUN_AFTER_SYNC" == "1" ]]; then
    [[ -n "$AFTER_SYNC_CMD" ]] || fatal "RUN_AFTER_SYNC=1 requires AFTER_SYNC_CMD"
    log "Running post-sync command: $AFTER_SYNC_CMD"
    bash -lc "$AFTER_SYNC_CMD"
  else
    log "RUN_AFTER_SYNC=0; no provisioning/deployment command was run."
  fi
}

main() {
  prepare_logging
  acquire_lock
  need_cmd flock
  install_git_if_missing
  need_cmd git
  ensure_repo_checkout
  sync_repo
}

main "$@"
