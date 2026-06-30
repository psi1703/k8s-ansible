#!/usr/bin/env bash
# Observability packaging helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Stage observability manifests/config files into the release bundle.
#   - Record intended Grafana/Prometheus/Loki/Alloy settings as metadata.
#   - Do not run helm repo/add/update/install/upgrade.
#   - Do not run kubectl apply.
#   - Do not query a live cluster.
#
# The production server receives only the finished bundle.

_observability_forbid_live_action() {
  local action="$1"

  fatal "forbidden observability live-cluster action in bundle-only mode: $action"
}

_observability_copy_if_exists() {
  local src="$1"
  local dst="$2"

  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

_observability_copy_tree_if_exists() {
  local src="$1"
  local dst="$2"

  if [ -d "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -a "$src" "$dst"
  fi
}

validate_observability_settings_for_bundle() {
  log "validating observability settings for bundle metadata"

  case "${OBSERVABILITY_INSTALL_STACK:-1}" in
    0|1) ;;
    *) fatal "OBSERVABILITY_INSTALL_STACK must be 0 or 1" ;;
  esac

  [ -n "${OBSERVABILITY_NAMESPACE:-}" ] || fatal "OBSERVABILITY_NAMESPACE is required"
  [ -n "${OBSERVABILITY_STACK_CHART_VERSION:-}" ] || fatal "OBSERVABILITY_STACK_CHART_VERSION is required"
  [ -n "${GRAFANA_HOST:-}" ] || fatal "GRAFANA_HOST is required"

  if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
    log "observability stack intent recorded: namespace=${OBSERVABILITY_NAMESPACE} chart=${OBSERVABILITY_STACK_CHART_VERSION} grafana_host=${GRAFANA_HOST}"
  else
    log "OBSERVABILITY_INSTALL_STACK=0; observability stack install intent disabled"
  fi
}

stage_observability_bundle_files() {
  local src_root=""
  local dst_root=""

  validate_observability_settings_for_bundle

  [ -n "${GENERATED_DIR:-}" ] || fatal "GENERATED_DIR is not set; cannot stage observability files"

  src_root="${INSTALL_DIR:-${SCRIPT_DIR:-$(pwd)}}/k8s/observability"
  dst_root="$GENERATED_DIR/observability"

  mkdir -p "$dst_root"

  if [ -d "$src_root" ]; then
    log "staging observability source files from $src_root"
    _observability_copy_tree_if_exists "$src_root" "$dst_root/source"
  else
    warn "observability source directory not found: $src_root"
  fi

  cat > "$dst_root/observability-release.env" <<EOF_OBS
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
OBSERVABILITY_INSTALL_STACK="${OBSERVABILITY_INSTALL_STACK:-1}"
OBSERVABILITY_STACK_CHART_VERSION="${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana-devprod.init-db.lan}"
NAMESPACE="${NAMESPACE:-otp-relay-devprod}"
TLS_ENABLED="${TLS_ENABLED:-0}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"
EOF_OBS

  cat > "$dst_root/README.md" <<EOF_README
# Observability production handoff

This directory contains observability files and metadata staged by the
bundle-only release builder.

The builder did not run Helm and did not apply Kubernetes resources.

Recorded intent:

- OBSERVABILITY_NAMESPACE: ${OBSERVABILITY_NAMESPACE:-observability-devprod}
- OBSERVABILITY_INSTALL_STACK: ${OBSERVABILITY_INSTALL_STACK:-1}
- OBSERVABILITY_STACK_CHART_VERSION: ${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}
- GRAFANA_HOST: ${GRAFANA_HOST:-grafana-devprod.init-db.lan}

Production-side Helm installation, chart upgrade, Grafana ingress creation,
ServiceMonitor application, Loki installation, Alloy installation, and dashboard
validation must be performed only by the approved production procedure.
EOF_README

  chmod 0644 "$dst_root/observability-release.env" "$dst_root/README.md" 2>/dev/null || true

  OBSERVABILITY_DIR="$dst_root"
  export OBSERVABILITY_DIR

  log "observability files staged for bundle: $OBSERVABILITY_DIR"
}

install_observability_if_requested() {
  stage_observability_bundle_files

  if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
    log "skipping observability Helm install/update in bundle-only mode"
  else
    log "observability install intent disabled"
  fi
}

apply_observability_manifests() {
  stage_observability_bundle_files
  log "skipping observability kubectl apply in bundle-only mode"
}

ensure_helm() {
  _observability_forbid_live_action "install/check Helm for live cluster"
}

helm_repo_add_or_update() {
  _observability_forbid_live_action "helm repo add/update"
}

install_kube_prometheus_stack_if_requested() {
  _observability_forbid_live_action "helm install/upgrade kube-prometheus-stack"
}

install_loki_if_requested() {
  _observability_forbid_live_action "helm install/upgrade Loki"
}

install_alloy_if_requested() {
  _observability_forbid_live_action "helm install/upgrade Alloy"
}

apply_grafana_dashboard_if_requested() {
  _observability_forbid_live_action "apply Grafana dashboard ConfigMap"
}

apply_service_monitors_if_requested() {
  _observability_forbid_live_action "apply ServiceMonitor resources"
}

apply_grafana_ingress_if_requested() {
  _observability_forbid_live_action "apply Grafana ingress"
}

wait_for_observability_rollouts() {
  _observability_forbid_live_action "wait for observability rollouts"
}

print_observability_diagnostics() {
  log "skipping observability diagnostics in bundle-only mode"
}
