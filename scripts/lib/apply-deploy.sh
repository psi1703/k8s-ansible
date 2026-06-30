#!/usr/bin/env bash
# Deprecated live Kubernetes apply/deploy helpers.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Do not create Kubernetes secrets.
#   - Do not apply manifests.
#   - Do not import images into K3s/containerd.
#   - Do not distribute images to worker nodes.
#   - Do not wait for PVCs.
#   - Do not roll out or restart deployments.
#   - Do not validate running pods.
#   - Do not copy runtime data into pods.
#   - Do not query live Kubernetes resources.
#
# The production server receives only the finished bundle.
#
# This file is intentionally retained as a safety guard for old function names.

_forbid_live_apply_deploy_action() {
  local action="$1"

  fatal "forbidden live Kubernetes deploy action in bundle-only mode: $action"
}

kubectl_resource_exists() {
  _forbid_live_apply_deploy_action "query Kubernetes resource existence"
}

print_namespace_diagnostics() {
  _forbid_live_apply_deploy_action "print live namespace diagnostics"
}

print_logs_for_selector() {
  _forbid_live_apply_deploy_action "read live pod logs"
}

apply_manifest_or_diagnose() {
  _forbid_live_apply_deploy_action "kubectl apply manifest"
}

apply_manifest_if_exists() {
  _forbid_live_apply_deploy_action "kubectl apply manifest if exists"
}

rollout_status_or_diagnose() {
  _forbid_live_apply_deploy_action "kubectl rollout status"
}

wait_for_pvc_bound_or_diagnose() {
  _forbid_live_apply_deploy_action "wait for live PVC binding"
}

apply_secret_if_required() {
  log "skipping Kubernetes secret creation in bundle-only mode"
  log "secret material is packaged/recorded only as production handoff input where applicable"
}

verify_app_image_contents() {
  local tmp_container=""

  if ! requires_app_image; then
    return 0
  fi

  [ -n "${DOCKER_BIN:-}" ] || fatal "DOCKER_BIN is not set; cannot inspect built app image"
  [ -n "${APP_IMAGE:-}" ] || fatal "APP_IMAGE is not set; cannot inspect built app image"
  [ -n "${GENERATED_DIR:-}" ] || fatal "GENERATED_DIR is not set; cannot write image validation artifacts"

  log "verifying built app image contains generated frontend bundle"

  tmp_container="$("$DOCKER_BIN" create "$APP_IMAGE")" ||
    fatal "failed to create temporary container from app image: $APP_IMAGE"

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
  _forbid_live_apply_deploy_action "build and import images into live K3s"
}

_storage_jsonpath() {
  _forbid_live_apply_deploy_action "query live storage jsonpath"
}

apply_app_storage_resources() {
  _forbid_live_apply_deploy_action "apply app storage resources"
}

validate_running_app_frontend() {
  _forbid_live_apply_deploy_action "validate frontend inside running pod"
}

apply_redis_resources_if_required() {
  _forbid_live_apply_deploy_action "apply Redis resources"
}

apply_app_resources_if_required() {
  _forbid_live_apply_deploy_action "apply app deployment/service/ingress"
}

apply_monitor_resources_if_required() {
  _forbid_live_apply_deploy_action "apply monitor deployment/service"
}

apply_kubernetes_resources_if_required() {
  log "skipping Kubernetes resource apply in bundle-only mode"
  log "rendered manifests are staged into the release bundle only"
}

copy_runtime_data_if_requested() {
  if [ -n "${RUNTIME_DATA_DIR:-}" ]; then
    warn "RUNTIME_DATA_DIR is set, but live pod copy is disabled in bundle-only mode"
    warn "runtime data must be handled by the approved production-side procedure"
  else
    log "no runtime data copy requested"
  fi
}

mark_deployment_restart_required() {
  _forbid_live_apply_deploy_action "mark deployment restart required"
}

perform_pending_rollout_restarts() {
  log "skipping rollout restarts in bundle-only mode"
}

resolve_portal_url_from_service() {
  log "skipping live service URL resolution in bundle-only mode"
}
