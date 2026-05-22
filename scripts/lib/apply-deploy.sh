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

apply_kubernetes_resources_if_required() {
if requires_manifests_apply; then
  log "applying Kubernetes resources"
  apply_runtime_configmap
  if [ "$NFS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
    log "applying static NFS PersistentVolume for app data"
    k3s kubectl apply -f "$MANIFEST_DIR/pv-nfs.yaml"
  fi
  k3s kubectl apply -f "$MANIFEST_DIR/pvc.yaml"

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
