#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

validate_k8s_topology_settings() {
  case "$SERVICE_TYPE" in
    ClusterIP|NodePort|LoadBalancer) ;;
    *) fatal "unsupported SERVICE_TYPE=$SERVICE_TYPE. Use ClusterIP, NodePort, or LoadBalancer." ;;
  esac

  case "$INGRESS_ENABLED" in
    0|1) ;;
    *) fatal "unsupported INGRESS_ENABLED=$INGRESS_ENABLED. Use 0 or 1." ;;
  esac

  case "$REDIS_ENABLED" in
    0|1) ;;
    *) fatal "unsupported REDIS_ENABLED=$REDIS_ENABLED. Use 0 or 1." ;;
  esac

  case "$REDIS_REQUIRED" in
    0|1) ;;
    *) fatal "unsupported REDIS_REQUIRED=$REDIS_REQUIRED. Use 0 or 1." ;;
  esac

  case "$TLS_ENABLED" in
    0|1) ;;
    *) fatal "unsupported TLS_ENABLED=$TLS_ENABLED. Use 0 or 1." ;;
  esac

  case "$TLS_SELF_SIGNED" in
    0|1) ;;
    *) fatal "unsupported TLS_SELF_SIGNED=$TLS_SELF_SIGNED. Use 0 or 1." ;;
  esac

  case "$NFS_ENABLED" in
    0|1) ;;
    *) fatal "NFS_ENABLED must be 0 or 1" ;;
  esac

  case "$REDIS_SPREAD_RECREATE_PVCS" in
    auto|0|1) ;;
    *) fatal "REDIS_SPREAD_RECREATE_PVCS must be auto, 0, or 1" ;;
  esac

  case "$DISTRIBUTE_IMAGES_TO_NODES" in
    0|1) ;;
    *) fatal "DISTRIBUTE_IMAGES_TO_NODES must be 0 or 1" ;;
  esac

  case "$IMAGE_DISTRIBUTION_PORT" in
    ''|*[!0-9]*) fatal "IMAGE_DISTRIBUTION_PORT must be numeric" ;;
  esac

  if [ "$IMAGE_DISTRIBUTION_PORT" -lt 1024 ] || [ "$IMAGE_DISTRIBUTION_PORT" -gt 65535 ]; then
    fatal "IMAGE_DISTRIBUTION_PORT must be between 1024 and 65535"
  fi

  if [ "$NFS_ENABLED" = "1" ]; then
    [ -n "$NFS_SERVER" ] || fatal "NFS_ENABLED=1 requires NFS_SERVER"
    [ -n "$NFS_PATH" ] || fatal "NFS_ENABLED=1 requires NFS_PATH"
    if [ -z "$PVC_STORAGE_CLASS" ]; then
      PVC_STORAGE_CLASS="$NFS_STORAGE_CLASS"
    fi
    if [ "$PVC_STORAGE_CLASS" != "$NFS_STORAGE_CLASS" ]; then
      fatal "NFS_ENABLED=1 requires PVC_STORAGE_CLASS=$NFS_STORAGE_CLASS or an empty PVC_STORAGE_CLASS"
    fi
  fi

  if [ "$TLS_ENABLED" = "1" ]; then
    [ "$INGRESS_ENABLED" = "1" ] || fatal "TLS_ENABLED=1 requires INGRESS_ENABLED=1"
    [ -n "$TLS_HOST" ] || fatal "TLS_ENABLED=1 requires TLS_HOST"
    [ -n "$TLS_SECRET_NAME" ] || fatal "TLS_ENABLED=1 requires TLS_SECRET_NAME"
  fi

  if [ "$SERVICE_TYPE" = "NodePort" ]; then
    case "$SERVICE_NODE_PORT" in
      ''|*[!0-9]*) fatal "SERVICE_NODE_PORT must be numeric for SERVICE_TYPE=NodePort" ;;
    esac
    if [ "$SERVICE_NODE_PORT" -lt 30000 ] || [ "$SERVICE_NODE_PORT" -gt 32767 ]; then
      fatal "SERVICE_NODE_PORT must be between 30000 and 32767"
    fi
  fi

  if [ "$SERVICE_TYPE" = "LoadBalancer" ] && [ "$INGRESS_ENABLED" = "1" ]; then
    warn "SERVICE_TYPE=LoadBalancer and INGRESS_ENABLED=1 are both enabled. Usually one exposure path is enough. Official design uses SERVICE_TYPE=ClusterIP with Ingress enabled."
  fi

  case "$REPLICA_COUNT" in
    ''|*[!0-9]*) fatal "REPLICA_COUNT must be a positive integer" ;;
  esac
  [ "$REPLICA_COUNT" -ge 1 ] || fatal "REPLICA_COUNT must be at least 1"
  if [ "$REPLICA_COUNT" -gt 1 ]; then
    warn "REPLICA_COUNT=$REPLICA_COUNT selected. Confirm OTP validation across multiple app pods before treating this as production-final."
  fi

  if { [ -n "$APP_NODE_SELECTOR_KEY" ] && [ -z "$APP_NODE_SELECTOR_VALUE" ]; } || { [ -z "$APP_NODE_SELECTOR_KEY" ] && [ -n "$APP_NODE_SELECTOR_VALUE" ]; }; then
    fatal "APP_NODE_SELECTOR_KEY and APP_NODE_SELECTOR_VALUE must be set together"
  fi
  if { [ -n "$MONITOR_NODE_SELECTOR_KEY" ] && [ -z "$MONITOR_NODE_SELECTOR_VALUE" ]; } || { [ -z "$MONITOR_NODE_SELECTOR_KEY" ] && [ -n "$MONITOR_NODE_SELECTOR_VALUE" ]; }; then
    fatal "MONITOR_NODE_SELECTOR_KEY and MONITOR_NODE_SELECTOR_VALUE must be set together"
  fi
  if { [ -n "$REDIS_NODE_SELECTOR_KEY" ] && [ -z "$REDIS_NODE_SELECTOR_VALUE" ]; } || { [ -z "$REDIS_NODE_SELECTOR_KEY" ] && [ -n "$REDIS_NODE_SELECTOR_VALUE" ]; }; then
    fatal "REDIS_NODE_SELECTOR_KEY and REDIS_NODE_SELECTOR_VALUE must be set together"
  fi
}

validate_selected_node() {
  local label_key="$1"
  local label_value="$2"
  local label_name="$3"
  [ -n "$label_key" ] || return 0
  if ! k3s kubectl get node -l "$label_key=$label_value" -o name | grep -q .; then
    fatal "$label_name node selector did not match any node: $label_key=$label_value"
  fi
}

mark_deployment_restart_required() {
  local deployment_name="$1"
  case "$deployment_name" in
    otp-relay) RESTART_APP_REQUIRED=1 ;;
    otp-monitor) RESTART_MONITOR_REQUIRED=1 ;;
    *) fatal "unknown deployment restart request: $deployment_name" ;;
  esac
}

rollout_restart_deployment_if_exists() {
  local deployment_name="$1"

  if ! k3s kubectl get deployment "$deployment_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "deployment/$deployment_name does not exist yet; skipping rollout restart"
    return 0
  fi

  for attempt in 1 2 3; do
    if k3s kubectl rollout restart "deployment/$deployment_name" -n "$NAMESPACE"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      warn "rollout restart for deployment/$deployment_name was rejected or raced; retrying"
      sleep 2
    fi
  done

  fatal "failed to trigger rollout restart for deployment/$deployment_name"
}

perform_pending_rollout_restarts() {
  if [ "$RESTART_APP_REQUIRED" = "1" ]; then
    log "restarting app deployment"
    rollout_restart_deployment_if_exists otp-relay
    log "waiting for app rollout"
    k3s kubectl rollout status deployment/otp-relay -n "$NAMESPACE" --timeout=240s
    RESTART_APP_REQUIRED=0
  fi

  if [ "$RESTART_MONITOR_REQUIRED" = "1" ]; then
    log "restarting monitor deployment"
    rollout_restart_deployment_if_exists otp-monitor
    log "waiting for monitor rollout"
    k3s kubectl rollout status deployment/otp-monitor -n "$NAMESPACE" --timeout=180s
    RESTART_MONITOR_REQUIRED=0
  fi
}

resolve_portal_url_from_service() {
  PORTAL_URL_CONFIG_REFRESHED=0

  [ "$SERVICE_TYPE" = "LoadBalancer" ] || return 0

  if [ "$PORTAL_URL_EXPLICIT" = "1" ]; then
    log "PORTAL_URL was explicitly provided; leaving it as $PORTAL_URL"
    return 0
  fi

  if [ -n "$LOADBALANCER_IP" ]; then
    ASSIGNED_LOADBALANCER_ADDRESS="$LOADBALANCER_IP"
    PORTAL_URL="http://$LOADBALANCER_IP"
    SERVER_IP="$LOADBALANCER_IP"
    log "using requested LoadBalancer IP for PORTAL_URL: $PORTAL_URL"
    apply_runtime_configmap
    PORTAL_URL_CONFIG_REFRESHED=1
    return 0
  fi

  log "waiting for LoadBalancer address assignment for service otp-relay"
  for i in $(seq 1 60); do
    local assigned_address
    assigned_address="$({
      k3s kubectl get svc otp-relay \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    })"
    assigned_address="$(printf '%s' "$assigned_address" | xargs)"

    if [ -z "$assigned_address" ]; then
      assigned_address="$({
        k3s kubectl get svc otp-relay \
          -n "$NAMESPACE" \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
      })"
      assigned_address="$(printf '%s' "$assigned_address" | xargs)"
    fi

    if [ -n "$assigned_address" ]; then
      ASSIGNED_LOADBALANCER_ADDRESS="$assigned_address"
      PORTAL_URL="http://$assigned_address"
      SERVER_IP="$assigned_address"
      log "using assigned LoadBalancer address for PORTAL_URL: $PORTAL_URL"
      apply_runtime_configmap
      PORTAL_URL_CONFIG_REFRESHED=1
      return 0
    fi

    sleep 2
  done

  warn "LoadBalancer address was not assigned within timeout; keeping PORTAL_URL=$PORTAL_URL"
}

