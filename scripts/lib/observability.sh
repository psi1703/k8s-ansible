#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

ensure_observability_namespace() {
  local source_dir="${OBSERVABILITY_DIR:-}"
  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  local has_applyable_manifest=0
  local file

  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue

    case "$(basename "$file")" in
      *values.yaml|alloy-values.yaml|loki-values.yaml|prometheus-stack-values.yaml)
        continue
        ;;
      *)
        has_applyable_manifest=1
        break
        ;;
    esac
  done

  if [ "$has_applyable_manifest" = "1" ]; then
    log "ensuring observability namespace exists"
    k3s kubectl create namespace observability --dry-run=client -o yaml | k3s kubectl apply -f -
  fi
}

apply_observability_manifests() {
  local source_dir="${OBSERVABILITY_DIR:-}"
  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  ensure_observability_namespace

  local has_service_monitor_crd=0
  if k3s kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    has_service_monitor_crd=1
  fi

  local applied=0
  local file
  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue

    case "$(basename "$file")" in
      *values.yaml|alloy-values.yaml|loki-values.yaml|prometheus-stack-values.yaml)
        continue
        ;;
      servicemonitor-*.yaml)
        if [ "$has_service_monitor_crd" = "1" ]; then
          log "applying observability manifest $(basename "$file")"
          k3s kubectl apply -f "$file"
          applied=$((applied + 1))
        else
          warn "skipping $(basename "$file") because ServiceMonitor CRD is not installed"
        fi
        ;;
      *)
        log "applying observability manifest $(basename "$file")"
        k3s kubectl apply -f "$file"
        applied=$((applied + 1))
        ;;
    esac
  done

  if [ "$applied" -gt 0 ]; then
    log "applied $applied observability manifest(s)"
  fi
}

dry_run_observability_manifests() {
  local source_dir="${OBSERVABILITY_DIR:-}"
  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  local has_service_monitor_crd=0
  if k3s kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    has_service_monitor_crd=1
  fi

  local file
  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue

    case "$(basename "$file")" in
      *values.yaml|alloy-values.yaml|loki-values.yaml|prometheus-stack-values.yaml)
        continue
        ;;
      servicemonitor-*.yaml)
        if [ "$has_service_monitor_crd" = "1" ]; then
          k3s kubectl apply --dry-run=client -f "$file" >/dev/null
        else
          warn "skipping dry-run for $(basename "$file") because ServiceMonitor CRD is not installed"
        fi
        ;;
      *)
        k3s kubectl apply --dry-run=client -f "$file" >/dev/null
        ;;
    esac
  done
}
