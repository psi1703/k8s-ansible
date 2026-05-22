#!/usr/bin/env bash
# Kubernetes secret creation, image build/import, manifest apply, and rollout restarts.

apply_secret_if_required() {
if requires_manifests_apply; then
  log "creating/updating Kubernetes secret"
  k3s kubectl create secret generic otp-relay-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=SMS_SECRET_TOKEN="$SMS_SECRET_TOKEN" \
    --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
    --from-literal=TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
fi

}

build_and_import_images_if_required() {
if requires_app_image; then
  log "building app image with Docker"
  "$DOCKER_BIN" build -t "$APP_IMAGE" -f "$APP_DOCKERFILE" .
  log "saving app image for K3s import/distribution"
  tmp_app_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-app-image.XXXXXX.tar)"
  "$DOCKER_BIN" save "$APP_IMAGE" -o "$tmp_app_tar"
  log "importing app image into local K3s containerd"
  k3s ctr images import "$tmp_app_tar"
  distribute_image_tar_to_all_nodes "$APP_IMAGE" "$tmp_app_tar" "app"
else
  log "DEPLOY_MODE=$DEPLOY_MODE skips app image build/import"
fi

if requires_monitor_image; then
  log "building required monitor image with Docker"
  "$DOCKER_BIN" build -t "$MONITOR_IMAGE" -f "$MONITOR_DOCKERFILE" .
  log "saving monitor image for K3s import/distribution"
  tmp_monitor_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-monitor-image.XXXXXX.tar)"
  "$DOCKER_BIN" save "$MONITOR_IMAGE" -o "$tmp_monitor_tar"
  log "importing required monitor image into local K3s containerd"
  k3s ctr images import "$tmp_monitor_tar"
  distribute_image_tar_to_all_nodes "$MONITOR_IMAGE" "$tmp_monitor_tar" "monitor"
else
  log "DEPLOY_MODE=$DEPLOY_MODE skips monitor image build/import"
fi

}


_storage_jsonpath() {
  local kind="$1"
  local name="$2"
  local jsonpath="$3"
  if [ "$kind" = "pv" ]; then
    k3s kubectl get pv "$name" -o "jsonpath=${jsonpath}" 2>/dev/null || true
  else
    k3s kubectl get "$kind" "$name" -n "$NAMESPACE" -o "jsonpath=${jsonpath}" 2>/dev/null || true
  fi
}

apply_app_storage_resources() {
  local pvc_name="otp-relay-data"
  local pv_name="${NFS_PV_NAME:-otp-relay-data-nfs-pv}"
  local existing_server=""
  local existing_path=""
  local existing_sc=""
  local existing_pvc_sc=""
  local existing_pvc_volume=""

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    if k3s kubectl get pv "$pv_name" >/dev/null 2>&1; then
      existing_server="$(_storage_jsonpath pv "$pv_name" '{.spec.nfs.server}')"
      existing_path="$(_storage_jsonpath pv "$pv_name" '{.spec.nfs.path}')"
      existing_sc="$(_storage_jsonpath pv "$pv_name" '{.spec.storageClassName}')"

      log "existing app data NFS PersistentVolume found: $pv_name"
      log "using existing PV source: ${existing_server:-unknown}:${existing_path:-unknown}"

      if [ "${existing_server:-}" != "${NFS_SERVER:-}" ] || [ "${existing_path:-}" != "${NFS_PATH:-}" ]; then
        warn "existing PV source differs from .env; keeping existing PV because Kubernetes PV source is immutable"
        warn "existing PV: ${existing_server:-unknown}:${existing_path:-unknown}"
        warn ".env value:  ${NFS_SERVER:-unset}:${NFS_PATH:-unset}"
        warn "to intentionally move storage, scale workloads down, delete the PVC/PV manually, then rerun the installer"
      fi

      if [ -n "${NFS_STORAGE_CLASS:-}" ] && [ -n "${existing_sc:-}" ] && [ "$existing_sc" != "$NFS_STORAGE_CLASS" ]; then
        warn "existing PV storageClassName differs from .env; keeping existing value: $existing_sc"
      fi
    else
      [ -f "$MANIFEST_DIR/pv-nfs.yaml" ] || fatal "NFS_ENABLED=1 but rendered NFS PV manifest is missing: $MANIFEST_DIR/pv-nfs.yaml"
      log "creating static NFS PersistentVolume for app data"
      k3s kubectl apply -f "$MANIFEST_DIR/pv-nfs.yaml"
    fi
  fi

  if k3s kubectl get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    existing_pvc_sc="$(_storage_jsonpath pvc "$pvc_name" '{.spec.storageClassName}')"
    existing_pvc_volume="$(_storage_jsonpath pvc "$pvc_name" '{.spec.volumeName}')"

    log "existing app data PersistentVolumeClaim found: $NAMESPACE/$pvc_name"
    log "using existing PVC volume: ${existing_pvc_volume:-dynamic-or-pending}"

    if [ "${NFS_ENABLED:-0}" = "1" ] && [ -n "${existing_pvc_volume:-}" ] && [ "$existing_pvc_volume" != "$pv_name" ]; then
      warn "existing PVC is bound to a different PV; keeping existing binding because PVC volume binding is immutable"
      warn "existing PVC volume: $existing_pvc_volume"
      warn ".env PV name:       $pv_name"
    fi

    if [ -n "${PVC_STORAGE_CLASS:-}" ] && [ -n "${existing_pvc_sc:-}" ] && [ "$existing_pvc_sc" != "$PVC_STORAGE_CLASS" ]; then
      warn "existing PVC storageClassName differs from .env; keeping existing value: $existing_pvc_sc"
    fi
  else
    [ -f "$MANIFEST_DIR/pvc.yaml" ] || fatal "rendered PVC manifest is missing: $MANIFEST_DIR/pvc.yaml"
    log "creating app data PersistentVolumeClaim"
    k3s kubectl apply -f "$MANIFEST_DIR/pvc.yaml"
  fi
}


apply_kubernetes_resources_if_required() {
if requires_manifests_apply; then
  log "applying Kubernetes resources"
  apply_runtime_configmap
  apply_app_storage_resources

  if [ "$REDIS_ENABLED" = "1" ]; then
    log "applying Redis HA shared-state resources"
    apply_if_exists "$MANIFEST_DIR/redis-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-service.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-statefulset.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-service.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-deployment.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-configmap.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-deployment.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-pdb.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-sentinel-pdb.yaml"
    apply_if_exists "$MANIFEST_DIR/redis-haproxy-pdb.yaml"

    log "waiting for Redis StatefulSet rollout"
    k3s kubectl rollout status statefulset/otp-redis -n "$NAMESPACE" --timeout=300s
    log "waiting for Redis Sentinel rollout"
    k3s kubectl rollout status deployment/otp-redis-sentinel -n "$NAMESPACE" --timeout=240s
    log "waiting for Redis HAProxy rollout"
    k3s kubectl rollout status deployment/otp-redis-haproxy -n "$NAMESPACE" --timeout=240s
  fi

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    k3s kubectl apply -f "$MANIFEST_DIR/deployment.yaml"
    k3s kubectl apply -f "$MANIFEST_DIR/service.yaml"
    resolve_portal_url_from_service
    if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
      k3s kubectl apply -f "$MANIFEST_DIR/ingress.yaml"
    else
      k3s kubectl delete ingress otp-relay -n "$NAMESPACE" --ignore-not-found=true
    fi
  fi

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "monitor" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    k3s kubectl apply -f "$MANIFEST_DIR/deployment-monitor.yaml"
    k3s kubectl apply -f "$MANIFEST_DIR/monitor-service.yaml"
  fi

  apply_observability_manifests

  if [ "$PORTAL_URL_CONFIG_REFRESHED" = "1" ]; then
    log "marking deployments for restart to pick up refreshed PORTAL_URL ConfigMap"
    mark_deployment_restart_required otp-relay
    mark_deployment_restart_required otp-monitor
  fi
fi

if requires_app_image; then
  log "marking app deployment for restart to pick up freshly imported local app image"
  mark_deployment_restart_required otp-relay
fi
if requires_monitor_image; then
  log "marking monitor deployment for restart to pick up freshly imported local monitor image"
  mark_deployment_restart_required otp-monitor
fi
perform_pending_rollout_restarts

if [ "$DEPLOY_MODE" = "manifests" ]; then
  log "manifest-only apply complete; checking rollout status for existing deployments"
  k3s kubectl rollout status deployment/otp-relay -n "$NAMESPACE" --timeout=240s || true
  k3s kubectl rollout status deployment/otp-monitor -n "$NAMESPACE" --timeout=180s || true
fi

}

copy_runtime_data_if_requested() {
if [ -n "$RUNTIME_DATA_DIR" ] && { [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ]; }; then
  [ -d "$RUNTIME_DATA_DIR" ] || fatal "RUNTIME_DATA_DIR does not exist: $RUNTIME_DATA_DIR"
  pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay -o jsonpath='{.items[0].metadata.name}')"
  for f in users.xlsx admin_auth.json admin_config.json wizard_progress.json audit.log; do
    if [ -f "$RUNTIME_DATA_DIR/$f" ]; then
      log "copying $f into PVC"
      k3s kubectl cp "$RUNTIME_DATA_DIR/$f" "$NAMESPACE/$pod:/app/data/$f" -n "$NAMESPACE"
    fi
  done
  mark_deployment_restart_required otp-relay
  mark_deployment_restart_required otp-monitor
  perform_pending_rollout_restarts
fi

}
