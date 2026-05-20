#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

ensure_tls_secret_available_if_required() {
  [ "$TLS_ENABLED" = "1" ] || return 0
  [ "$TLS_SELF_SIGNED" = "0" ] || return 0

  if k3s kubectl get secret "$TLS_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "TLS secret $TLS_SECRET_NAME already exists in namespace $NAMESPACE"
    return 0
  fi

  fatal "TLS_ENABLED=1 with TLS_SELF_SIGNED=0 requires an existing Kubernetes TLS secret named $TLS_SECRET_NAME in namespace $NAMESPACE. Create the TLS secret first, or use TLS_SELF_SIGNED=1 so the installer creates/updates the self-signed secret for IT Group Policy distribution."
}

ensure_tls_secret_if_requested() {
  [ "$TLS_ENABLED" = "1" ] || return 0
  [ "$TLS_SELF_SIGNED" = "1" ] || return 0

  log "creating/updating self-signed TLS secret $TLS_SECRET_NAME for $TLS_HOST; IT Group Policy must trust/distribute this cert for users"
  local tls_tmp_dir
  tls_tmp_dir="$(mktemp -d /tmp/otp-relay-tls.XXXXXX)"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$tls_tmp_dir/tls.key" \
    -out "$tls_tmp_dir/tls.crt" \
    -days 825 \
    -subj "/CN=$TLS_HOST" \
    -addext "subjectAltName=DNS:$TLS_HOST"

  k3s kubectl create secret tls "$TLS_SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --cert="$tls_tmp_dir/tls.crt" \
    --key="$tls_tmp_dir/tls.key" \
    --dry-run=client -o yaml | k3s kubectl apply -f -

  rm -rf "$tls_tmp_dir"
}

