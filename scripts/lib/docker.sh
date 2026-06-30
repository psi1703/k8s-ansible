#!/usr/bin/env bash
# Shared Docker/image-build helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Docker may be used only on the dev/build host to build local image archives.
#   - This file must not install Docker automatically.
#   - This file must not import images into K3s/containerd.
#   - This file must not contact or mutate a Kubernetes cluster.
#
# The production server receives only the finished bundle.

resolve_docker_bin() {
  if [ -n "${DOCKER_BIN:-}" ] && [ -x "$DOCKER_BIN" ]; then
    return 0
  fi

  if cmd_exists docker; then
    DOCKER_BIN="$(command -v docker)"
    export DOCKER_BIN
    return 0
  fi

  for candidate in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker; do
    if [ -x "$candidate" ]; then
      DOCKER_BIN="$candidate"
      export DOCKER_BIN
      return 0
    fi
  done

  return 1
}

ensure_docker() {
  log "checking Docker CLI availability for local image archive export"

  if ! resolve_docker_bin; then
    fatal "Docker CLI is required to build/export release image archives, but it was not found. Install Docker on the dev/build host before running the bundle builder."
  fi

  log "using Docker CLI: $DOCKER_BIN"

  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    fatal "Docker CLI is available at $DOCKER_BIN, but the Docker daemon is not responding. Start Docker on the dev/build host before building the bundle."
  fi

  log "Docker is ready for local bundle image builds"
}

image_ref_for_archive_name() {
  local image_ref="$1"

  printf '%s' "$image_ref" \
    | sed 's#[/:@]#-#g; s/[^A-Za-z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

docker_build_image() {
  local image_ref="$1"
  local dockerfile="$2"
  local context_dir="${3:-.}"

  [ -n "$image_ref" ] || fatal "docker_build_image requires image reference"
  [ -n "$dockerfile" ] || fatal "docker_build_image requires Dockerfile path"
  [ -f "$dockerfile" ] || fatal "Dockerfile not found: $dockerfile"
  [ -d "$context_dir" ] || fatal "Docker build context directory not found: $context_dir"

  ensure_docker

  log "building local image for release archive: $image_ref"
  "$DOCKER_BIN" build \
    -t "$image_ref" \
    -f "$dockerfile" \
    "$context_dir"

  log "local image build completed: $image_ref"
}

docker_save_image_archive() {
  local image_ref="$1"
  local output_tar="$2"

  [ -n "$image_ref" ] || fatal "docker_save_image_archive requires image reference"
  [ -n "$output_tar" ] || fatal "docker_save_image_archive requires output tar path"

  ensure_docker

  mkdir -p "$(dirname "$output_tar")"

  log "exporting local image archive: $image_ref -> $output_tar"
  "$DOCKER_BIN" image inspect "$image_ref" >/dev/null 2>&1 ||
    fatal "Docker image does not exist locally after build: $image_ref"

  "$DOCKER_BIN" save -o "$output_tar" "$image_ref"

  [ -s "$output_tar" ] || fatal "Docker image archive was not created or is empty: $output_tar"
  log "image archive exported: $output_tar"
}

docker_write_image_digest_metadata() {
  local image_ref="$1"
  local output_file="$2"
  local image_id=""

  ensure_docker

  image_id="$("$DOCKER_BIN" image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true)"
  [ -n "$image_id" ] || fatal "could not inspect Docker image ID for $image_ref"

  mkdir -p "$(dirname "$output_file")"

  {
    printf 'IMAGE_REF=%s\n' "$image_ref"
    printf 'IMAGE_ID=%s\n' "$image_id"
    printf 'BUNDLE_ONLY=1\n'
    printf 'IMPORTED_TO_CLUSTER=0\n'
  } > "$output_file"
}

build_and_export_image_archive() {
  local image_ref="$1"
  local dockerfile="$2"
  local output_tar="$3"
  local context_dir="${4:-.}"
  local metadata_file

  docker_build_image "$image_ref" "$dockerfile" "$context_dir"
  docker_save_image_archive "$image_ref" "$output_tar"

  metadata_file="${output_tar}.metadata.env"
  docker_write_image_digest_metadata "$image_ref" "$metadata_file"

  if declare -F validate_image_archive_file >/dev/null 2>&1; then
    validate_image_archive_file "$image_ref" "$output_tar"
  fi

  log "image archive metadata written: $metadata_file"
}

release_image_tag() {
  local base_ref="$1"
  local fallback_name="$2"
  local release_tag="${RELEASE_TAG:-${GIT_SHORT_SHA:-bundle}}"

  if [ -n "$base_ref" ]; then
    case "$base_ref" in
      *:*)
        printf '%s\n' "$base_ref"
        ;;
      *)
        printf '%s:%s\n' "$base_ref" "$release_tag"
        ;;
    esac
    return 0
  fi

  printf 'otp-relay/%s:%s\n' "$fallback_name" "$release_tag"
}

export_release_images_if_required() {
  local image_output_dir
  local app_image_ref
  local monitor_image_ref
  local app_archive_name
  local monitor_archive_name

  if [ "${DEPLOY_MODE:-full}" = "none" ]; then
    log "artifact selector DEPLOY_MODE=none; skipping release image archive export"
    return 0
  fi

  [ -n "${GENERATED_DIR:-}" ] || fatal "GENERATED_DIR is not set; stage manifests before exporting images"

  image_output_dir="$GENERATED_DIR/images"
  mkdir -p "$image_output_dir"

  if declare -F assert_image_distribution_disabled >/dev/null 2>&1; then
    assert_image_distribution_disabled
  fi

  if requires_app_image; then
    [ -n "${APP_DOCKERFILE:-}" ] || fatal "APP_DOCKERFILE is not set"
    [ -f "$APP_DOCKERFILE" ] || fatal "app Dockerfile is missing: $APP_DOCKERFILE"

    app_image_ref="$(release_image_tag "${APP_IMAGE:-}" "otp-relay-app")"
    APP_IMAGE="$app_image_ref"
    export APP_IMAGE

    app_archive_name="$(image_ref_for_archive_name "$app_image_ref").tar"
    build_and_export_image_archive \
      "$app_image_ref" \
      "$APP_DOCKERFILE" \
      "$image_output_dir/$app_archive_name" \
      "."

    log "app image archive ready for bundle: $image_output_dir/$app_archive_name"
  else
    log "artifact selector does not require app image archive"
  fi

  if requires_monitor_image; then
    [ -n "${MONITOR_DOCKERFILE:-}" ] || fatal "MONITOR_DOCKERFILE is not set"
    [ -f "$MONITOR_DOCKERFILE" ] || fatal "monitor Dockerfile is missing: $MONITOR_DOCKERFILE"

    monitor_image_ref="$(release_image_tag "${MONITOR_IMAGE:-}" "otp-relay-monitor")"
    MONITOR_IMAGE="$monitor_image_ref"
    export MONITOR_IMAGE

    monitor_archive_name="$(image_ref_for_archive_name "$monitor_image_ref").tar"
    build_and_export_image_archive \
      "$monitor_image_ref" \
      "$MONITOR_DOCKERFILE" \
      "$image_output_dir/$monitor_archive_name" \
      "."

    log "monitor image archive ready for bundle: $image_output_dir/$monitor_archive_name"
  else
    log "artifact selector does not require monitor image archive"
  fi

  log "release image archive export completed"
}
