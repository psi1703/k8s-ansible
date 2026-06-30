#!/usr/bin/env bash
# Shared image artifact helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Build/export image archives only.
#   - Do not import images into a live cluster.
#   - Do not query Kubernetes nodes.
#   - Do not create Kubernetes DaemonSets.
#   - Do not run kubectl/k3s kubectl.
#   - Do not start temporary HTTP image distribution servers for cluster nodes.
#
# The production server receives only the finished bundle.

image_distribution_server_ip() {
  # Kept only for compatibility with older references.
  # Bundle-only release builds must not distribute images to cluster nodes.
  if [ -n "${IMAGE_DISTRIBUTION_HOST:-}" ]; then
    printf '%s\n' "$IMAGE_DISTRIBUTION_HOST"
    return 0
  fi

  if [ -n "${SERVER_IP:-}" ] && [ "$SERVER_IP" != "127.0.0.1" ]; then
    printf '%s\n' "$SERVER_IP"
    return 0
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

sanitize_k8s_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-48
}

_forbid_live_image_distribution() {
  local action="$1"

  fatal "forbidden live image operation in bundle-only mode: $action"
}

wait_for_importer_logs() {
  _forbid_live_image_distribution "waiting for Kubernetes image importer pod logs"
}

distribute_image_tar_to_all_nodes() {
  _forbid_live_image_distribution "distributing image tar to live K3s nodes"
}

validate_image_archive_file() {
  local image_name="$1"
  local tar_path="$2"

  [ -n "$image_name" ] || fatal "image name is empty"
  [ -n "$tar_path" ] || fatal "image archive path is empty for $image_name"
  [ -f "$tar_path" ] || fatal "image archive does not exist for $image_name: $tar_path"
  [ -s "$tar_path" ] || fatal "image archive is empty for $image_name: $tar_path"

  case "$tar_path" in
    *.tar|*.tar.gz|*.tgz|*.oci|*.oci.tar|*.oci.tar.gz) ;;
    *)
      warn "image archive has an unusual extension for $image_name: $tar_path"
      ;;
  esac
}

image_archive_checksum() {
  local tar_path="$1"

  [ -f "$tar_path" ] || fatal "cannot checksum missing image archive: $tar_path"
  sha256sum "$tar_path" | awk '{print $1}'
}

write_image_archive_metadata() {
  local image_name="$1"
  local tar_path="$2"
  local metadata_file="$3"
  local checksum

  validate_image_archive_file "$image_name" "$tar_path"
  checksum="$(image_archive_checksum "$tar_path")"

  mkdir -p "$(dirname "$metadata_file")"

  {
    printf 'IMAGE_NAME=%s\n' "$image_name"
    printf 'IMAGE_ARCHIVE=%s\n' "$(basename "$tar_path")"
    printf 'IMAGE_ARCHIVE_SHA256=%s\n' "$checksum"
    printf 'BUNDLE_ONLY=1\n'
    printf 'IMPORTED_TO_CLUSTER=0\n'
  } > "$metadata_file"
}

copy_image_archive_to_release_dir() {
  local image_name="$1"
  local tar_path="$2"
  local release_image_dir="$3"
  local dest_path
  local metadata_file

  validate_image_archive_file "$image_name" "$tar_path"

  mkdir -p "$release_image_dir"
  dest_path="$release_image_dir/$(basename "$tar_path")"

  log "copying image archive for bundle: $image_name -> $dest_path"
  cp -f "$tar_path" "$dest_path"

  metadata_file="$release_image_dir/$(basename "$tar_path").metadata.env"
  write_image_archive_metadata "$image_name" "$dest_path" "$metadata_file"

  log "image archive staged for bundle: $dest_path"
}

collect_existing_image_archives() {
  local output_file="$1"
  local search_dir

  : > "$output_file"

  for search_dir in \
    "${GENERATED_DIR:-}/images" \
    "${GENERATED_DIR:-}/image-archives" \
    "${SCRIPT_DIR:-.}/images" \
    "${SCRIPT_DIR:-.}/image-archives" \
    "${SCRIPT_DIR:-.}/artifacts/images" \
    "${SCRIPT_DIR:-.}/artifacts/image-archives" \
    "${SCRIPT_DIR:-.}/dist/images" \
    "${SCRIPT_DIR:-.}/dist/image-archives"; do
    [ -n "$search_dir" ] || continue
    [ -d "$search_dir" ] || continue

    find "$search_dir" -maxdepth 1 -type f \( \
      -name '*.tar' -o \
      -name '*.tar.gz' -o \
      -name '*.tgz' -o \
      -name '*.oci' -o \
      -name '*.oci.tar' -o \
      -name '*.oci.tar.gz' \
    \) -print >> "$output_file"
  done

  sort -u "$output_file" -o "$output_file"
}

stage_existing_image_archives_for_bundle() {
  local release_image_dir="$1"
  local archive_list
  local archive
  local image_name

  archive_list="$(mktemp /tmp/otp-relay-image-archives.XXXXXX)"
  collect_existing_image_archives "$archive_list"

  if [ ! -s "$archive_list" ]; then
    rm -f "$archive_list"
    warn "no existing image archives found to stage"
    warn "image build/export may be handled by scripts/lib/docker.sh or another bundle phase"
    return 0
  fi

  while IFS= read -r archive; do
    [ -n "$archive" ] || continue
    image_name="$(basename "$archive")"
    copy_image_archive_to_release_dir "$image_name" "$archive" "$release_image_dir"
  done < "$archive_list"

  rm -f "$archive_list"
}

assert_image_distribution_disabled() {
  [ "${DISTRIBUTE_IMAGES_TO_NODES:-0}" != "1" ] ||
    fatal "DISTRIBUTE_IMAGES_TO_NODES=1 is forbidden in bundle-only mode"

  [ "${SKIP_IMAGE_IMPORT:-1}" = "1" ] ||
    fatal "SKIP_IMAGE_IMPORT must be 1 in bundle-only mode"
}
