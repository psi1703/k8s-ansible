#!/usr/bin/env bash
# App/frontend build, generated staging directory, and bundle-only staging validation.
#
# Bundle-only rule:
#   This library must never contact, mutate, validate, or depend on a live
#   Kubernetes cluster.
#
# Forbidden here:
#   - k3s kubectl apply
#   - kubectl apply
#   - kubectl rollout
#   - namespace creation
#   - live PVC inspection
#   - live TLS secret inspection/creation
#   - live observability validation
#
# The production server receives only the finished bundle.

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

_bundle_manifest_lint_or_fatal() {
  local file="$1"
  local label="${2:-$file}"

  [ -f "$file" ] || fatal "cannot validate missing manifest: $file"
  [ -s "$file" ] || fatal "manifest exists but is empty: $file"

  log "bundle-only validating manifest file: $label"

  if grep -n $'\r' "$file" >/dev/null 2>&1; then
    fatal "manifest contains CRLF line endings: $label"
  fi

  if ! grep -Eq '^[[:space:]]*apiVersion:[[:space:]]*' "$file"; then
    _dump_manifest_on_failure "$file"
    fatal "manifest is missing apiVersion: $label"
  fi

  if ! grep -Eq '^[[:space:]]*kind:[[:space:]]*' "$file"; then
    _dump_manifest_on_failure "$file"
    fatal "manifest is missing kind: $label"
  fi
}

_observability_file_requires_kubernetes_lint() {
  local file="$1"

  [ -f "$file" ] || return 1

  # Helm values files are bundled inputs, not Kubernetes API objects. They are
  # intentionally allowed to omit apiVersion/kind. Kubernetes-object YAMLs,
  # such as ServiceMonitor, Ingress, and generated Grafana dashboard ConfigMaps,
  # still receive strict apiVersion/kind validation.
  case "$(basename "$file")" in
    *-values.yaml|*-values.yml|values.yaml|values.yml)
      return 1
      ;;
  esac

  grep -Eq '^[[:space:]]*apiVersion:[[:space:]]*' "$file" || return 1
  grep -Eq '^[[:space:]]*kind:[[:space:]]*' "$file" || return 1

  return 0
}

_bundle_observability_file_lint_or_warn() {
  local file="$1"
  local label="${2:-$file}"

  [ -f "$file" ] || fatal "cannot validate missing observability file: $file"
  [ -s "$file" ] || fatal "observability file exists but is empty: $file"

  if grep -n $'\r' "$file" >/dev/null 2>&1; then
    fatal "observability file contains CRLF line endings: $label"
  fi

  if _observability_file_requires_kubernetes_lint "$file"; then
    _bundle_manifest_lint_or_fatal "$file" "$label"
  else
    log "bundle-only accepting observability values/input file without Kubernetes apiVersion/kind: $label"
  fi
}

_forbidden_live_cluster_guard() {
  local action="$1"

  fatal "forbidden live-cluster action attempted in bundle-only build-stage.sh: $action"
}

_kubectl_dry_run_or_fatal() {
  _forbidden_live_cluster_guard "kubectl dry-run"
}

_kubectl_apply_or_fatal() {
  _forbidden_live_cluster_guard "kubectl apply"
}

_validate_required_source_file() {
  local file="$1"

  [ -f "$file" ] || fatal "required source file is missing: $file"
}

_validate_required_source_dir() {
  local dir="$1"

  [ -d "$dir" ] || fatal "required source directory is missing: $dir"
}

requires_app_artifacts() {
  requires_app_image
}

requires_monitor_artifacts() {
  requires_monitor_image
}

requires_runtime_manifests() {
  case "${DEPLOY_MODE:-full}" in
    full|app|monitor) return 0 ;;
    *) return 1 ;;
  esac
}

initialize_generated_dir() {
  GENERATED_DIR="$(mktemp -d /tmp/otp-relay-k8s-bundle.XXXXXX)"
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

  export GENERATED_DIR
  export SOURCE_MANIFEST_DIR
  export SOURCE_OBSERVABILITY_DIR
  export MANIFEST_DIR
  export OBSERVABILITY_DIR
  export APP_DOCKERFILE
  export MONITOR_DOCKERFILE

  log "generated release staging directory: $GENERATED_DIR"
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
  if requires_app_artifacts; then
    log "preparing installer Python environment for app validation/help docs"
    _validate_required_source_file requirements.txt

    log "creating/updating .installer-venv"
    python3 -m venv .installer-venv

    _run_checked "upgrading installer Python packaging tools" \
      .installer-venv/bin/python -m pip install --upgrade pip setuptools wheel

    _run_checked "installing Python requirements from requirements.txt" \
      .installer-venv/bin/python -m pip install -r requirements.txt

    if [ "${SKIP_HELP_DOCS_BUILD:-0}" = "1" ]; then
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

    _run_checked "installing frontend build dependencies from committed package-lock.json" \
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
    grep -q 'script src="app.js"' frontend/index.html ||
      fatal "frontend/index.html must load generated bundle with: script src=\"app.js\""

    log "frontend production bundle generated and validated: frontend/app.js"
  else
    log "artifact selector DEPLOY_MODE=${DEPLOY_MODE:-full} does not require app help-doc/frontend build; skipping"
  fi

  if [ -f k8s/observability/dashboards/otp-relay-live.json ] && [ "${DEPLOY_MODE:-full}" != "none" ]; then
    _validate_required_source_file scripts/build_grafana_dashboard_configmap.py
    _run_checked "generating Grafana dashboard ConfigMap from dashboard JSON" \
      python3 scripts/build_grafana_dashboard_configmap.py
    log "Grafana dashboard ConfigMap generation completed"
  else
    log "Grafana dashboard ConfigMap generation skipped"
  fi
}

validate_dockerfile_packaging() {
  log "validating Dockerfile packaging requirements for selected artifacts"

  if requires_app_artifacts; then
    [ -n "${APP_DOCKERFILE:-}" ] || fatal "APP_DOCKERFILE is not set"
    [ -f "$APP_DOCKERFILE" ] || fatal "app Dockerfile is missing: $APP_DOCKERFILE"

    log "validating app Dockerfile includes otp_relay package and generated frontend"
    _validate_required_source_dir otp_relay
    _validate_required_source_file main.py
    [ -f frontend/app.js ] || fatal "frontend/app.js must exist before Docker image build/export"

    grep -Eq 'COPY[[:space:]].*otp_relay' "$APP_DOCKERFILE" ||
      fatal "$APP_DOCKERFILE must copy otp_relay/ into the image because main.py imports otp_relay.routes"

    grep -Eq 'COPY[[:space:]].*frontend' "$APP_DOCKERFILE" ||
      fatal "$APP_DOCKERFILE must copy frontend/ into the image"

    if grep -Eq 'COPY[[:space:]].*app\.js' "$APP_DOCKERFILE"; then
      fatal "$APP_DOCKERFILE must not copy root-level app.js. It must copy frontend/ after frontend/app.js is built."
    fi
  else
    log "artifact selector does not require app Dockerfile validation"
  fi

  if requires_monitor_artifacts; then
    [ -n "${MONITOR_DOCKERFILE:-}" ] || fatal "MONITOR_DOCKERFILE is not set"
    [ -f "$MONITOR_DOCKERFILE" ] || fatal "monitor Dockerfile is missing: $MONITOR_DOCKERFILE"

    log "validating monitor Dockerfile includes otp_monitor package"
    _validate_required_source_dir otp_monitor
    _validate_required_source_file monitor.py

    grep -Eq 'COPY[[:space:]].*otp_monitor' "$MONITOR_DOCKERFILE" ||
      fatal "$MONITOR_DOCKERFILE must copy otp_monitor/ into the image because monitor.py imports otp_monitor.runner"
  else
    log "artifact selector does not require monitor Dockerfile validation"
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
  log "copying base Kubernetes manifests into release staging directory"
  mkdir -p "$MANIFEST_DIR"
  cp "$SOURCE_MANIFEST_DIR"/*.yaml "$MANIFEST_DIR"/
  rm -f "$MANIFEST_DIR/secret-example.env"

  if [ -d "$SOURCE_OBSERVABILITY_DIR" ]; then
    log "copying observability manifests into release staging directory"
    mkdir -p "$OBSERVABILITY_DIR"
    find "$SOURCE_OBSERVABILITY_DIR" -maxdepth 1 -type f -name '*.yaml' -exec cp {} "$OBSERVABILITY_DIR"/ \;
  else
    log "observability source directory not found; skipping observability manifest staging"
  fi
}

validate_python_sources() {
  log "validating Python syntax"

  if requires_app_artifacts; then
    log "checking Python syntax for app sources"
    python3 -m py_compile main.py otp_relay/*.py
  fi

  if requires_monitor_artifacts; then
    log "checking Python syntax for monitor sources"
    python3 -m py_compile monitor.py otp_monitor/*.py
  fi

  log "Python syntax validation completed"
}

configure_bundle_storage_class() {
  log "configuring bundle storage class values without live PVC inspection"

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    [ -n "${NFS_STORAGE_CLASS:-}" ] || fatal "NFS_ENABLED=1 but NFS_STORAGE_CLASS is not set"

    if [ -z "${PVC_STORAGE_CLASS:-}" ]; then
      PVC_STORAGE_CLASS="$NFS_STORAGE_CLASS"
      export PVC_STORAGE_CLASS
      log "PVC_STORAGE_CLASS not set; using NFS_STORAGE_CLASS=$NFS_STORAGE_CLASS"
    fi
  fi
}

validate_existing_app_pvc_storage_class() {
  configure_bundle_storage_class
}

validate_rendered_manifest_files() {
  log "validating rendered manifest files without contacting a cluster"

  [ -d "$MANIFEST_DIR" ] || fatal "rendered manifest directory is missing: $MANIFEST_DIR"

  _bundle_manifest_lint_or_fatal "$MANIFEST_DIR/namespace.yaml" "namespace.yaml"

  if [ "${NFS_ENABLED:-0}" = "1" ] && [ -f "$MANIFEST_DIR/pv-nfs.yaml" ]; then
    _bundle_manifest_lint_or_fatal "$MANIFEST_DIR/pv-nfs.yaml" "pv-nfs.yaml"
  fi

  for core_manifest in \
    configmap.yaml \
    pvc.yaml \
    deployment.yaml \
    service.yaml \
    deployment-monitor.yaml \
    monitor-service.yaml; do
    _bundle_manifest_lint_or_fatal "$MANIFEST_DIR/$core_manifest" "$core_manifest"
  done

  if [ "${INGRESS_ENABLED:-0}" = "1" ] && [ -f "$MANIFEST_DIR/ingress.yaml" ]; then
    _bundle_manifest_lint_or_fatal "$MANIFEST_DIR/ingress.yaml" "ingress.yaml"
  fi

  if [ "${REDIS_ENABLED:-0}" = "1" ]; then
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
        _bundle_manifest_lint_or_fatal "$MANIFEST_DIR/$redis_manifest" "$redis_manifest"
      fi
    done
  fi

  if [ -d "${OBSERVABILITY_DIR:-}" ]; then
    find "$OBSERVABILITY_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 |
      while IFS= read -r -d '' observability_manifest; do
        _bundle_observability_file_lint_or_warn "$observability_manifest" "observability/$(basename "$observability_manifest")"
      done
  fi

  log "rendered manifest file validation completed"
}

dry_run_core_otp_relay_manifests() {
  validate_rendered_manifest_files
}

dry_run_redis_manifests() {
  validate_rendered_manifest_files
}

stage_metadata_only_bundle_inputs() {
  log "DEPLOY_MODE=none selected; staging metadata-only bundle inputs"

  mkdir -p "$GENERATED_DIR/metadata"
  cat > "$GENERATED_DIR/metadata/metadata-only.txt" <<EOF_METADATA_ONLY
OTP Relay bundle metadata-only mode

DEPLOY_MODE=none was selected.

No runtime manifests were rendered.
No Docker images were exported.
No live cluster operations were performed.
EOF_METADATA_ONLY

  chmod 0644 "$GENERATED_DIR/metadata/metadata-only.txt" 2>/dev/null || true
}

stage_and_validate_manifests() {
  log "staging repository Dockerfiles and Kubernetes manifests for release bundle"

  initialize_generated_dir

  if ! requires_runtime_manifests; then
    stage_metadata_only_bundle_inputs
    log "manifest staging skipped for DEPLOY_MODE=${DEPLOY_MODE:-none}"
    return 0
  fi

  mkdir -p "$MANIFEST_DIR"

  validate_staging_source_layout
  validate_dockerfile_packaging
  copy_manifests_to_staging
  configure_bundle_storage_class

  log "rendering Kubernetes manifests from .env configuration for bundle"
  render_manifests
  log "manifest rendering completed"

  if declare -F validate_rendered_manifests >/dev/null 2>&1; then
    validate_rendered_manifests
  fi

  validate_python_sources
  validate_rendered_manifest_files

  log "TLS secret creation/check is skipped in bundle-only mode"
  log "production TLS material must be handled by the approved production-side procedure"

  log "manifest staging and bundle-only validation completed"
}
