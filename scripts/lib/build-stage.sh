#!/usr/bin/env bash
# App/frontend build, generated staging directory, and dry-run validation.

build_app_assets_if_required() {
  if requires_app_image; then
    log "preparing installer Python environment for app validation/help docs"
    log "creating/updating .installer-venv; this may take a moment"
    python3 -m venv .installer-venv

    log "upgrading installer Python packaging tools"
    .installer-venv/bin/python -m pip install --upgrade pip setuptools wheel

    log "installing Python requirements from requirements.txt; this may take a few minutes"
    .installer-venv/bin/python -m pip install -r requirements.txt

    if [ "$SKIP_HELP_DOCS_BUILD" = "1" ]; then
      log "skipping help docs build because SKIP_HELP_DOCS_BUILD=1"
    else
      log "building help docs with scripts/build_help_docs.py"
      .installer-venv/bin/python scripts/build_help_docs.py
      log "help docs build completed"
    fi

    [ -f package.json ] || fatal "package.json is missing in repo root"
    [ -f package-lock.json ] || fatal "package-lock.json is missing in repo root"
    [ -f frontend/app.jsx ] || fatal "frontend/app.jsx is missing"
    [ -f frontend/index.html ] || fatal "frontend/index.html is missing"
    [ -f frontend/style.css ] || fatal "frontend/style.css is missing"

    if [ -f app.js ]; then
      fatal "root-level app.js exists. This is not allowed. Generated frontend bundle must be frontend/app.js only."
    fi

    log "removing stale generated frontend bundle before rebuild"
    rm -f frontend/app.js frontend/app.raw.js

    log "installing frontend build dependencies from committed package-lock.json; npm ci may take a few minutes"
    npm ci
    log "frontend dependencies installed"

    log "building production frontend bundle frontend/app.js"
    npm run build:frontend

    [ -f frontend/app.js ] || fatal "frontend/app.js was not produced by npm run build:frontend"
    [ -s frontend/app.js ] || fatal "frontend/app.js was produced but is empty"

    if [ -f app.js ]; then
      fatal "npm build produced root-level app.js. Fix package.json so build:frontend outputs only frontend/app.js"
    fi

    log "validating frontend bundle path and portal index"
    grep -q 'script src="app.js"' frontend/index.html || \
      fatal "frontend/index.html must load generated bundle with: script src=\"app.js\""

    log "frontend production bundle generated and validated: frontend/app.js"
  else
    log "DEPLOY_MODE=$DEPLOY_MODE does not require app help-doc/frontend build; skipping installer venv and npm build"
  fi

  if [ -f k8s/observability/dashboards/otp-relay-live.json ]; then
    log "generating Grafana dashboard ConfigMap from dashboard JSON"
    python3 scripts/build_grafana_dashboard_configmap.py
    log "Grafana dashboard ConfigMap generation completed"
  else
    log "Grafana dashboard JSON not found; skipping dashboard ConfigMap generation"
  fi
}

validate_dockerfile_packaging() {
  log "validating Dockerfile packaging requirements"

  [ -f "$APP_DOCKERFILE" ] || fatal "app Dockerfile is missing: $APP_DOCKERFILE"
  [ -f "$MONITOR_DOCKERFILE" ] || fatal "monitor Dockerfile is missing: $MONITOR_DOCKERFILE"

  if requires_app_image; then
    log "validating app Dockerfile includes otp_relay package and generated frontend"
    [ -d otp_relay ] || fatal "otp_relay package directory is missing from repo root"
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
    [ -d otp_monitor ] || fatal "otp_monitor package directory is missing from repo root"
    grep -Eq 'COPY[[:space:]].*otp_monitor' "$MONITOR_DOCKERFILE" || \
      fatal "$MONITOR_DOCKERFILE must copy otp_monitor/ into the image because monitor.py imports otp_monitor.runner"
  fi

  log "Dockerfile packaging validation completed"
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

  log "generated staging directory: $GENERATED_DIR"
  mkdir -p "$MANIFEST_DIR"

  validate_dockerfile_packaging

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

  log "checking existing otp-relay-data PVC storage class"
  existing_pvc_storage_class="$(k3s kubectl get pvc otp-relay-data -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  existing_pvc_storage_class="$(printf '%s' "$existing_pvc_storage_class" | xargs)"

  if [ "$NFS_ENABLED" = "1" ]; then
    log "NFS storage enabled; ensuring PVC_STORAGE_CLASS uses $NFS_STORAGE_CLASS"
    if [ -z "$PVC_STORAGE_CLASS" ]; then
      PVC_STORAGE_CLASS="$NFS_STORAGE_CLASS"
    fi
  elif [ -n "$existing_pvc_storage_class" ] && [ -z "$PVC_STORAGE_CLASS" ]; then
    warn "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; preserving it"
    PVC_STORAGE_CLASS="$existing_pvc_storage_class"
  fi

  if [ -n "$existing_pvc_storage_class" ] && [ -n "$PVC_STORAGE_CLASS" ] && [ "$PVC_STORAGE_CLASS" != "$existing_pvc_storage_class" ]; then
    fatal "PVC otp-relay-data already exists with storageClassName=$existing_pvc_storage_class; refusing to change immutable storageClassName to $PVC_STORAGE_CLASS"
  fi

  log "rendering Kubernetes manifests from .env configuration"
  render_manifests
  log "manifest rendering completed"

  log "validating Python syntax and Kubernetes manifests"

  if requires_app_image; then
    log "checking Python syntax for app sources"
    python3 -m py_compile main.py otp_relay/*.py
  fi

  if requires_monitor_image; then
    log "checking Python syntax for monitor sources"
    python3 -m py_compile monitor.py otp_monitor/*.py
  fi

  log "dry-run validating namespace manifest"
  k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/namespace.yaml" >/dev/null

  if [ "$NFS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
    log "dry-run validating NFS PV manifest"
    k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/pv-nfs.yaml" >/dev/null
  fi

  log "ensuring namespace exists before secret/TLS validation"
  k3s kubectl apply -f "$MANIFEST_DIR/namespace.yaml"

  log "checking TLS secret requirements"
  ensure_tls_secret_if_requested
  ensure_tls_secret_available_if_required

  log "dry-run validating core OTP Relay manifests"
  k3s kubectl apply --dry-run=client \
    -f "$MANIFEST_DIR/configmap.yaml" \
    -f "$MANIFEST_DIR/pvc.yaml" \
    -f "$MANIFEST_DIR/deployment.yaml" \
    -f "$MANIFEST_DIR/service.yaml" \
    -f "$MANIFEST_DIR/deployment-monitor.yaml" \
    -f "$MANIFEST_DIR/monitor-service.yaml" >/dev/null

  if [ "$INGRESS_ENABLED" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
    log "dry-run validating ingress manifest"
    k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/ingress.yaml" >/dev/null
  fi

  if [ "$REDIS_ENABLED" = "1" ]; then
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
        log "dry-run validating Redis manifest: $redis_manifest"
        k3s kubectl apply --dry-run=client -f "$MANIFEST_DIR/$redis_manifest" >/dev/null
      fi
    done
  fi

  log "dry-run validating observability manifests if present"
  dry_run_observability_manifests

  log "manifest staging and validation completed"
}
