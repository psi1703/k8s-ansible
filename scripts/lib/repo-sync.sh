#!/usr/bin/env bash
# Repository sync and source validation for the bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Prepare source on the dev/build host only.
#   - Do not deploy.
#   - Do not pull or mutate anything on the production server.
#   - Do not run Kubernetes, Helm, Ansible, K3s, or runner setup.
#
# The production server receives only the finished bundle.

_repo_sync_realpath_parent_safe() {
  local path="$1"
  local parent=""
  local base=""

  if [ -d "$path" ]; then
    (
      cd "$path"
      pwd
    )
    return 0
  fi

  parent="$(dirname "$path")"
  base="$(basename "$path")"

  if [ -d "$parent" ]; then
    (
      cd "$parent"
      printf '%s/%s\n' "$(pwd)" "$base"
    )
    return 0
  fi

  printf '%s\n' "$path"
}

_sync_requires_remote_repo() {
  [ "${SKIP_REPO_SYNC:-auto}" != "1" ]
}

_sync_validate_remote_config() {
  if _sync_requires_remote_repo; then
    [ -n "${REPO_URL:-}" ] || fatal "REPO_URL is required when repository sync is enabled"
    [ -n "${REPO_REF:-}" ] || fatal "REPO_REF is required when repository sync is enabled"
  fi
}

sync_deployment_repo() {
  local script_dir_real=""
  local install_dir_real=""
  local env_source_file="${ENV_FILE:-}"

  log "preparing release source repository on dev/build host"

  script_dir_real="$(
    cd "$SCRIPT_DIR"
    pwd
  )"
  install_dir_real="$(_repo_sync_realpath_parent_safe "$INSTALL_DIR")"

  log "script directory: $script_dir_real"
  log "release source directory: $install_dir_real"
  log "repo sync mode: SKIP_REPO_SYNC=${SKIP_REPO_SYNC:-auto}"

  if [ "${SKIP_REPO_SYNC:-auto}" = "auto" ] && [ "$script_dir_real" = "$install_dir_real" ]; then
    log "SKIP_REPO_SYNC=auto and launcher already runs from release source directory; skipping git sync"
    SKIP_REPO_SYNC="1"
    export SKIP_REPO_SYNC
  fi

  _sync_validate_remote_config

  if [ "${SKIP_REPO_SYNC:-auto}" = "1" ]; then
    log "using existing source repository at $script_dir_real; skipping git sync"
    INSTALL_DIR="$script_dir_real"
    export INSTALL_DIR
  elif [ -d "$INSTALL_DIR/.git" ]; then
    log "syncing source repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
    log "updating git remote origin URL"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" || true

    log "fetching repository ref from origin"
    git -C "$INSTALL_DIR" fetch --prune origin "$REPO_REF"

    log "resetting build working tree to origin/$REPO_REF"
    git -C "$INSTALL_DIR" reset --hard "origin/$REPO_REF"

    if [ "${GIT_CLEAN:-1}" = "1" ]; then
      log "cleaning untracked files in source working tree, preserving local env/data/log files"
      git -C "$INSTALL_DIR" clean -ffd -e data/ -e .env -e k8s/manifests/secret.env -e '*.log'
      log "git clean completed"
    else
      log "GIT_CLEAN=${GIT_CLEAN:-0}; skipping git clean"
    fi
  elif [ -e "$INSTALL_DIR" ]; then
    fatal "$INSTALL_DIR exists but is not a git repo. Move it away, set INSTALL_DIR to another path, or run from the synced repo with SKIP_REPO_SYNC=1."
  else
    log "cloning source repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
    git clone --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
    log "repository clone completed"
  fi

  cd "$INSTALL_DIR"

  if [ -f "$env_source_file" ] && [ "$env_source_file" != "$INSTALL_DIR/.env" ]; then
    log "copying environment source file into release source repository .env"
    cp "$env_source_file" "$INSTALL_DIR/.env"
    chmod 0600 "$INSTALL_DIR/.env"
    ENV_FILE="$INSTALL_DIR/.env"
    export ENV_FILE
    log "environment source copied to $ENV_FILE"
  elif [ -f "$INSTALL_DIR/.env" ]; then
    ENV_FILE="$INSTALL_DIR/.env"
    export ENV_FILE
  fi

  log "release source repo: $(git rev-parse --short HEAD 2>/dev/null || echo no-git): $(git log -1 --pretty=%s 2>/dev/null || echo local-files)"
  log "release source repository preparation completed"
}

validate_frontend_source_tree() {
  log "validating frontend source tree and generated artifact policy"

  [ -d frontend ] || fatal "frontend/ directory is missing"
  [ -f frontend/index.html ] || fatal "frontend/index.html is missing"
  [ -f frontend/app.jsx ] || fatal "frontend/app.jsx source is missing"
  [ -f frontend/style.css ] || fatal "frontend/style.css is missing"

  if [ -f app.js ]; then
    fatal "root-level app.js exists. Delete it from the repo. Generated browser bundle must be frontend/app.js only."
  fi

  if ! grep -q 'script src="app.js"' frontend/index.html; then
    fatal "frontend/index.html must load the generated frontend bundle with: script src=\"app.js\""
  fi

  log "frontend source tree validation completed"
}

validate_app_source_tree() {
  log "checking app source files for release bundle"

  [ -f main.py ] || fatal "main.py is missing in repo root"
  [ -d otp_relay ] || fatal "otp_relay/ package is missing"
  [ -f requirements.txt ] || fatal "requirements.txt is missing in repo root"
  [ -f package.json ] || fatal "package.json is missing in repo root"
  [ -f package-lock.json ] || fatal "package-lock.json is missing in repo root"
  [ -f k8s/Dockerfile ] || fatal "k8s/Dockerfile is missing"

  validate_frontend_source_tree

  [ -f scripts/build_help_docs.py ] || fatal "required help-doc builder is missing: scripts/build_help_docs.py"
  [ -d docs/help ] || fatal "required help-doc input directory is missing: docs/help"

  log "app source tree validation completed"
}

validate_monitor_source_tree() {
  log "checking monitor source files for release bundle"

  [ -f monitor.py ] || fatal "monitor.py is required and missing in repo root"
  [ -d otp_monitor ] || fatal "otp_monitor/ package is missing"
  [ -f requirements.txt ] || fatal "requirements.txt is missing in repo root"
  [ -f k8s/Dockerfile.monitor ] || fatal "k8s/Dockerfile.monitor is missing"

  if [ -z "${PHONE_IP:-}" ]; then
    warn "PHONE_IP is not set. It will remain a production-side runtime configuration responsibility."
  fi

  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    warn "Telegram alert credentials are not set. Monitor image can still be built; production secrets must be handled separately."
  fi

  log "monitor source tree validation completed"
}

validate_manifest_source_tree() {
  log "checking Kubernetes manifest source templates"

  [ -d k8s/manifests ] || fatal "k8s/manifests directory is missing"

  for required_manifest in \
    namespace.yaml \
    configmap.yaml \
    pvc.yaml \
    deployment.yaml \
    service.yaml \
    deployment-monitor.yaml \
    monitor-service.yaml; do
    [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
  done

  if [ "${INGRESS_ENABLED:-0}" = "1" ]; then
    [ -f "k8s/manifests/ingress.yaml" ] || fatal "INGRESS_ENABLED=1 but k8s/manifests/ingress.yaml is missing"
  fi

  if [ "${NFS_ENABLED:-0}" = "1" ]; then
    [ -f "k8s/manifests/pv-nfs.yaml" ] || fatal "NFS_ENABLED=1 but k8s/manifests/pv-nfs.yaml is missing"
  fi

  if [ "${REDIS_ENABLED:-0}" = "1" ]; then
    log "REDIS_ENABLED=1; checking required Redis manifest templates"
    for required_manifest in \
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
      [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
    done
  else
    log "REDIS_ENABLED=0; skipping Redis manifest source validation"
  fi

  if [ -f k8s/observability/dashboards/otp-relay-live.json ]; then
    [ -f scripts/build_grafana_dashboard_configmap.py ] || fatal "required Grafana dashboard ConfigMap builder is missing: scripts/build_grafana_dashboard_configmap.py"
  fi

  log "manifest source template validation completed"
}

validate_source_tree() {
  log "checking required source files for release bundle"

  case "${DEPLOY_MODE:-full}" in
    none)
      log "DEPLOY_MODE=none; skipping runtime source tree validation"
      ;;
    app)
      validate_app_source_tree
      validate_manifest_source_tree
      ;;
    monitor)
      validate_monitor_source_tree
      validate_manifest_source_tree
      ;;
    full)
      validate_app_source_tree
      validate_monitor_source_tree
      validate_manifest_source_tree
      ;;
    *)
      fatal "unsupported DEPLOY_MODE during source validation: ${DEPLOY_MODE:-}"
      ;;
  esac

  log "required source tree validation completed"
}
