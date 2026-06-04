#!/usr/bin/env bash
# App/frontend build, generated staging directory, and dry-run validation.

_run_checked() {
  local description="$1"
  shift

  log "$description"
  "$@"
}

_dump_manifest_on_failure() {
  local file="$1"

  warn "manifest validation failed: $file"
  if [ -f "$file" ]; then
    warn "first 160 lines of $file follow"
    sed -n '1,160p' "$file" >&2 || true
  fi
}

_kubectl_dry_run_or_fatal() {
  local file="$1"
  local label="${2:-$file}"

  [ -f "$file" ] || fatal "cannot dry-run missing manifest: $file"

  log "dry-run validating $label"
  if ! k3s kubectl apply --dry-run=client -f "$file" >/dev/null; then
    _dump_manifest_on_failure "$file"
    fatal "Kubernetes dry-run validation failed for $label"
  fi
}

_kubectl_apply_or_fatal() {
  local file="$1"
  local label="${2:-$file}"

  [ -f "$file" ] || fatal "cannot apply missing manifest: $file"

  log "applying $label"
  if ! k3s kubectl apply -f "$file"; then
    _dump_manifest_on_failure "$file"
    fatal "Kubernetes apply failed for $label"
  fi
}

_validate_required_source_file() {
  local file="$1"
  [ -f "$file" ] || fatal "required source file is missing: $file"
}

_validate_required_source_dir() {
  local dir="$1"
  [ -d "$dir" ] || fatal "required source directory is missing: $dir"
}

validate_frontend_source_tree() {
  log "validating frontend source tree"

  _validate_required_source_file package.json
  _validate_required_source_file package-lock.json
  _validate_required_source_file frontend/app.jsx
  _validate_required_source_file frontend/index.html
  _validate_required_source_file frontend/style.css

  if [ -f app.js ]; then
    fatal "root-level app.js exists. This is not allowed. Generated frontend bundle must be frontend/app.js only."
  fi

  if ! grep -q 'script src="app.js"' frontend/index.html; then
    fatal "frontend/index.html must load generated bundle with: script src=\"app.js\""
  fi

  log "frontend source tree validation completed"
}

build_app_assets_if_required() {
  if requires_app_image; then
    log "preparing installer Python environment for app validation/help docs"
    _validate_required_source_file requirements.txt

    log "creating/updating .installer-venv; this may take a moment"
    python3 -m venv .installer-venv

    _run_checked "upgrading installer Python packaging tools" \
      .installer-venv/bin/python -m pip install --upgrade pip setuptools wheel

    _run_checked "installing Python requirements from requirements.txt; this may take a few minutes" \
      .installer-venv/bin/python -m pip install -r requirements.txt

    if [ "$SKIP_HELP_DOCS_BUILD" = "1" ]; then
      log "skipping help docs build because SKIP_HELP_DOCS_BUILD=1"
    else
      _validate_required_source_file scripts/build_help_docs.py
      _run_checked "building help docs with scripts/build_help_docs.py" \
        .installer-venv/bin/python scripts/build_help_docs.py
      log "help docs build completed"
    fi

    validate_frontend_source_tree

    log "removing stale generated frontend bundle before rebuild"
    rm -f frontend/app.js frontend/app.raw.js

    _run_checked "installing frontend build dependencies from committed package-lock.json; npm ci may take a few minutes" \
      npm ci
    log "frontend dependencies installed"

    _run_checked "building production frontend bundle frontend/app.js" \
      npm run build:frontend

    [ -f frontend/app.js ] || fatal "frontend/app.js was not produced by npm run build:frontend"
    [ -s frontend/app.js ] || fatal "frontend/app.js was produced but is empty"

    if [ -f app.js ]; then
      fatal "npm build produced root-level app.js. Fix package.json so build:frontend outputs only frontend/app.js"
    fi

    if [ -f frontend/app.jsx ] && cmp -s frontend/app.jsx frontend/app.js 2>/dev/null; then
      fatal "frontend/app.js is identical to frontend/app.jsx; expected generated production bundle, not copied source"
    fi

    log "validating frontend bundle path and portal index"
    grep -q 'script src="app.js"' frontend/index.html || \
      fatal "frontend/index.html must load generated bundle with: script src=\"app.js\""

    log "frontend production bundle generated and validated: frontend/app.js"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require app help-doc/frontend build; skipping installer venv and npm build"
  fi

  if [ -f k8s/observability/dashboards/otp-relay-live.json ]; then
    _validate_required_source_file scripts/build_grafana_dashboard_configmap.py
    _run_checked "generating Grafana dashboard ConfigMap from dashboard JSON" \
      python3 scripts/build_grafana_dashboard_configmap.py
    log "Grafana dashboard ConfigMap generation completed"
  else
    log "Grafana dashboard JSON not found; skipping dashboard ConfigMap generation"
  fi
}

validate_dockerfile_packaging() {
  log "validating Dockerfile packaging requirements"

  [ -n "${APP_DOCKERFILE:-}" ] || fatal "APP_DOCKERFILE is not set"
  [ -n "${MONITOR_DOCKERFILE:-}" ] || fatal "MONITOR_DOCKERFILE is not set"
  [ -f "$APP_DOCKERFILE" ] || fatal "app Dockerfile is missing: $APP_DOCKERFILE"
  [ -f "$MONITOR_DOCKERFILE" ] || fatal "monitor Dockerfile is missing: $MONITOR_DOCKERFILE"

  if requires_app_image; then
    log "validating app Dockerfile includes otp_relay package and generated frontend"
    _validate_required_source_dir otp_relay
    _validate_required_source_file main.py
    [ -f frontend/app.js ] || fatal "frontend/app.js must exist before Docker image build"

    grep -Eq 'COPY[[:space:]].*otp_relay' "$APP_DOCKERFILE" || \
      fatal "$APP_DOCKERFILE must copy otp_relay/ into the image because main.py imports otp_relay.routes"

    grep -Eq 'COPY[[:space:]].*frontend' "$APP_DOCKERFILE" || \
      fatal "$APP_DOCKERFILE must copy frontend/ into the image"

    if grep -Eq 'COPY[[:space:]].*app\.js' "$APP_DOCKERFILE"; then
      fatal "$APP_DOCKERFILE must not copy root-level app.js. It must copy frontend/ after frontend/app.js is built."
    fi
  fi

  if requires_monitor_image; then
    log "validating monitor Dockerfile includes otp_monitor package"
    _validate_required_source_dir otp_monitor
    _validate_required_source_file monitor.py
    grep -Eq 'COPY[[:space:]].*otp_monitor' "$MONITOR_DOCKERFILE" || \
      fatal "$MONITOR_DOCKERFILE must copy otp_monitor/ into the image because monitor.py imports otp_monitor.runner"
  fi

  log "Dockerfile packaging validation completed"
}

validate_staging_source_layout() {
  log "validating manifest source layout"

  [ -n "${SOURCE_MANIFEST_DIR:-}" ] || fatal "SOURCE_MANIFEST_DIR is not set"
  [ -d "$SOURCE_MANIFEST_DIR" ] || fatal "Kubernetes manifest source directory is missing: $SOURCE_MANIFEST_DIR"

  for required_manifest in \
    namespace.yaml \
    configmap.yaml \
    pvc.yaml \
    deployment.yaml \
    service.yaml \
    deployment-monitor.yaml \
    monitor-service.yaml; do
    [ -f "$SOURCE_MANIFEST_DIR/$required_manifest" ] || fatal "required Kubernetes manifest is missing: $SOURCE_MANIFEST_DIR/$required_manifest"
  done

  if [ "${REDIS_ENABLED:-0}" = "1" ]; then
    for redis_manifest in \
      redis-service.yaml \
      redis-configmap.yaml \
      redis-statefulset.yaml \
      redis-sentinel-configmap.yaml \
      redis-sentinel-deployment.yaml \
      redis-sentinel-service.yaml \
      redis-haproxy-configmap.yaml \
      redis-haproxy-deployment.yaml \
      otp-relay-pdb.yaml \
      redis-pdb.yaml \
      redis-sentinel-pdb.yaml \
      redis-haproxy-pdb.yaml; do
      [ -f "$SOURCE_MANIFEST_DIR/$redis_manifest" ] || fatal "REDIS_ENABLED=1 but Redis manifest is missing: $SOURCE_MANIFEST_DIR/$redis_manifest"
    done
  fi

  log "manifest source layout validation completed"
}

copy_manifests_to_staging() {
  log "copying base Kubernetes manifests into staging directory"
  cp "$SOURCE_MANIFEST_DIR"/*.yaml "$MANIFEST_DIR"/
  rm -f "$MANIFEST_DIR/secret-example.env"

  if [ -d "$SOURCE_OBSERVABILITY_DIR" ]; then
    log "copying observability manifests into staging directory"
    mkdir -p "$OBSERVABILITY_DIR"
    find "$SOURCE_OBSERVABILITY_DIR" -maxdepth 1 -type f -name '*.yaml' -exec cp {} "$OBSERVABILITY_DIR"/ \;
  else
    log "observability source directory not found; skipping observability manifest staging"
  fi
}

validate_python_sources() {
  log "validating Python syntax"

  if requires_app_image; then
    log "checking Python syntax for app sources"
    python3 -m py_compile main.py otp_relay/*.py
  fi

  if requires_monitor_image; then
    log "checking Python syntax for monitor sources"
    python3 -m py_compile monitor.py otp_monitor/*.py
  fi

  log "Python syntax validation completed"
}

validate_existing_app_pvc_storage_class() {
  local existing_pvc_storage_class=""

  log "checking existing otp-relay-data PVC storage class"
  existing_pvc_storage_class="$(k3s kubectl get pvc otp-relay-data -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  existing_pvc_storage_class="$(printf '%s' "$existing_pvc_storage_class" | xargs)"

  if [ "$NFS_ENABLED" = "1" ]; then
    log "NFS storage enabled; ensuring PVC_STORAGE_CLASS uses $NFS_STORAGE_CLASS"
    if [ -z "${PVC_STORAGE_CLASS:-}" ]; then
      PVC_STORAGE_CLASS="$NFS_STORAGE_CLASS"
      export PVC_STORAGE_CLASS
    fi
  elif [ -n "$existing_pvc_storage_class" ] && [ -z "${PVC_STORAGE_CLASS:-}" ]; then
    warn "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; preserving it"
    PVC_STORAGE_CLASS="$existing_pvc_storage_class"
    export PVC_STORAGE_CLASS
  fi

  if [ -n "$existing_pvc_storage_class" ] && [ -n "${PVC_STORAGE_CLASS:-}" ] && [ "$PVC_STORAGE_CLASS" != "$existing_pvc_storage_class" ]; then
    fatal "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; refusing to change immutable storageClassName to $PVC_STORAGE_CLASS"
  fi
}

dry_run_core_otp_relay_manifests() {
  log "dry-run validating core OTP Relay manifests"

  for core_manifest in \
    configmap.yaml \
    pvc.yaml \
    deployment.yaml \
    service.yaml \
    deployment-monitor.yaml \
    monitor-service.yaml; do
    _kubectl_dry_run_or_fatal "$MANIFEST_DIR/$core_manifest" "$core_manifest"
  done

  if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
    _kubectl_dry_run_or_fatal "$MANIFEST_DIR/ingress.yaml" "ingress.yaml"
  fi
}

dry_run_redis_manifests() {
  [ "$REDIS_ENABLED" = "1" ] || return 0

  log "dry-run validating Redis manifests"
  for redis_manifest in \
    redis-nfs-pv.yaml \
    redis-service.yaml \
    redis-configmap.yaml \
    redis-statefulset.yaml \
    redis-sentinel-configmap.yaml \
    redis-sentinel-deployment.yaml \
    redis-sentinel-service.yaml \
    redis-haproxy-configmap.yaml \
    redis-haproxy-deployment.yaml \
    otp-relay-pdb.yaml \
    redis-pdb.yaml \
    redis-sentinel-pdb.yaml \
    redis-haproxy-pdb.yaml; do
    if [ -f "$MANIFEST_DIR/$redis_manifest" ]; then
      _kubectl_dry_run_or_fatal "$MANIFEST_DIR/$redis_manifest" "$redis_manifest"
    fi
  done
}

stage_and_validate_manifests() {
  log "staging repository Dockerfiles and Kubernetes manifests for deployment"

  GENERATED_DIR="$(mktemp -d /tmp/otp-relay-k8s.XXXXXX)"
  SOURCE_MANIFEST_DIR="k8s/manifests"
  SOURCE_OBSERVABILITY_DIR="k8s/observability"
  MANIFEST_DIR="$GENERATED_DIR/manifests"
  OBSERVABILITY_DIR="$GENERATED_DIR/observability"
  APP_DOCKERFILE="k8s/Dockerfile"
  MONITOR_DOCKERFILE="k8s/Dockerfile.monitor"

  cleanup_generated_assets() {
    rm -rf "$GENERATED_DIR"
  }

  trap cleanup_generated_assets EXIT

  export GENERATED_DIR SOURCE_MANIFEST_DIR SOURCE_OBSERVABILITY_DIR MANIFEST_DIR OBSERVABILITY_DIR APP_DOCKERFILE MONITOR_DOCKERFILE

  log "generated staging directory: $GENERATED_DIR"
  mkdir -p "$MANIFEST_DIR"

  validate_staging_source_layout
  validate_dockerfile_packaging
  copy_manifests_to_staging
  validate_existing_app_pvc_storage_class

  log "rendering Kubernetes manifests from .env configuration"
  render_manifests
  log "manifest rendering completed"

  if declare -F validate_rendered_manifests >/dev/null 2>&1; then
    validate_rendered_manifests
  fi

  validate_python_sources

  _kubectl_dry_run_or_fatal "$MANIFEST_DIR/namespace.yaml" "namespace.yaml"

  if [ "$NFS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
    _kubectl_dry_run_or_fatal "$MANIFEST_DIR/pv-nfs.yaml" "pv-nfs.yaml"
  fi

  log "ensuring namespace exists before secret/TLS validation"
  _kubectl_apply_or_fatal "$MANIFEST_DIR/namespace.yaml" "namespace.yaml"

  log "checking TLS secret requirements"
  ensure_tls_secret_if_requested
  ensure_tls_secret_available_if_required

  dry_run_core_otp_relay_manifests
  dry_run_redis_manifests

  log "dry-run validating observability manifests if present"
  dry_run_observability_manifests

  log "manifest staging and validation completed"
}
