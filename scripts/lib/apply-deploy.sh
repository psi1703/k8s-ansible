#!/usr/bin/env bash
# Kubernetes secret creation, image build/import, manifest apply, and rollout restarts.

apply_secret_if_required() {
  if requires_manifests_apply; then
    log "creating/updating Kubernetes secret $NAMESPACE/otp-relay-secrets"
    k3s kubectl create secret generic otp-relay-secrets \
      --namespace "$NAMESPACE" \
      --from-literal=SMS_SECRET_TOKEN="$SMS_SECRET_TOKEN" \
      --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
      --from-literal=TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
      --dry-run=client -o yaml | k3s kubectl apply -f -
    log "Kubernetes secret $NAMESPACE/otp-relay-secrets applied"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require secret apply; skipping Kubernetes secret"
  fi
}

verify_app_image_contents() {
  if ! requires_app_image; then
    return 0
  fi

  log "verifying built app image contains generated frontend bundle"

  tmp_container="$("$DOCKER_BIN" create "$APP_IMAGE")"
  cleanup_tmp_container() {
    "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
  }
  trap cleanup_tmp_container RETURN

  "$DOCKER_BIN" cp "$tmp_container:/app/frontend/app.js" "$GENERATED_DIR/app-image-frontend-app.js" >/dev/null

  [ -s "$GENERATED_DIR/app-image-frontend-app.js" ] || \
    fatal "app image contains /app/frontend/app.js, but it is empty"

  if "$DOCKER_BIN" cp "$tmp_container:/app/app.js" "$GENERATED_DIR/app-image-root-app.js" >/dev/null 2>&1; then
    fatal "app image contains forbidden root-level /app/app.js"
  fi

  if "$DOCKER_BIN" cp "$tmp_container:/app/frontend/app.jsx" "$GENERATED_DIR/app-image-frontend-app.jsx" >/dev/null 2>&1; then
    fatal "app image contains frontend source /app/frontend/app.jsx; runtime image should contain generated app.js only"
  fi

  log "app image frontend bundle validation passed"
}

build_and_import_images_if_required() {
  if requires_app_image; then
    log "building app image with Docker: $APP_IMAGE"
    log "Docker build can take several minutes on a fresh host"
    "$DOCKER_BIN" build -t "$APP_IMAGE" -f "$APP_DOCKERFILE" .
    log "app image build completed: $APP_IMAGE"

    verify_app_image_contents

    log "saving app image for K3s import/distribution"
    tmp_app_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-app-image.XXXXXX.tar)"
    "$DOCKER_BIN" save "$APP_IMAGE" -o "$tmp_app_tar"
    log "app image saved to $tmp_app_tar"

    log "importing app image into local K3s containerd"
    k3s ctr images import "$tmp_app_tar"
    log "app image imported into local K3s containerd"

    log "distributing app image to worker nodes if enabled"
    distribute_image_tar_to_all_nodes "$APP_IMAGE" "$tmp_app_tar" "app"
    log "app image distribution step completed"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE skips app image build/import"
  fi

  if requires_monitor_image; then
    log "building monitor image with Docker: $MONITOR_IMAGE"
    log "Docker build can take several minutes on a fresh host"
    "$DOCKER_BIN" build -t "$MONITOR_IMAGE" -f "$MONITOR_DOCKERFILE" .
    log "monitor image build completed: $MONITOR_IMAGE"

    log "saving monitor image for K3s import/distribution"
    tmp_monitor_tar="$(mktemp -p "$GENERATED_DIR" otp-relay-monitor-image.XXXXXX.tar)"
    "$DOCKER_BIN" save "$MONITOR_IMAGE" -o "$tmp_monitor_tar"
    log "monitor image saved to $tmp_monitor_tar"

    log "importing monitor image into local K3s containerd"
    k3s ctr images import "$tmp_monitor_tar"
    log "monitor image imported into local K3s containerd"

    log "distributing monitor image to worker nodes if enabled"
    distribute_image_tar_to_all_nodes "$MONITOR_IMAGE" "$tmp_monitor_tar" "monitor"
    log "monitor image distribution step completed"
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

  log "checking app storage resources"

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    log "NFS app storage is enabled; validating PersistentVolume $pv_name"

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
      log "creating static NFS PersistentVolume for app data: $pv_name"
      k3s kubectl apply -f "$MANIFEST_DIR/pv-nfs.yaml"
      log "static NFS PersistentVolume apply completed: $pv_name"
    fi
  else
    log "NFS app storage is disabled; skipping static NFS PV apply"
  fi

  log "checking app data PersistentVolumeClaim $NAMESPACE/$pvc_name"

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
    log "creating app data PersistentVolumeClaim: $NAMESPACE/$pvc_name"
    k3s kubectl apply -f "$MANIFEST_DIR/pvc.yaml"
    log "app data PersistentVolumeClaim apply completed: $NAMESPACE/$pvc_name"
  fi

  log "app storage resource check completed"
}

validate_running_app_frontend() {
  if ! requires_app_image; then
    return 0
  fi

  log "validating generated frontend bundle inside running OTP Relay pod"

  k3s kubectl rollout status deployment/otp-relay -n "$NAMESPACE" --timeout=240s

  app_pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$app_pod" ] || fatal "could not find running otp-relay pod for frontend validation"

  log "validating frontend files in pod $NAMESPACE/$app_pod"

  k3s kubectl exec -n "$NAMESPACE" "$app_pod" -- test -s /app/frontend/app.js || \
    fatal "running app pod does not contain generated /app/frontend/app.js"

  if k3s kubectl exec -n "$NAMESPACE" "$app_pod" -- test -e /app/app.js; then
    fatal "running app pod contains forbidden root-level /app/app.js"
  fi

  if k3s kubectl exec -n "$NAMESPACE" "$app_pod" -- test -e /app/frontend/app.jsx; then
    fatal "running app pod contains /app/frontend/app.jsx; runtime should serve generated app.js only"
  fi

  k3s kubectl exec -n "$NAMESPACE" "$app_pod" -- sh -c 'grep -q "script src=\"app.js\"" /app/frontend/index.html' || \
    fatal "running app pod index.html does not reference app.js"

  log "running OTP Relay pod frontend validation passed"
}

apply_kubernetes_resources_if_required() {
  if requires_manifests_apply; then
    log "applying Kubernetes resources for DEPLOY_MODE=$DEPLOY_MODE"

    log "applying runtime ConfigMap"
    apply_runtime_configmap
    log "runtime ConfigMap apply completed"

    apply_app_storage_resources

    if [ "$REDIS_ENABLED" = "1" ]; then
      log "applying Redis HA shared-state resources"
      apply_if_exists "$MANIFEST_DIR/redis-nfs-pv.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-configmap.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-service.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-statefulset.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-sentinel-configmap.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-sentinel-service.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-sentinel-deployment.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-haproxy-configmap.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-haproxy-deployment.yaml"
      apply_if_exists "$MANIFEST_DIR/otp-relay-pdb.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-pdb.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-sentinel-pdb.yaml"
      apply_if_exists "$MANIFEST_DIR/redis-haproxy-pdb.yaml"

      log "waiting for Redis StatefulSet rollout; this may take a few minutes"
      k3s kubectl rollout status statefulset/otp-redis -n "$NAMESPACE" --timeout=300s
      log "Redis StatefulSet rollout completed"

      log "waiting for Redis Sentinel rollout; this may take a few minutes"
      k3s kubectl rollout status deployment/otp-redis-sentinel -n "$NAMESPACE" --timeout=240s
      log "Redis Sentinel rollout completed"

      log "waiting for Redis HAProxy rollout; this may take a few minutes"
      k3s kubectl rollout status deployment/otp-redis-haproxy -n "$NAMESPACE" --timeout=240s
      log "Redis HAProxy rollout completed"
    else
      log "REDIS_ENABLED=0; skipping Redis resources"
    fi

    if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
      log "applying OTP Relay app deployment manifest"
      k3s kubectl apply -f "$MANIFEST_DIR/deployment.yaml"

      log "applying OTP Relay service manifest"
      k3s kubectl apply -f "$MANIFEST_DIR/service.yaml"

      resolve_portal_url_from_service

      if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
        log "applying OTP Relay ingress manifest"
        k3s kubectl apply -f "$MANIFEST_DIR/ingress.yaml"
      else
        log "Ingress disabled or manifest missing; deleting existing otp-relay ingress if present"
        k3s kubectl delete ingress otp-relay -n "$NAMESPACE" --ignore-not-found=true
      fi
    else
      log "DEPLOY_MODE=$DEPLOY_MODE skips app deployment/service/ingress apply"
    fi

    if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "monitor" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
      log "applying OTP monitor deployment manifest"
      k3s kubectl apply -f "$MANIFEST_DIR/deployment-monitor.yaml"

      log "applying OTP monitor service manifest"
      k3s kubectl apply -f "$MANIFEST_DIR/monitor-service.yaml"
    else
      log "DEPLOY_MODE=$DEPLOY_MODE skips monitor deployment/service apply"
    fi

    log "applying observability manifests if present"
    apply_observability_manifests
    log "observability manifest apply completed"

    if [ "$PORTAL_URL_CONFIG_REFRESHED" = "1" ]; then
      log "marking deployments for restart to pick up refreshed PORTAL_URL ConfigMap"
      mark_deployment_restart_required otp-relay
      mark_deployment_restart_required otp-monitor
    fi
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require manifest apply; skipping Kubernetes resources"
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

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    validate_running_app_frontend
  fi

  if [ "$DEPLOY_MODE" = "manifests" ]; then
    log "manifest-only apply complete; checking rollout status for existing deployments"

    log "checking existing app deployment rollout status"
    k3s kubectl rollout status deployment/otp-relay -n "$NAMESPACE" --timeout=240s || true

    log "checking existing monitor deployment rollout status"
    k3s kubectl rollout status deployment/otp-monitor -n "$NAMESPACE" --timeout=180s || true
  fi

  log "Kubernetes resource apply phase completed"
}

copy_runtime_data_if_requested() {
  if [ -n "$RUNTIME_DATA_DIR" ] && { [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ]; }; then
    [ -d "$RUNTIME_DATA_DIR" ] || fatal "RUNTIME_DATA_DIR does not exist: $RUNTIME_DATA_DIR"

    log "runtime data copy requested from $RUNTIME_DATA_DIR"
    log "finding current otp-relay app pod"
    pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay -o jsonpath='{.items[0].metadata.name}')"
    [ -n "$pod" ] || fatal "could not find otp-relay pod for runtime data copy"

    log "copying runtime data into pod $NAMESPACE/$pod"
    for f in users.xlsx admin_auth.json admin_config.json wizard_progress.json audit.log; do
      if [ -f "$RUNTIME_DATA_DIR/$f" ]; then
        log "copying $f into PVC"
        k3s kubectl cp "$RUNTIME_DATA_DIR/$f" "$NAMESPACE/$pod:/app/data/$f" -n "$NAMESPACE"
        log "copied $f"
      else
        log "runtime data file not present, skipping: $RUNTIME_DATA_DIR/$f"
      fi
    done

    mark_deployment_restart_required otp-relay
    mark_deployment_restart_required otp-monitor
    perform_pending_rollout_restarts
    log "runtime data copy completed"
  else
    log "no runtime data copy requested for DEPLOY_MODE=$DEPLOY_MODE"
  fi
}
