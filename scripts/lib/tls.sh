#!/usr/bin/env bash
# TLS helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Validate TLS/Ingress values used for rendered manifests.
#   - Optionally stage certificate material as handoff files only when already provided.
#   - Do not create Kubernetes secrets.
#   - Do not apply Kubernetes resources.
#   - Do not query a live cluster.
#
# The production server receives only the finished bundle.

_tls_forbid_live_action() {
  local action="$1"

  fatal "forbidden TLS live-cluster action in bundle-only mode: $action"
}

validate_tls_settings_for_bundle() {
  log "validating TLS settings for bundle rendering"

  case "${TLS_ENABLED:-0}" in
    0|1) ;;
    *) fatal "TLS_ENABLED must be 0 or 1" ;;
  esac

  case "${TLS_SELF_SIGNED:-0}" in
    0|1) ;;
    *) fatal "TLS_SELF_SIGNED must be 0 or 1" ;;
  esac

  if [ "${TLS_ENABLED:-0}" = "1" ]; then
    [ "${INGRESS_ENABLED:-0}" = "1" ] || fatal "TLS_ENABLED=1 requires INGRESS_ENABLED=1"
    [ -n "${TLS_HOST:-}" ] || fatal "TLS_ENABLED=1 requires TLS_HOST"
    [ -n "${TLS_SECRET_NAME:-}" ] || fatal "TLS_ENABLED=1 requires TLS_SECRET_NAME"

    if [ "${TLS_HOST:-}" = "CHANGE_ME_TLS_HOST" ] || [ "${TLS_HOST:-}" = "otp-relay.local" ]; then
      fatal "TLS_HOST must be changed from the default when TLS_ENABLED=1"
    fi

    log "TLS will be referenced in rendered manifests: host=${TLS_HOST} secret=${TLS_SECRET_NAME}"
  else
    log "TLS disabled for rendered ingress"
  fi
}

stage_tls_handoff_if_requested() {
  local tls_stage_dir=""

  validate_tls_settings_for_bundle

  if [ "${TLS_ENABLED:-0}" != "1" ]; then
    return 0
  fi

  [ -n "${GENERATED_DIR:-}" ] || fatal "GENERATED_DIR is not set; cannot stage TLS handoff note"

  tls_stage_dir="$GENERATED_DIR/tls"
  mkdir -p "$tls_stage_dir"

  cat > "$tls_stage_dir/README.md" <<EOF_TLS
# TLS production handoff

TLS was enabled during bundle rendering.

Rendered values:

- TLS_HOST: ${TLS_HOST:-}
- TLS_SECRET_NAME: ${TLS_SECRET_NAME:-}
- TLS_SELF_SIGNED: ${TLS_SELF_SIGNED:-0}

The bundle builder does not create Kubernetes TLS secrets.

Production-side secret creation must be handled by the approved production
procedure before or during manifest application.

Expected Kubernetes secret name:

\`\`\`text
${TLS_SECRET_NAME:-otp-relay-tls}
\`\`\`

Expected namespace:

\`\`\`text
${NAMESPACE:-otp-relay-devprod}
\`\`\`
EOF_TLS

  chmod 0644 "$tls_stage_dir/README.md" 2>/dev/null || true
  log "TLS handoff note staged: $tls_stage_dir/README.md"
}

ensure_tls_secret_if_requested() {
  stage_tls_handoff_if_requested

  if [ "${TLS_ENABLED:-0}" = "1" ]; then
    log "skipping Kubernetes TLS secret creation in bundle-only mode"
  fi
}

create_self_signed_tls_secret() {
  _tls_forbid_live_action "create self-signed Kubernetes TLS secret"
}

apply_tls_secret_manifest() {
  _tls_forbid_live_action "apply TLS secret manifest"
}

tls_secret_exists() {
  _tls_forbid_live_action "query TLS secret existence"
}

print_tls_diagnostics() {
  log "skipping TLS diagnostics in bundle-only mode"
}
