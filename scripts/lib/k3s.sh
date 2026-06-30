#!/usr/bin/env bash
# Shared Kubernetes runtime-setting validators for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Validate values that will be rendered into manifests.
#   - Do not query Kubernetes nodes.
#   - Do not restart deployments.
#   - Do not wait for LoadBalancer assignment.
#   - Do not update live ConfigMaps.
#
# The production server receives only the finished bundle.

validate_k8s_topology_settings() {
  log "validating Kubernetes runtime settings for bundle rendering"

  case "${SERVICE_TYPE:-}" in
    ClusterIP|NodePort|LoadBalancer) ;;
    *) fatal "unsupported SERVICE_TYPE=${SERVICE_TYPE:-}. Use ClusterIP, NodePort, or LoadBalancer." ;;
  esac

  case "${INGRESS_ENABLED:-}" in
    0|1) ;;
    *) fatal "unsupported INGRESS_ENABLED=${INGRESS_ENABLED:-}. Use 0 or 1." ;;
  esac

  case "${TLS_ENABLED:-}" in
    0|1) ;;
    *) fatal "unsupported TLS_ENABLED=${TLS_ENABLED:-}. Use 0 or 1." ;;
  esac

  case "${TLS_SELF_SIGNED:-}" in
    0|1) ;;
    *) fatal "unsupported TLS_SELF_SIGNED=${TLS_SELF_SIGNED:-}. Use 0 or 1." ;;
  esac

  case "${NFS_ENABLED:-}" in
    0|1) ;;
    *) fatal "NFS_ENABLED must be 0 or 1" ;;
  esac

  case "${REDIS_ENABLED:-}" in
    0|1) ;;
    *) fatal "unsupported REDIS_ENABLED=${REDIS_ENABLED:-}. Use 0 or 1." ;;
  esac

  case "${REDIS_REQUIRED:-}" in
    0|1) ;;
    *) fatal "unsupported REDIS_REQUIRED=${REDIS_REQUIRED:-}. Use 0 or 1." ;;
  esac

  case "${REDIS_SPREAD_RECREATE_PVCS:-auto}" in
    auto|0|1) ;;
    *) fatal "REDIS_SPREAD_RECREATE_PVCS must be auto, 0, or 1" ;;
  esac

  case "${DISTRIBUTE_IMAGES_TO_NODES:-0}" in
    0) ;;
    1) fatal "DISTRIBUTE_IMAGES_TO_NODES must be 0 in bundle-only mode" ;;
    *) fatal "DISTRIBUTE_IMAGES_TO_NODES must be 0 in bundle-only mode" ;;
  esac

  case "${IMAGE_DISTRIBUTION_PORT:-18080}" in
    ''|*[!0-9]*) fatal "IMAGE_DISTRIBUTION_PORT must be numeric" ;;
  esac

  if [ "${IMAGE_DISTRIBUTION_PORT:-18080}" -lt 1024 ] || [ "${IMAGE_DISTRIBUTION_PORT:-18080}" -gt 65535 ]; then
    fatal "IMAGE_DISTRIBUTION_PORT must be between 1024 and 65535"
  fi

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    log "validating external NFS storage values for rendered manifests"
    [ -n "${NFS_SERVER:-}" ] || fatal "NFS_ENABLED=1 requires NFS_SERVER"
    [ -n "${NFS_PATH:-}" ] || fatal "NFS_ENABLED=1 requires NFS_PATH"

    if [ -z "${PVC_STORAGE_CLASS:-}" ]; then
      PVC_STORAGE_CLASS="${NFS_STORAGE_CLASS:-}"
      export PVC_STORAGE_CLASS
    fi

    if [ -n "${NFS_STORAGE_CLASS:-}" ] && [ "${PVC_STORAGE_CLASS:-}" != "${NFS_STORAGE_CLASS:-}" ]; then
      fatal "NFS_ENABLED=1 requires PVC_STORAGE_CLASS=$NFS_STORAGE_CLASS or an empty PVC_STORAGE_CLASS"
    fi
  fi

  if [ "${TLS_ENABLED:-0}" = "1" ]; then
    log "validating TLS values for rendered manifests"
    [ "${INGRESS_ENABLED:-0}" = "1" ] || fatal "TLS_ENABLED=1 requires INGRESS_ENABLED=1"
    [ -n "${TLS_HOST:-}" ] || fatal "TLS_ENABLED=1 requires TLS_HOST"
    [ -n "${TLS_SECRET_NAME:-}" ] || fatal "TLS_ENABLED=1 requires TLS_SECRET_NAME"
  fi

  if [ "${SERVICE_TYPE:-}" = "NodePort" ]; then
    log "validating NodePort service value for rendered manifest"

    case "${SERVICE_NODE_PORT:-}" in
      ''|*[!0-9]*) fatal "SERVICE_NODE_PORT must be numeric for SERVICE_TYPE=NodePort" ;;
    esac

    if [ "${SERVICE_NODE_PORT:-0}" -lt 30000 ] || [ "${SERVICE_NODE_PORT:-0}" -gt 32767 ]; then
      fatal "SERVICE_NODE_PORT must be between 30000 and 32767"
    fi
  fi

  if [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] && [ "${INGRESS_ENABLED:-0}" = "1" ]; then
    warn "SERVICE_TYPE=LoadBalancer and INGRESS_ENABLED=1 are both enabled. Usually one exposure path is enough."
  fi

  if [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] && [ "${REQUIRE_METALLB:-0}" = "1" ] && [ "${INSTALL_METALLB:-0}" != "1" ] && [ -z "${LOADBALANCER_IP:-}" ]; then
    warn "LoadBalancer service requested without INSTALL_METALLB=1 or LOADBALANCER_IP. Bundle will render this intent only."
  fi

  case "${REPLICA_COUNT:-}" in
    ''|*[!0-9]*) fatal "REPLICA_COUNT must be a positive integer" ;;
  esac

  [ "${REPLICA_COUNT:-0}" -ge 1 ] || fatal "REPLICA_COUNT must be at least 1"

  if [ "${REPLICA_COUNT:-1}" -gt 1 ]; then
    warn "REPLICA_COUNT=$REPLICA_COUNT selected. Confirm OTP validation across multiple app pods during production-side validation."
  fi

  if { [ -n "${APP_NODE_SELECTOR_KEY:-}" ] && [ -z "${APP_NODE_SELECTOR_VALUE:-}" ]; } || { [ -z "${APP_NODE_SELECTOR_KEY:-}" ] && [ -n "${APP_NODE_SELECTOR_VALUE:-}" ]; }; then
    fatal "APP_NODE_SELECTOR_KEY and APP_NODE_SELECTOR_VALUE must be set together"
  fi

  if { [ -n "${MONITOR_NODE_SELECTOR_KEY:-}" ] && [ -z "${MONITOR_NODE_SELECTOR_VALUE:-}" ]; } || { [ -z "${MONITOR_NODE_SELECTOR_KEY:-}" ] && [ -n "${MONITOR_NODE_SELECTOR_VALUE:-}" ]; }; then
    fatal "MONITOR_NODE_SELECTOR_KEY and MONITOR_NODE_SELECTOR_VALUE must be set together"
  fi

  if { [ -n "${REDIS_NODE_SELECTOR_KEY:-}" ] && [ -z "${REDIS_NODE_SELECTOR_VALUE:-}" ]; } || { [ -z "${REDIS_NODE_SELECTOR_KEY:-}" ] && [ -n "${REDIS_NODE_SELECTOR_VALUE:-}" ]; }; then
    fatal "REDIS_NODE_SELECTOR_KEY and REDIS_NODE_SELECTOR_VALUE must be set together"
  fi

  log "Kubernetes runtime settings for bundle rendering validated"
}

validate_selected_node() {
  local label_key="${1:-}"
  local label_value="${2:-}"
  local label_name="${3:-node selector}"

  if [ -z "$label_key" ] && [ -z "$label_value" ]; then
    log "no $label_name node selector configured"
    return 0
  fi

  [ -n "$label_key" ] || fatal "$label_name node selector value is set but key is empty"
  [ -n "$label_value" ] || fatal "$label_name node selector key is set but value is empty"

  log "validated $label_name node selector syntax for rendered manifest: $label_key=$label_value"
}

mark_deployment_restart_required() {
  fatal "mark_deployment_restart_required is forbidden in bundle-only mode"
}

rollout_restart_deployment_if_exists() {
  fatal "rollout_restart_deployment_if_exists is forbidden in bundle-only mode"
}

perform_pending_rollout_restarts() {
  log "skipping rollout restarts in bundle-only mode"
}

resolve_portal_url_from_service() {
  log "skipping live LoadBalancer service lookup in bundle-only mode"

  PORTAL_URL_CONFIG_REFRESHED=0
  ASSIGNED_LOADBALANCER_ADDRESS="${LOADBALANCER_IP:-}"

  if [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] && [ "${PORTAL_URL_EXPLICIT:-0}" != "1" ] && [ -n "${LOADBALANCER_IP:-}" ]; then
    PORTAL_URL="http://${LOADBALANCER_IP}"
    SERVER_IP="$LOADBALANCER_IP"
    export PORTAL_URL SERVER_IP
    log "using configured LOADBALANCER_IP for rendered PORTAL_URL: $PORTAL_URL"
  fi

  export PORTAL_URL_CONFIG_REFRESHED ASSIGNED_LOADBALANCER_ADDRESS
}
