#!/usr/bin/env bash
# Kubernetes secret creation, image build/import, manifest apply, and rollout restarts.

kubectl_resource_exists() {
  local kind="$1"
  local name="$2"

  k3s kubectl get "$kind" "$name" -n "$NAMESPACE" >/dev/null 2>&1
}

print_namespace_diagnostics() {
  local title="${1:-Kubernetes diagnostics}"

  warn "$title"

  log "diagnostic: nodes"
  k3s kubectl get nodes -o wide 2>/dev/null || true

  log "diagnostic: namespace $NAMESPACE resources"
  k3s kubectl get pods,svc,ingress,pvc -n "$NAMESPACE" -o wide 2>/dev/null || true

  log "diagnostic: persistent volumes"
  k3s kubectl get pv -o wide 2>/dev/null || true

  log "diagnostic: recent namespace events"
  k3s kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -n 80 || true

  if kubectl_resource_exists deployment otp-relay; then
    log "diagnostic: describe deployment/otp-relay"
    k3s kubectl describe deployment otp-relay -n "$NAMESPACE" 2>/dev/null || true
  fi

  if kubectl_resource_exists deployment otp-monitor; then
    log "diagnostic: describe deployment/otp-monitor"
    k3s kubectl describe deployment otp-monitor -n "$NAMESPACE" 2>/dev/null || true
  fi

  if kubectl_resource_exists statefulset otp-redis; then
    log "diagnostic: describe statefulset/otp-redis"
    k3s kubectl describe statefulset otp-redis -n "$NAMESPACE" 2>/dev/null || true
  fi

  if kubectl_resource_exists deployment otp-redis-sentinel; then
    log "diagnostic: describe deployment/otp-redis-sentinel"
    k3s kubectl describe deployment otp-redis-sentinel -n "$NAMESPACE" 2>/dev/null || true
  fi

  if kubectl_resource_exists deployment otp-redis-haproxy; then
    log "diagnostic: describe deployment/otp-redis-haproxy"
    k3s kubectl describe deployment otp-redis-haproxy -n "$NAMESPACE" 2>/dev/null || true
  fi
}

print_logs_for_selector() {
  local selector="$1"
  local label="$2"

  log "diagnostic: recent logs for $label ($selector)"
  k3s kubectl logs -n "$NAMESPACE" -l "$selector" --all-containers --tail=160 2>/dev/null || true
}

apply_manifest_or_diagnose() {
  local file="$1"
  local label="${2:-$1}"

  [ -f "$file" ] || fatal "required manifest is missing for $label: $file"

  log "applying manifest: $label ($file)"
  if k3s kubectl apply -f "$file"; then
    log "manifest applied: $label"
    return 0
  fi

  warn "failed to apply manifest: $label ($file)"
  warn "first 160 lines of failed manifest follow"
  sed -n '1,160p' "$file" >&2 || true
  print_namespace_diagnostics "diagnostics after manifest apply failure: $label"
  fatal "failed to apply manifest: $label ($file)"
}

apply_manifest_if_exists() {
  local file="$1"
  local label="${2:-$1}"

  if [ -f "$file" ]; then
    apply_manifest_or_diagnose "$file" "$label"
  else
    log "manifest not present, skipping: $label ($file)"
  fi
}

rollout_status_or_diagnose() {
  local resource="$1"
  local timeout="$2"
  local label="$3"
  local selector="${4:-}"

  log "waiting for rollout: $resource ($label); timeout=$timeout"
  if k3s kubectl rollout status "$resource" -n "$NAMESPACE" --timeout="$timeout"; then
    log "rollout completed: $resource ($label)"
    return 0
  fi

  warn "rollout failed or timed out: $resource ($label)"
  print_namespace_diagnostics "diagnostics after rollout failure: $resource"

  if [ -n "$selector" ]; then
    print_logs_for_selector "$selector" "$label"
  fi

  fatal "rollout failed or timed out: $resource ($label)"
}

wait_for_pvc_bound_or_diagnose() {
  local pvc_name="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0
  local phase=""

  log "waiting for PVC $NAMESPACE/$pvc_name to become Bound; timeout=${timeout_seconds}s"

  while [ "$elapsed" -le "$timeout_seconds" ]; do
    phase="$(k3s kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

    if [ "$phase" = "Bound" ]; then
      log "PVC $NAMESPACE/$pvc_name is Bound"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  warn "PVC $NAMESPACE/$pvc_name did not become Bound; current phase=${phase:-unknown}"
  k3s kubectl describe pvc "$pvc_name" -n "$NAMESPACE" 2>/dev/null || true
  print_namespace_diagnostics "diagnostics after PVC bind timeout: $pvc_name"
  fatal "PVC $NAMESPACE/$pvc_name did not become Bound within ${timeout_seconds}s"
}

apply_secret_if_required() {
  if requires_manifests_apply; then
    log "creating/updating Kubernetes secret $NAMESPACE/otp-relay-secrets"

    if k3s kubectl create secret generic otp-relay-secrets \
      --namespace "$NAMESPACE" \
      --from-literal=SMS_SECRET_TOKEN="$SMS_SECRET_TOKEN" \
      --from-literal=TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
      --from-literal=TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
      --dry-run=client -o yaml | k3s kubectl apply -f -; then
      log "Kubernetes secret $NAMESPACE/otp-relay-secrets applied"
      return 0
    fi

    print_namespace_diagnostics "diagnostics after secret apply failure"
    fatal "failed to create/update Kubernetes secret $NAMESPACE/otp-relay-secrets"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require secret apply; skipping Kubernetes secret"
  fi
}

verify_app_image_contents() {
  local tmp_container=""

  if ! requires_app_image; then
    return 0
  fi

  log "verifying built app image contains generated frontend bundle"

  tmp_container="$("$DOCKER_BIN" create "$APP_IMAGE")" || fatal "failed to create temporary container from app image: $APP_IMAGE"

  if ! "$DOCKER_BIN" cp "$tmp_container:/app/frontend/app.js" "$GENERATED_DIR/app-image-frontend-app.js" >/dev/null; then
    "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
    fatal "app image does not contain required /app/frontend/app.js"
  fi

  [ -s "$GENERATED_DIR/app-image-frontend-app.js" ] || {
    "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
    fatal "app image contains /app/frontend/app.js, but it is empty"
  }

  if "$DOCKER_BIN" cp "$tmp_container:/app/app.js" "$GENERATED_DIR/app-image-root-app.js" >/dev/null 2>&1; then
    "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
    fatal "app image contains forbidden root-level /app/app.js"
  fi

  if "$DOCKER_BIN" cp "$tmp_container:/app/frontend/app.jsx" "$GENERATED_DIR/app-image-frontend-app.jsx" >/dev/null 2>&1; then
    "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
    fatal "app image contains frontend source /app/frontend/app.jsx; runtime image should contain generated app.js only"
  fi

  "$DOCKER_BIN" rm -f "$tmp_container" >/dev/null 2>&1 || true
  log "app image frontend bundle validation passed"
}

build_and_import_images_if_required() {
  local tmp_app_tar=""
  local tmp_monitor_tar=""

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
      apply_manifest_or_diagnose "$MANIFEST_DIR/pv-nfs.yaml" "app static NFS PersistentVolume"
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
    apply_manifest_or_diagnose "$MANIFEST_DIR/pvc.yaml" "app data PersistentVolumeClaim"
  fi

  wait_for_pvc_bound_or_diagnose "$pvc_name" 180
  log "app storage resource check completed"
}

validate_running_app_frontend() {
  local app_pod=""

  if ! requires_app_image; then
    return 0
  fi

  log "validating generated frontend bundle inside running OTP Relay pod"

  rollout_status_or_diagnose "deployment/otp-relay" "240s" "OTP Relay app" "app=otp-relay"

  app_pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$app_pod" ] || {
    print_namespace_diagnostics "diagnostics after missing running otp-relay pod"
    fatal "could not find running otp-relay pod for frontend validation"
  }

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

apply_redis_resources_if_required() {
  if [ "${REDIS_ENABLED:-0}" != "1" ]; then
    log "REDIS_ENABLED=0; skipping Redis resources"
    return 0
  fi

  log "applying Redis HA shared-state resources"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-nfs-pv.yaml" "Redis NFS PersistentVolume"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-configmap.yaml" "Redis ConfigMap"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-service.yaml" "Redis Service"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-statefulset.yaml" "Redis StatefulSet"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-sentinel-configmap.yaml" "Redis Sentinel ConfigMap"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-sentinel-service.yaml" "Redis Sentinel Service"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-sentinel-deployment.yaml" "Redis Sentinel Deployment"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-haproxy-configmap.yaml" "Redis HAProxy ConfigMap"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-haproxy-deployment.yaml" "Redis HAProxy Deployment"
  apply_manifest_if_exists "$MANIFEST_DIR/otp-relay-pdb.yaml" "OTP Relay PDB"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-pdb.yaml" "Redis PDB"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-sentinel-pdb.yaml" "Redis Sentinel PDB"
  apply_manifest_if_exists "$MANIFEST_DIR/redis-haproxy-pdb.yaml" "Redis HAProxy PDB"

  rollout_status_or_diagnose "statefulset/otp-redis" "300s" "Redis StatefulSet" "app=otp-redis"
  rollout_status_or_diagnose "deployment/otp-redis-sentinel" "240s" "Redis Sentinel" "app=otp-redis-sentinel"
  rollout_status_or_diagnose "deployment/otp-redis-haproxy" "240s" "Redis HAProxy" "app=otp-redis-haproxy"
}

apply_app_resources_if_required() {
  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    apply_manifest_or_diagnose "$MANIFEST_DIR/deployment.yaml" "OTP Relay app deployment"
    apply_manifest_or_diagnose "$MANIFEST_DIR/service.yaml" "OTP Relay service"

    resolve_portal_url_from_service

    if [ "${INGRESS_ENABLED:-0}" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
      apply_manifest_or_diagnose "$MANIFEST_DIR/ingress.yaml" "OTP Relay ingress"
    else
      log "Ingress disabled or manifest missing; deleting existing otp-relay ingress if present"
      k3s kubectl delete ingress otp-relay -n "$NAMESPACE" --ignore-not-found=true
    fi
  else
    log "DEPLOY_MODE=$DEPLOY_MODE skips app deployment/service/ingress apply"
  fi
}

apply_monitor_resources_if_required() {
  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "monitor" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    apply_manifest_or_diagnose "$MANIFEST_DIR/deployment-monitor.yaml" "OTP monitor deployment"
    apply_manifest_or_diagnose "$MANIFEST_DIR/monitor-service.yaml" "OTP monitor service"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE skips monitor deployment/service apply"
  fi
}

apply_kubernetes_resources_if_required() {
  if [ "$DEPLOY_MODE" = "observability" ]; then
    log "DEPLOY_MODE=observability; applying observability resources only"

    log "applying observability manifests if present"
    apply_observability_manifests
    log "observability manifest apply completed"

    log "Kubernetes resource apply phase completed"
    return 0
  fi

  if requires_manifests_apply; then
    log "applying Kubernetes resources for DEPLOY_MODE=$DEPLOY_MODE"

    log "applying runtime ConfigMap"
    apply_runtime_configmap
    log "runtime ConfigMap apply completed"

    apply_app_storage_resources
    apply_redis_resources_if_required
    apply_app_resources_if_required
    apply_monitor_resources_if_required

    log "applying observability manifests if present"
    apply_observability_manifests
    log "observability manifest apply completed"

    if [ "${PORTAL_URL_CONFIG_REFRESHED:-0}" = "1" ]; then
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

  if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "monitor" ] || [ "$DEPLOY_MODE" = "manifests" ]; then
    rollout_status_or_diagnose "deployment/otp-monitor" "180s" "OTP monitor" "app=otp-monitor"
  fi

  if [ "$DEPLOY_MODE" = "manifests" ]; then
    log "manifest-only apply completed after rollout checks for existing deployments"
  fi

  log "Kubernetes resource apply phase completed"
}

copy_runtime_data_if_requested() {
  local pod=""
  local f=""

  if [ -n "${RUNTIME_DATA_DIR:-}" ] && { [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "app" ]; }; then
    [ -d "$RUNTIME_DATA_DIR" ] || fatal "RUNTIME_DATA_DIR does not exist: $RUNTIME_DATA_DIR"

    log "runtime data copy requested from $RUNTIME_DATA_DIR"
    rollout_status_or_diagnose "deployment/otp-relay" "240s" "OTP Relay app before runtime data copy" "app=otp-relay"

    log "finding current otp-relay app pod"
    pod="$(k3s kubectl get pod -n "$NAMESPACE" -l app=otp-relay --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$pod" ] || {
      print_namespace_diagnostics "diagnostics after missing app pod for runtime data copy"
      fatal "could not find running otp-relay pod for runtime data copy"
    }

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
