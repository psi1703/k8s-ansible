#!/usr/bin/env bash
set -Eeuo pipefail

# Bundle-only release entrypoint for OTP Relay Kubernetes / Ansible artifacts.
#
# Normal use:
#   bash setup.sh
#
# This script intentionally DOES NOT deploy anything.
#
# Bundle-only policy:
#   - No K3s install
#   - No Kubernetes apply
#   - No kubectl live-cluster validation
#   - No Helm install/upgrade
#   - No image import into a live cluster
#   - No Ansible cluster execution
#   - No worker VM provisioning
#   - No GitHub runner installation
#
# The production server receives only the finished bundle.
#
# Output:
#   releases/<release-name>.tar.gz
#   releases/<release-name>.tar.gz.sha256
#
# The bundle contains:
#   - sanitized repository snapshot
#   - release metadata
#   - checksum manifest
#   - production handoff runbook
#   - optional image/archive files if present in known artifact directories

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RELEASE_ROOT="${RELEASE_ROOT:-$SCRIPT_DIR/releases}"
RELEASE_NAME="${RELEASE_NAME:-otp-relay-prod-release-$(date -u +%Y%m%dT%H%M%SZ)}"
WORK_ROOT=""
STAGE_DIR=""
BUNDLE_FILE=""
CHECKSUM_FILE=""

DRY_RUN="0"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
INCLUDE_IMAGE_ARCHIVES="${INCLUDE_IMAGE_ARCHIVES:-1}"

log() {
  printf '[build-release] %s\n' "$*"
}

warn() {
  printf '[build-release] WARNING: %s\n' "$*" >&2
}

fatal() {
  printf '[build-release] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  bash setup.sh [options]

Bundle-only options:
  --release-name NAME       Set release name. Default: otp-relay-prod-release-<UTC timestamp>
  --output-dir DIR          Set output directory. Default: ./releases
  --skip-image-archives     Do not copy existing image/archive artifacts into the bundle.
  --dry-run                 Print what would be created without writing a bundle.
  --noninteractive          Reserved for CI compatibility; no prompts are used.
  -h, --help                Show this help.

Forbidden old deployment options:
  --local
  --reprovision-vms
  --no-ansible
  --edit-env

This entrypoint is now bundle-only. It does not provision VMs, run Ansible,
install K3s, apply Kubernetes resources, run Helm, import images, install
GitHub runners, or validate a live cluster.

The production server receives only the finished bundle.
USAGE
}

forbidden_old_option() {
  local opt="$1"

  fatal "$opt belongs to the old deploy/provision flow and is intentionally disabled. Use this entrypoint only to build a sealed release bundle."
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release-name)
        [ "$#" -ge 2 ] || fatal "--release-name requires a value"
        RELEASE_NAME="$2"
        shift 2
        ;;
      --output-dir)
        [ "$#" -ge 2 ] || fatal "--output-dir requires a value"
        RELEASE_ROOT="$2"
        shift 2
        ;;
      --skip-image-archives)
        INCLUDE_IMAGE_ARCHIVES="0"
        shift
        ;;
      --dry-run)
        DRY_RUN="1"
        shift
        ;;
      --noninteractive)
        NONINTERACTIVE="1"
        export NONINTERACTIVE
        shift
        ;;
      --local|--reprovision-vms|--no-ansible|--edit-env)
        forbidden_old_option "$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "unknown argument: $1"
        ;;
    esac
  done
}

require_command() {
  local cmd="$1"

  command -v "$cmd" >/dev/null 2>&1 || fatal "required command missing: $cmd"
}

require_base_tools() {
  require_command awk
  require_command date
  require_command find
  require_command mkdir
  require_command sed
  require_command sha256sum
  require_command sort
  require_command tar
}

validate_release_name() {
  case "$RELEASE_NAME" in
    ""|.*|*/*|*\\*|*" "*)
      fatal "release name must be non-empty and must not contain spaces, slashes, or start with dot"
      ;;
  esac

  if ! printf '%s' "$RELEASE_NAME" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    fatal "release name contains unsupported characters: $RELEASE_NAME"
  fi
}

absolute_dir() {
  local input="$1"
  local parent
  local leaf

  parent="$(dirname "$input")"
  leaf="$(basename "$input")"

  mkdir -p "$parent"
  parent="$(cd "$parent" && pwd)"

  printf '%s/%s\n' "$parent" "$leaf"
}

initialize_paths() {
  RELEASE_ROOT="$(absolute_dir "$RELEASE_ROOT")"
  WORK_ROOT="$RELEASE_ROOT/.build/$RELEASE_NAME"
  STAGE_DIR="$WORK_ROOT/$RELEASE_NAME"
  BUNDLE_FILE="$RELEASE_ROOT/$RELEASE_NAME.tar.gz"
  CHECKSUM_FILE="$BUNDLE_FILE.sha256"
}

print_plan() {
  log "bundle-only release build"
  log "  source repo: $SCRIPT_DIR"
  log "  release name: $RELEASE_NAME"
  log "  output dir: $RELEASE_ROOT"
  log "  bundle: $BUNDLE_FILE"
  log "  checksum: $CHECKSUM_FILE"
  log "  include image/archive artifacts: $INCLUDE_IMAGE_ARCHIVES"
  log "  deploy/provision/live validation: disabled"
}

assert_not_root_required() {
  if [ "$(id -u)" -eq 0 ]; then
    warn "running as root is not required for bundle creation"
  fi
}

assert_repo_shape() {
  if [ ! -d "$SCRIPT_DIR" ]; then
    fatal "script directory does not exist: $SCRIPT_DIR"
  fi

  if [ ! -f "$SCRIPT_DIR/setup.sh" ]; then
    fatal "setup.sh not found in script directory: $SCRIPT_DIR"
  fi

  if [ ! -d "$SCRIPT_DIR/automation" ] && [ ! -d "$SCRIPT_DIR/scripts" ] && [ ! -d "$SCRIPT_DIR/manifests" ] && [ ! -d "$SCRIPT_DIR/k8s" ]; then
    warn "no common project directories found: automation, scripts, manifests, or k8s"
    warn "continuing because a sanitized repository snapshot can still be bundled"
  fi
}

prepare_stage() {
  rm -rf "$WORK_ROOT"
  mkdir -p "$STAGE_DIR"
  mkdir -p "$STAGE_DIR/metadata"
  mkdir -p "$STAGE_DIR/source"
  mkdir -p "$STAGE_DIR/artifacts"
  mkdir -p "$STAGE_DIR/runbooks"
}

git_value() {
  local args=("$@")

  if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" "${args[@]}" 2>/dev/null || true
  fi
}

write_metadata() {
  local commit
  local branch
  local dirty
  local created_utc

  created_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  commit="$(git_value rev-parse HEAD)"
  branch="$(git_value rev-parse --abbrev-ref HEAD)"

  dirty="unknown"
  if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$SCRIPT_DIR" diff --quiet -- . && git -C "$SCRIPT_DIR" diff --cached --quiet -- .; then
      dirty="no"
    else
      dirty="yes"
    fi
  fi

  cat > "$STAGE_DIR/metadata/release.env" <<EOF_METADATA
RELEASE_NAME="$RELEASE_NAME"
CREATED_UTC="$created_utc"
SOURCE_DIR="$SCRIPT_DIR"
GIT_BRANCH="${branch:-unknown}"
GIT_COMMIT="${commit:-unknown}"
GIT_DIRTY="$dirty"
BUNDLE_ONLY="1"
DEPLOYMENT_EXECUTED="0"
ANSIBLE_EXECUTED="0"
K3S_INSTALLED="0"
KUBECTL_APPLIED="0"
HELM_EXECUTED="0"
IMAGES_IMPORTED_TO_CLUSTER="0"
LIVE_CLUSTER_VALIDATED="0"
PRODUCTION_SERVER_RECEIVES_ONLY_FINISHED_BUNDLE="1"
EOF_METADATA

  cat > "$STAGE_DIR/metadata/policy.txt" <<'EOF_POLICY'
Bundle-only release policy

This release was produced as a sealed handoff bundle.

The build path must not:
- install K3s
- apply Kubernetes resources
- import images into a live cluster
- run Helm install/upgrade against a cluster
- roll out deployments
- install GitHub runners
- provision worker VMs
- validate a live cluster

The production server receives only the finished bundle.
EOF_POLICY
}

copy_repo_snapshot() {
  log "copying sanitized repository snapshot"

  (
    cd "$SCRIPT_DIR"

    tar \
      --exclude='./.git' \
      --exclude='./.github/actions-runner' \
      --exclude='./.env' \
      --exclude='./.env.*' \
      --exclude='./*.env' \
      --exclude='./releases' \
      --exclude='./dist' \
      --exclude='./build' \
      --exclude='./tmp' \
      --exclude='./.cache' \
      --exclude='./__pycache__' \
      --exclude='./*.pyc' \
      --exclude='./*.qcow2' \
      --exclude='./*.iso' \
      --exclude='./*.img' \
      --exclude='./*.pem' \
      --exclude='./*.key' \
      --exclude='./id_rsa' \
      --exclude='./id_ed25519' \
      --exclude='./otp-relay-cluster' \
      --exclude='./kubeconfig' \
      --exclude='./kubeconfig.*' \
      --exclude='./admin.conf' \
      -cf - .
  ) | (
    cd "$STAGE_DIR/source"
    tar -xf -
  )
}

copy_existing_image_archives() {
  local src
  local dest="$STAGE_DIR/artifacts/image-archives"
  local copied="0"

  if [ "$INCLUDE_IMAGE_ARCHIVES" != "1" ]; then
    log "skipping image/archive artifact copy"
    return 0
  fi

  mkdir -p "$dest"

  for src in \
    "$SCRIPT_DIR/images" \
    "$SCRIPT_DIR/image-archives" \
    "$SCRIPT_DIR/release-images" \
    "$SCRIPT_DIR/artifacts/images" \
    "$SCRIPT_DIR/artifacts/image-archives" \
    "$SCRIPT_DIR/output/images" \
    "$SCRIPT_DIR/output/image-archives"; do
    if [ -d "$src" ]; then
      log "copying existing image/archive artifacts from: $src"
      find "$src" -type f \( \
        -name '*.tar' -o \
        -name '*.tar.gz' -o \
        -name '*.tgz' -o \
        -name '*.oci' -o \
        -name '*.oci.tar' -o \
        -name '*.oci.tar.gz' \
      \) -print0 |
        while IFS= read -r -d '' file; do
          cp -f "$file" "$dest/"
          copied="1"
        done
    fi
  done

  if ! find "$dest" -type f | grep -q .; then
    rmdir "$dest"
    warn "no existing image/archive artifacts found to copy"
    warn "this script does not build or import images; add image archives before release if required"
  elif [ "$copied" = "1" ]; then
    log "image/archive artifacts copied"
  fi
}

write_prod_runbook() {
  cat > "$STAGE_DIR/runbooks/PROD_HANDOFF.md" <<'EOF_RUNBOOK'
# OTP Relay Production Release Handoff

This is a sealed production release bundle.

## Important boundary

This bundle was built without deploying anything.

The build path did not:

- install K3s
- apply Kubernetes resources
- import images into a live cluster
- run Helm install/upgrade
- roll out deployments
- install GitHub runners
- provision worker VMs
- validate a live cluster

The production server receives only this finished bundle.

## Files

- `metadata/release.env` contains release identity and source metadata.
- `metadata/policy.txt` records the bundle-only policy.
- `source/` contains the sanitized source snapshot used to build the handoff.
- `artifacts/` may contain prebuilt image/archive artifacts if they existed before bundling.
- `CHECKSUMS.sha256` contains checksums for all files inside the expanded bundle.

## Verification on production

After copying the bundle to production, verify the tarball checksum before extracting:

```bash
sha256sum -c otp-relay-prod-release-*.tar.gz.sha256
