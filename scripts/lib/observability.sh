#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.
#
# Important:
#   k8s/observability/*values.yaml files are Helm values, not Kubernetes manifests.
#   This installer currently applies only raw Kubernetes YAML manifests.
#   Therefore Grafana/Prometheus are considered "external/preinstalled" unless
#   a future Helm installation phase is added.

OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

_observability_source_dir() {
  printf '%s\n' "${OBSERVABILITY_DIR:-}"
}

_is_helm_values_file() {
  local base="$1"

  case "$base" in
    *values.yaml|alloy-values.yaml|loki-values.yaml|prometheus-stack-values.yaml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_has_applyable_observability_manifest() {
  local source_dir="$1"
  local file

  [ -n "$source_dir" ] || return 1
  [ -d "$source_dir" ] || return 1

  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue

    if _is_helm_values_file "$(basename "$file")"; then
      continue
    fi

    return 0
  done

  return 1
}

_service_monitor_crd_available() {
  k3s kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1
}

_grafana_service_available() {
  k3s kubectl get svc kube-prometheus-stack-grafana -n "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1
}

ensure_observability_namespace() {
  local source_dir
  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  if _has_applyable_observability_manifest "$source_dir"; then
    log "ensuring observability namespace exists"
    k3s kubectl create namespace "$OBSERVABILITY_NAMESPACE" --dry-run=client -o yaml | k3s kubectl apply -f -
  fi
}

_apply_single_observability_manifest() {
  local file="$1"
  local base
  base="$(basename "$file")"

  if _is_helm_values_file "$base"; then
    log "skipping Helm values file, not a raw Kubernetes manifest: $base"
    return 0
  fi

  case "$base" in
    servicemonitor-*.yaml)
      if _service_monitor_crd_available; then
        log "applying ServiceMonitor manifest $base"
        k3s kubectl apply -f "$file"
      else
        warn "skipping $base because ServiceMonitor CRD is not installed"
      fi
      ;;
    grafana-ingressroute.yaml)
      if _grafana_service_available; then
        log "applying Grafana IngressRoute manifest $base"
        k3s kubectl apply -f "$file"
      else
        warn "skipping $base because service $OBSERVABILITY_NAMESPACE/kube-prometheus-stack-grafana does not exist"
        warn "Grafana will 404 until kube-prometheus-stack is installed separately or Helm support is added"
      fi
      ;;
    grafana-dashboard-*.yaml)
      if _grafana_service_available; then
        log "applying Grafana dashboard ConfigMap $base"
        k3s kubectl apply -f "$file"
      else
        warn "skipping $base because Grafana is not installed in namespace $OBSERVABILITY_NAMESPACE"
      fi
      ;;
    *)
      log "applying observability manifest $base"
      k3s kubectl apply -f "$file"
      ;;
  esac
}

apply_observability_manifests() {
  local source_dir
  local file
  local applied=0

  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  ensure_observability_namespace

  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue

    _apply_single_observability_manifest "$file"
    applied=$((applied + 1))
  done

  if [ "$applied" -gt 0 ]; then
    log "processed $applied observability file(s)"
  else
    log "no observability files found to process"
  fi
}

_dry_run_single_observability_manifest() {
  local file="$1"
  local base
  base="$(basename "$file")"

  if _is_helm_values_file "$base"; then
    log "skipping dry-run for Helm values file: $base"
    return 0
  fi

  case "$base" in
    servicemonitor-*.yaml)
      if _service_monitor_crd_available; then
        k3s kubectl apply --dry-run=client -f "$file" >/dev/null
      else
        warn "skipping dry-run for $base because ServiceMonitor CRD is not installed"
      fi
      ;;
    grafana-ingressroute.yaml)
      if _grafana_service_available; then
        k3s kubectl apply --dry-run=client -f "$file" >/dev/null
      else
        warn "skipping dry-run for $base because Grafana service is not installed"
      fi
      ;;
    grafana-dashboard-*.yaml)
      if _grafana_service_available; then
        k3s kubectl apply --dry-run=client -f "$file" >/dev/null
      else
        warn "skipping dry-run for $base because Grafana is not installed"
      fi
      ;;
    *)
      k3s kubectl apply --dry-run=client -f "$file" >/dev/null
      ;;
  esac
}

dry_run_observability_manifests() {
  local source_dir
  local file

  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue
    _dry_run_single_observability_manifest "$file"
  done
}
