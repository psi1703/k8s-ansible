#!/usr/bin/env bash
# Hard-sync this local DEVtoPROD checkout from GitHub.
#
# This script is for the dev/build server only.
#
# It does not deploy.
# It does not run setup.sh.
# It does not build the bundle automatically.
# It does not run Kubernetes, Helm, Ansible deployment, libvirt, or production mutation.
#
# Default target:
#   /home/psi/k8s-ansible
#
# Usage:
#   bash scripts/sync-from-github.sh
#
# Optional overrides:
#   REPO_URL="https://github.com/psi1703/k8s-ansible.git" \
#   BRANCH="k8s-ansible-DEVtoPROD" \
#   TARGET_DIR="/home/psi/k8s-ansible" \
#   bash scripts/sync-from-github.sh
#
# Local files intentionally preserved:
#   .env
#   .env.*
#   dist/
#   release/
#   automation/ansible/inventory.generated.ini
#   automation/libvirt/build/

set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/psi1703/k8s-ansible.git}"
BRANCH="${BRANCH:-k8s-ansible-DEVtoPROD}"
TARGET_DIR="${TARGET_DIR:-/home/psi/k8s-ansible}"

LOG_PREFIX="[repo-sync]"

log() {
  printf '%s %s\n' "$LOG_PREFIX" "$*"
}

warn() {
  printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2
}

fatal() {
  printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"
}

assert_safe_config() {
  [ -n "$REPO_URL" ] || fatal "REPO_URL is empty"
  [ -n "$BRANCH" ] || fatal "BRANCH is empty"
  [ -n "$TARGET_DIR" ] || fatal "TARGET_DIR is empty"

  [ "$BRANCH" = "k8s-ansible-DEVtoPROD" ] || fatal "refusing unsafe branch: $BRANCH"

  case "$TARGET_DIR" in
    /home/psi/k8s-ansible)
      log "target path confirmed: $TARGET_DIR"
      ;;
    *)
      fatal "refusing unsafe target directory: $TARGET_DIR. Expected /home/psi/k8s-ansible"
      ;;
  esac

  case "$TARGET_DIR" in
    /|/home|/home/psi|/opt)
      fatal "refusing dangerous target directory: $TARGET_DIR"
      ;;
  esac
}

prepare_parent_dir() {
  local parent_dir=""

  parent_dir="$(dirname "$TARGET_DIR")"
  [ -n "$parent_dir" ] || fatal "could not determine parent directory for $TARGET_DIR"

  if [ ! -d "$parent_dir" ]; then
    fatal "parent directory does not exist: $parent_dir"
  fi
}

clone_if_needed() {
  if [ -d "$TARGET_DIR/.git" ]; then
    return 0
  fi

  if [ -d "$TARGET_DIR" ] && [ -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    fatal "target exists but is not a git checkout and is not empty: $TARGET_DIR"
  fi

  log "cloning $BRANCH from $REPO_URL into $TARGET_DIR"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$TARGET_DIR"
}

assert_checkout_identity() {
  local actual_url=""
  local top_level=""
  local current_branch=""

  cd "$TARGET_DIR"

  top_level="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ "$top_level" = "$TARGET_DIR" ] || fatal "unexpected git top-level: $top_level"

  actual_url="$(git remote get-url origin 2>/dev/null || true)"
  if [ "$actual_url" != "$REPO_URL" ]; then
    warn "origin URL differs"
    warn "current: $actual_url"
    warn "wanted:  $REPO_URL"
    log "setting origin URL to $REPO_URL"
    git remote set-url origin "$REPO_URL"
  fi

  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -n "$current_branch" ] && [ "$current_branch" != "$BRANCH" ]; then
    warn "current local branch is '$current_branch', target branch is '$BRANCH'"
    warn "this hard sync will switch the checkout to '$BRANCH'"
  fi
}

backup_local_env_files() {
  local backup_dir=""

  cd "$TARGET_DIR"

  backup_dir="$TARGET_DIR/.repo-sync-backup"
  mkdir -p "$backup_dir"

  if [ -f ".env" ]; then
    cp -a ".env" "$backup_dir/.env"
    log "preserved .env backup at $backup_dir/.env"
  fi
}

hard_sync_checkout() {
  cd "$TARGET_DIR"

  log "fetching branch $BRANCH from origin"
  git fetch --prune origin "$BRANCH"

  log "checking out local branch $BRANCH"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
  else
    git checkout -B "$BRANCH" "origin/$BRANCH"
  fi

  log "hard resetting to origin/$BRANCH"
  git reset --hard "origin/$BRANCH"

  log "cleaning untracked files while preserving local runtime/build outputs"
  git clean -ffdx \
    -e .env \
    -e '.env.*' \
    -e .repo-sync-backup/ \
    -e dist/ \
    -e release/ \
    -e automation/ansible/inventory.generated.ini \
    -e automation/libvirt/build/

  log "sync result"
  git status --short
  git branch --show-current
  git log --oneline -1
}

print_next_steps() {
  cat <<EOF_NEXT

${LOG_PREFIX} Sync complete.

Repository:
  $TARGET_DIR

Branch:
  $BRANCH

This script did not deploy anything.
This script did not run Kubernetes, Helm, Ansible deployment, libvirt, setup.sh, or build-release-bundle.sh.

Next manual step, only when you want to build the bundle:

  cd "$TARGET_DIR"
  bash build-release-bundle.sh --mode full

EOF_NEXT
}

main() {
  log "starting GitHub hard sync"
  log "repo:   $REPO_URL"
  log "branch: $BRANCH"
  log "target: $TARGET_DIR"

  require_cmd git
  require_cmd find
  require_cmd dirname

  assert_safe_config
  prepare_parent_dir
  clone_if_needed
  assert_checkout_identity
  backup_local_env_files
  hard_sync_checkout
  print_next_steps
}

main "$@"
