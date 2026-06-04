#!/usr/bin/env bash
# Shared TLS helpers for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

ensure_tls_secret_available_if_required() {
  [ "${TLS_ENABLED:-0}" = "1" ] || return 0
  [ "${TLS_SELF_SIGNED:-1}" = "0" ] || return 0

  if k3s kubectl get secret "$TLS_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "TLS secret $TLS_SECRET_NAME already exists in namespace $NAMESPACE"
    return 0
  fi

  fatal "TLS_ENABLED=1 with TLS_SELF_SIGNED=0 requires an existing Kubernetes TLS secret named $TLS_SECRET_NAME in namespace $NAMESPACE. Create the TLS secret first, or set TLS_SELF_SIGNED=1 so the installer can create a self-signed secret."
}

ensure_tls_secret_if_requested() {
  [ "${TLS_ENABLED:-0}" = "1" ] || return 0
  [ "${TLS_SELF_SIGNED:-1}" = "1" ] || return 0

  local tls_tmp_dir=""
  local tls_key=""
  local tls_crt=""
  local rotate_self_signed="${TLS_ROTATE_SELF_SIGNED:-0}"

  if k3s kubectl get secret "$TLS_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    if [ "$rotate_self_signed" != "1" ]; then
      log "self-signed TLS secret $TLS_SECRET_NAME already exists in namespace $NAMESPACE; keeping existing certificate"
      log "set TLS_ROTATE_SELF_SIGNED=1 only when you intentionally want to replace the certificate"
      return 0
    fi

    warn "TLS_ROTATE_SELF_SIGNED=1; replacing existing self-signed TLS secret $TLS_SECRET_NAME in namespace $NAMESPACE"
  fi

  [ -n "${TLS_HOST:-}" ] || fatal "TLS_HOST is required when TLS_ENABLED=1 and TLS_SELF_SIGNED=1"
  [ -n "${TLS_SECRET_NAME:-}" ] || fatal "TLS_SECRET_NAME is required when TLS_ENABLED=1"
  [ -n "${NAMESPACE:-}" ] || fatal "NAMESPACE is required when TLS_ENABLED=1"

  tls_tmp_dir="$(mktemp -d /tmp/otp-relay-tls.XXXXXX)"
  tls_key="$tls_tmp_dir/tls.key"
  tls_crt="$tls_tmp_dir/tls.crt"

  cleanup_tls_tmp_dir() {
    if [ -n "${tls_tmp_dir:-}" ] && [ -d "$tls_tmp_dir" ]; then
      rm -rf "$tls_tmp_dir"
    fi
  }
  trap cleanup_tls_tmp_dir RETURN

  log "creating self-signed TLS secret $TLS_SECRET_NAME for $TLS_HOST; IT Group Policy must trust/distribute this cert for users"

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$tls_key" \
    -out "$tls_crt" \
    -days 825 \
    -subj "/CN=$TLS_HOST" \
    -addext "subjectAltName=DNS:$TLS_HOST"

  k3s kubectl create secret tls "$TLS_SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --cert="$tls_crt" \
    --key="$tls_key" \
    --dry-run=client -o yaml | k3s kubectl apply -f -

  log "self-signed TLS secret $TLS_SECRET_NAME is available in namespace $NAMESPACE"
}
