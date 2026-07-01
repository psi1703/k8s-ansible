#!/usr/bin/env bash
# Release bundle packaging helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Package staged manifests, observability files, image archives, metadata, and handoff docs.
#   - Do not deploy.
#   - Do not install K3s.
#   - Do not run Helm.
#   - Do not run kubectl.
#   - Do not import images.
#   - Do not validate a live cluster.
#
# The production server receives only the finished bundle.

_release_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

_release_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

_release_timestamp() {
  date -u '+%Y%m%d-%H%M%S' 2>/dev/null || date '+%Y%m%d-%H%M%S'
}

_release_git_short_sha() {
  git rev-parse --short HEAD 2>/dev/null || printf 'nogit'
}

_release_git_full_sha() {
  git rev-parse HEAD 2>/dev/null || printf 'nogit'
}

_release_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown'
}

_release_git_subject() {
  git log -1 --pretty=%s 2>/dev/null || printf 'local-files'
}

_release_sanitize_name() {
  local value="${1:-release}"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"

  if [ -z "$value" ]; then
    value="release"
  fi

  printf '%s' "$value"
}

_release_require_file() {
  local file="$1"
  local label="${2:-$1}"

  [ -f "$file" ] || fatal "required release file missing: $label ($file)"
  [ -s "$file" ] || fatal "required release file is empty: $label ($file)"
}

_release_require_dir() {
  local dir="$1"
  local label="${2:-$1}"

  [ -d "$dir" ] || fatal "required release directory missing: $label ($dir)"
}

_release_abs_path() {
  local input_path="$1"
  local base_dir="${2:-$SCRIPT_DIR}"

  if [ -z "$input_path" ]; then
    return 1
  fi

  case "$input_path" in
    /*)
      printf '%s' "$input_path"
      ;;
    *)
      printf '%s/%s' "$base_dir" "$input_path"
      ;;
  esac
}

_release_forbid_live_tooling_in_path() {
  local scan_dir="$1"
  local found=""

  [ -d "$scan_dir" ] || return 0

  # Scan executable-like payloads only.
  # Do not scan .md/.txt handoff documents; those intentionally explain which
  # live operations are outside the build path.
  found="$(
    grep -RInE \
      '(^|[^A-Za-z0-9_-])(k3s[[:space:]]+kubectl|kubectl[[:space:]]+apply|kubectl[[:space:]]+rollout|helm[[:space:]]+(install|upgrade|repo|dependency)|k3s[[:space:]]+ctr[[:space:]]+images[[:space:]]+import|ansible-playbook|virsh|virt-install|get\.k3s\.io)([^A-Za-z0-9_-]|$)' \
      "$scan_dir" \
      --include='*.sh' \
      --include='*.bash' \
      --include='*.yaml' \
      --include='*.yml' \
      2>/dev/null || true
  )"

  if [ -n "$found" ]; then
    warn "release bundle staging contains live-deploy command references in executable or YAML payloads:"
    printf '%s\n' "$found" >&2
    fatal "release bundle must not package live-deploy executable paths"
  fi
}

_release_copy_if_exists() {
  local source_path="$1"
  local dest_path="$2"

  if [ -e "$source_path" ]; then
    mkdir -p "$(dirname "$dest_path")"
    cp -a "$source_path" "$dest_path"
  fi
}

_release_copy_tree_if_exists() {
  local source_dir="$1"
  local dest_dir="$2"

  if [ -d "$source_dir" ]; then
    mkdir -p "$(dirname "$dest_dir")"
    rm -rf "$dest_dir"
    cp -a "$source_dir" "$dest_dir"
  fi
}

_release_write_metadata() {
  local bundle_root="$1"
  local metadata_file="$bundle_root/metadata/release.env"

  mkdir -p "$(dirname "$metadata_file")"

  cat > "$metadata_file" <<EOF_METADATA
RELEASE_MODE="bundle"
RELEASE_CREATED_UTC="$(_release_now_utc)"
RELEASE_NAME="${RELEASE_NAME:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
RELEASE_BUNDLE_NAME="${RELEASE_BUNDLE_NAME:-}"
DEPLOY_MODE="${DEPLOY_MODE:-full}"
NAMESPACE="${NAMESPACE:-otp-relay-devprod}"
GIT_BRANCH="$(_release_git_branch)"
GIT_COMMIT="$(_release_git_full_sha)"
GIT_SHORT_SHA="$(_release_git_short_sha)"
GIT_SUBJECT="$(_release_git_subject)"
PORTAL_URL="${PORTAL_URL:-}"
SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"
INGRESS_ENABLED="${INGRESS_ENABLED:-0}"
TLS_ENABLED="${TLS_ENABLED:-0}"
TLS_HOST="${TLS_HOST:-}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"
NFS_ENABLED="${NFS_ENABLED:-0}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-}"
PVC_STORAGE_CLASS="${PVC_STORAGE_CLASS:-}"
PVC_SIZE="${PVC_SIZE:-}"
REDIS_ENABLED="${REDIS_ENABLED:-0}"
REDIS_URL="${REDIS_URL:-}"
REDIS_REQUIRED="${REDIS_REQUIRED:-0}"
REDIS_STORAGE_CLASS="${REDIS_STORAGE_CLASS:-}"
REDIS_SIZE="${REDIS_SIZE:-}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
OBSERVABILITY_INSTALL_STACK="${OBSERVABILITY_INSTALL_STACK:-0}"
GRAFANA_HOST="${GRAFANA_HOST:-}"
APP_IMAGE="${APP_IMAGE:-}"
MONITOR_IMAGE="${MONITOR_IMAGE:-}"
SKIP_CLUSTER_DEPLOY="1"
SKIP_K3S_INSTALL="1"
SKIP_HELM_INSTALL="1"
SKIP_KUBECTL_APPLY="1"
SKIP_IMAGE_IMPORT="1"
SKIP_ROLLOUT_RESTART="1"
SKIP_LIVE_CLUSTER_VALIDATE="1"
SKIP_GITHUB_RUNNER_INSTALL="1"
SKIP_VM_PROVISIONING="1"
EOF_METADATA

  chmod 0644 "$metadata_file" 2>/dev/null || true
}

_release_write_manifest_index() {
  local bundle_root="$1"
  local index_file="$bundle_root/metadata/file-index.txt"

  mkdir -p "$(dirname "$index_file")"

  (
    cd "$bundle_root"
    find . -type f | sed 's#^\./##' | sort
  ) > "$index_file"

  chmod 0644 "$index_file" 2>/dev/null || true
}

_release_write_checksums() {
  local bundle_root="$1"
  local checksum_file="$bundle_root/metadata/SHA256SUMS"

  mkdir -p "$(dirname "$checksum_file")"

  (
    cd "$bundle_root"
    find . -type f \
      ! -path './metadata/SHA256SUMS' \
      ! -path './metadata/file-index.txt' \
      -print0 |
      sort -z |
      xargs -0 sha256sum
  ) > "$checksum_file"

  chmod 0644 "$checksum_file" 2>/dev/null || true
}

_release_write_handoff_readme() {
  local bundle_root="$1"
  local readme_file="$bundle_root/PROD-HANDOFF.md"

  cat > "$readme_file" <<EOF_README
# OTP Relay production release bundle

Generated: $(_release_now_utc)

This bundle was produced by the DEV/build-side bundle builder.

## Contract

The production server receives only this finished bundle.

This build path did not:

- install K3s
- install Helm
- run kubectl apply
- run Helm install or upgrade
- import images into a live cluster
- restart Kubernetes deployments
- provision VMs
- install GitHub Actions runners
- validate a live cluster

## Included content

- rendered Kubernetes manifests under \`manifests/\`
- observability YAML/value files under \`observability/\`, when present
- image archives under \`images/\`, when requested by the artifact selector
- release metadata under \`metadata/\`
- checksum files for handoff verification

## Production-side responsibility

Production-side installation, image loading, Helm execution, kubectl apply,
rollout validation, secret handling, and operational checks are intentionally
outside this build path and must be performed only by the approved production
procedure.
EOF_README

  chmod 0644 "$readme_file" 2>/dev/null || true
}

_release_stage_runtime_secret_note() {
  local bundle_root="$1"
  local secret_note="$bundle_root/metadata/secret-handoff.txt"

  cat > "$secret_note" <<EOF_SECRET
OTP Relay secret handoff note
Generated: $(_release_now_utc)

This bundle builder does not create Kubernetes secrets.

The following secret-backed runtime values were present in the build environment
and must be handled by the approved production-side secret procedure:

SMS_SECRET_TOKEN: ${SMS_SECRET_TOKEN:+set}
TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:+set}
TELEGRAM_CHAT_ID: ${TELEGRAM_CHAT_ID:+set}

Do not commit populated .env files.
Do not print production secrets into logs.
EOF_SECRET

  chmod 0600 "$secret_note" 2>/dev/null || true
}

_release_stage_bundle_tree() {
  local bundle_root="$1"

  mkdir -p "$bundle_root"
  mkdir -p "$bundle_root/metadata"

  _release_require_dir "${GENERATED_DIR:-}" "generated staging directory"

  if [ "${DEPLOY_MODE:-full}" != "none" ]; then
    _release_require_dir "${MANIFEST_DIR:-}" "rendered manifest directory"
    _release_copy_tree_if_exists "$MANIFEST_DIR" "$bundle_root/manifests"
  fi

  _release_copy_tree_if_exists "${OBSERVABILITY_DIR:-}" "$bundle_root/observability"
  _release_copy_tree_if_exists "${GENERATED_DIR:-}/images" "$bundle_root/images"

  _release_copy_if_exists "${INSTALL_DIR:-$SCRIPT_DIR}/.env" "$bundle_root/metadata/build.env"
  _release_copy_if_exists "${GENERATED_DIR:-}/app-image-frontend-app.js" "$bundle_root/metadata/app-image-frontend-app.js"

  _release_write_metadata "$bundle_root"
  _release_stage_runtime_secret_note "$bundle_root"
  _release_write_handoff_readme "$bundle_root"
  _release_write_manifest_index "$bundle_root"
  _release_write_checksums "$bundle_root"
}

_release_validate_bundle_tree() {
  local bundle_root="$1"

  _release_require_file "$bundle_root/PROD-HANDOFF.md" "production handoff readme"
  _release_require_file "$bundle_root/metadata/release.env" "release metadata"
  _release_require_file "$bundle_root/metadata/SHA256SUMS" "bundle checksums"
  _release_require_file "$bundle_root/metadata/file-index.txt" "bundle file index"

  if [ "${DEPLOY_MODE:-full}" != "none" ]; then
    _release_require_dir "$bundle_root/manifests" "bundled rendered manifests"
  fi

  _release_forbid_live_tooling_in_path "$bundle_root"
}

stage_release_bundle_if_required() {
  local dist_dir=""
  local release_stamp=""
  local git_sha=""
  local safe_namespace=""
  local bundle_root=""
  local bundle_tar=""
  local checksum_path=""

  [ -n "${GENERATED_DIR:-}" ] || fatal "GENERATED_DIR is not set; stage manifests before creating release bundle"

  release_stamp="$(_release_timestamp)"
  git_sha="$(_release_git_short_sha)"
  safe_namespace="$(_release_sanitize_name "${NAMESPACE:-otp-relay}")"

  RELEASE_TAG="${RELEASE_TAG:-${release_stamp}-${git_sha}}"
  RELEASE_NAME="${RELEASE_NAME:-otp-relay-k8s-${safe_namespace}-${RELEASE_TAG}}"
  RELEASE_BUNDLE_NAME="${RELEASE_BUNDLE_NAME:-${RELEASE_NAME}.tar.gz}"

  dist_dir="$(_release_abs_path "${DIST_DIR:-dist}" "$SCRIPT_DIR")"
  mkdir -p "$dist_dir"

  bundle_root="${GENERATED_DIR}/${RELEASE_NAME}"
  bundle_tar="${dist_dir}/${RELEASE_BUNDLE_NAME}"
  checksum_path="${bundle_tar}.sha256"

  export RELEASE_TAG
  export RELEASE_NAME
  export RELEASE_BUNDLE_NAME

  log "staging release bundle tree: $bundle_root"
  rm -rf "$bundle_root"
  _release_stage_bundle_tree "$bundle_root"
  _release_validate_bundle_tree "$bundle_root"

  log "creating sealed release bundle: $bundle_tar"
  rm -f "$bundle_tar" "$checksum_path"

  (
    cd "$GENERATED_DIR"
    tar -czf "$bundle_tar" "$RELEASE_NAME"
  )

  _release_require_file "$bundle_tar" "release tarball"

  log "writing release bundle checksum: $checksum_path"
  (
    cd "$(dirname "$bundle_tar")"
    sha256sum "$(basename "$bundle_tar")"
  ) > "$checksum_path"

  _release_require_file "$checksum_path" "release checksum"

  RELEASE_BUNDLE_PATH="$bundle_tar"
  RELEASE_BUNDLE_SHA256_PATH="$checksum_path"
  BUNDLE_PATH="$bundle_tar"
  BUNDLE_SHA256_PATH="$checksum_path"

  export RELEASE_BUNDLE_PATH
  export RELEASE_BUNDLE_SHA256_PATH
  export BUNDLE_PATH
  export BUNDLE_SHA256_PATH

  log "release bundle staged successfully"
  log "bundle: $RELEASE_BUNDLE_PATH"
  log "checksum: $RELEASE_BUNDLE_SHA256_PATH"
}
