#!/usr/bin/env bash
# Repository sync and source validation.

sync_deployment_repo() {
  log "preparing deployment repository source"

  SCRIPT_DIR_REAL="$(cd "$SCRIPT_DIR" && pwd)"
  INSTALL_DIR_REAL="$(mkdir -p "$INSTALL_DIR" 2>/dev/null || true; cd "$INSTALL_DIR" 2>/dev/null && pwd || printf '%s' "$INSTALL_DIR")"

  log "script directory: $SCRIPT_DIR_REAL"
  log "install directory: $INSTALL_DIR_REAL"
  log "repo sync mode: SKIP_REPO_SYNC=$SKIP_REPO_SYNC"

  if [ "$SKIP_REPO_SYNC" = "auto" ] && [ "$SCRIPT_DIR_REAL" = "$INSTALL_DIR_REAL" ]; then
    log "SKIP_REPO_SYNC=auto and script already runs from install directory; skipping git sync"
    SKIP_REPO_SYNC=1
  fi

  if [ "$SKIP_REPO_SYNC" = "1" ]; then
    log "using existing synced repository at $SCRIPT_DIR_REAL; skipping installer git sync"
    INSTALL_DIR="$SCRIPT_DIR_REAL"
  elif [ -d "$INSTALL_DIR/.git" ]; then
    log "syncing repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
    log "updating git remote origin URL"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" || true

    log "fetching repository ref from origin; this may take a few minutes on slow networks"
    git -C "$INSTALL_DIR" fetch --prune origin "$REPO_REF"

    log "resetting working tree to origin/$REPO_REF"
    git -C "$INSTALL_DIR" reset --hard "origin/$REPO_REF"

    if [ "$GIT_CLEAN" = "1" ]; then
      log "cleaning untracked files in repo working tree, preserving common local data/secret files"
      git -C "$INSTALL_DIR" clean -ffd -e data/ -e .env -e k8s/manifests/secret.env -e '*.log'
      log "git clean completed"
    else
      log "GIT_CLEAN=$GIT_CLEAN; skipping git clean"
    fi
  elif [ -e "$INSTALL_DIR" ]; then
    fatal "$INSTALL_DIR exists but is not a git repo. Move it away, set INSTALL_DIR to another path, or run from the synced repo with SKIP_REPO_SYNC=1."
  else
    log "cloning repository into $INSTALL_DIR from $REPO_URL ref $REPO_REF"
    log "git clone may take a few minutes on slow networks"
    git clone --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
    log "repository clone completed"
  fi

  cd "$INSTALL_DIR"

  if [ -f "$ENV_FILE" ] && [ "$ENV_FILE" != "$INSTALL_DIR/.env" ]; then
    log "copying environment source file into synced repository .env"
    cp "$ENV_FILE" "$INSTALL_DIR/.env"
    chmod 0600 "$INSTALL_DIR/.env"
    ENV_FILE="$INSTALL_DIR/.env"
    export ENV_FILE
    log "environment source copied to $ENV_FILE"
  fi

  log "deployment source repo: $(git rev-parse --short HEAD 2>/dev/null || echo no-git): $(git log -1 --pretty=%s 2>/dev/null || echo local-files)"
  log "deployment repository preparation completed"
}

validate_source_tree() {
  log "checking required source files"

  [ -f main.py ] || fatal "main.py is missing in repo root"
  [ -f monitor.py ] || fatal "monitor.py is required and missing in repo root"
  [ -d otp_relay ] || fatal "otp_relay/ package is missing"
  [ -d otp_monitor ] || fatal "otp_monitor/ package is missing"
  [ -f requirements.txt ] || fatal "requirements.txt is missing in repo root"
  [ -d frontend ] || fatal "frontend/ directory is missing"
  [ -f frontend/index.html ] || fatal "frontend/index.html is missing"
  [ -f frontend/app.jsx ] || fatal "frontend/app.jsx source is missing"
  [ -f frontend/style.css ] || fatal "frontend/style.css is missing"
  [ -f k8s/Dockerfile ] || fatal "k8s/Dockerfile is missing"
  [ -f k8s/Dockerfile.monitor ] || fatal "k8s/Dockerfile.monitor is missing"
  [ -d k8s/manifests ] || fatal "k8s/manifests directory is missing"

  log "checking required core Kubernetes manifests"
  for required_manifest in namespace.yaml pvc.yaml deployment.yaml service.yaml deployment-monitor.yaml monitor-service.yaml; do
    [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
  done

  if [ "$REDIS_ENABLED" = "1" ]; then
    log "REDIS_ENABLED=1; checking required Redis manifests"
    for required_manifest in \
      redis-service.yaml \
      redis-configmap.yaml \
      redis-statefulset.yaml \
      redis-sentinel-configmap.yaml \
      redis-sentinel-deployment.yaml \
      redis-sentinel-service.yaml \
      redis-haproxy-configmap.yaml \
      redis-haproxy-deployment.yaml \
      redis-pdb.yaml; do
      [ -f "k8s/manifests/$required_manifest" ] || fatal "k8s/manifests/$required_manifest is missing"
    done
  else
    log "REDIS_ENABLED=0; skipping Redis manifest source validation"
  fi

  [ -f scripts/build_help_docs.py ] || fatal "required help-doc builder is missing: scripts/build_help_docs.py"
  [ -d docs/help ] || fatal "required help-doc input directory is missing: docs/help"
  [ -f scripts/build_grafana_dashboard_configmap.py ] || fatal "required Grafana dashboard ConfigMap builder is missing: scripts/build_grafana_dashboard_configmap.py"

  if [ -z "$PHONE_IP" ]; then
    fatal "PHONE_IP is required because monitor.py is a core component"
  fi

  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    warn "Telegram alert credentials are not set. monitor.py will still run, but Telegram phone-state alerts will be skipped."
  fi

  log "required source tree validation completed"
}
