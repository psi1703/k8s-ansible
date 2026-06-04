#!/usr/bin/env bash
# Observability installation and manifest apply support for install-otp-relay-k8s.sh.
# Source this file; do not execute it directly.
#
# Contract:
#   - Owns kube-prometheus-stack installation when OBSERVABILITY_INSTALL_STACK=1.
#   - Owns Loki installation from k8s/observability/loki-values.yaml when present.
#   - Owns Alloy installation from k8s/observability/alloy-values.yaml when present.
#   - Owns applying OTP Relay dashboard, ServiceMonitor, and Grafana IngressRoute manifests.
#   - Treats k8s/observability/*values.yaml as Helm values, not raw Kubernetes manifests.
#   - Fails fast when observability is enabled but the requested stack cannot be made usable.

OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
OBSERVABILITY_INSTALL_STACK="${OBSERVABILITY_INSTALL_STACK:-1}"

OBSERVABILITY_STACK_RELEASE="${OBSERVABILITY_STACK_RELEASE:-kube-prometheus-stack}"
OBSERVABILITY_STACK_REPO_NAME="${OBSERVABILITY_STACK_REPO_NAME:-prometheus-community}"
OBSERVABILITY_STACK_REPO_URL="${OBSERVABILITY_STACK_REPO_URL:-https://prometheus-community.github.io/helm-charts}"
OBSERVABILITY_STACK_CHART="${OBSERVABILITY_STACK_CHART:-kube-prometheus-stack}"
OBSERVABILITY_STACK_CHART_VERSION="${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}"

# SCH-aligned log stack:
# - Loki chart moved from grafana/loki to grafana-community/loki.
# - Alloy remains in the grafana chart repo.
OBSERVABILITY_LOKI_RELEASE="${OBSERVABILITY_LOKI_RELEASE:-loki}"
OBSERVABILITY_LOKI_REPO_NAME="${OBSERVABILITY_LOKI_REPO_NAME:-grafana-community}"
OBSERVABILITY_LOKI_REPO_URL="${OBSERVABILITY_LOKI_REPO_URL:-https://grafana.github.io/helm-charts}"
OBSERVABILITY_LOKI_CHART="${OBSERVABILITY_LOKI_CHART:-loki}"
OBSERVABILITY_LOKI_CHART_VERSION="${OBSERVABILITY_LOKI_CHART_VERSION:-13.7.0}"

OBSERVABILITY_ALLOY_RELEASE="${OBSERVABILITY_ALLOY_RELEASE:-alloy}"
OBSERVABILITY_ALLOY_REPO_NAME="${OBSERVABILITY_ALLOY_REPO_NAME:-grafana}"
OBSERVABILITY_ALLOY_REPO_URL="${OBSERVABILITY_ALLOY_REPO_URL:-https://grafana.github.io/helm-charts}"
OBSERVABILITY_ALLOY_CHART="${OBSERVABILITY_ALLOY_CHART:-alloy}"
OBSERVABILITY_ALLOY_CHART_VERSION="${OBSERVABILITY_ALLOY_CHART_VERSION:-1.8.1}"

OBSERVABILITY_HELM_TIMEOUT="${OBSERVABILITY_HELM_TIMEOUT:-15m}"
HELM_KUBECONFIG="${HELM_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana-test.lan}"

ensure_helm_kubeconfig() {
  if [ -f "$HELM_KUBECONFIG" ]; then
    export KUBECONFIG="$HELM_KUBECONFIG"
    return 0
  fi

  if [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
    return 0
  fi

  fatal "Helm kubeconfig not found. Expected HELM_KUBECONFIG=$HELM_KUBECONFIG or a valid KUBECONFIG."
}

helm_k3s() {
  ensure_helm_kubeconfig
  helm "$@"
}

_observability_source_dir() {
  printf '%s\n' "${OBSERVABILITY_DIR:-}"
}

_observability_values_file() {
  local source_dir
  source_dir="$(_observability_source_dir)"
  printf '%s\n' "$source_dir/prometheus-stack-values.yaml"
}

_observability_loki_values_file() {
  local source_dir
  source_dir="$(_observability_source_dir)"
  printf '%s\n' "$source_dir/loki-values.yaml"
}

_observability_alloy_values_file() {
  local source_dir
  source_dir="$(_observability_source_dir)"
  printf '%s\n' "$source_dir/alloy-values.yaml"
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

_service_monitor_crd_available() {
  k3s kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1
}

_grafana_service_available() {
  k3s kubectl get svc "${OBSERVABILITY_STACK_RELEASE}-grafana" -n "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1
}

_prometheus_service_available() {
  k3s kubectl get svc "${OBSERVABILITY_STACK_RELEASE}-prometheus" -n "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1
}

_loki_service_available() {
  k3s kubectl get svc "${OBSERVABILITY_LOKI_RELEASE}" -n "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1
}

_alloy_daemonset_available() {
  k3s kubectl get daemonset "${OBSERVABILITY_ALLOY_RELEASE}" -n "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1
}

_helm_available() {
  command -v helm >/dev/null 2>&1
}

run_apt_get_observability() {
  local attempt

  export DEBIAN_FRONTEND=noninteractive

  for attempt in 1 2 3; do
    if apt-get -o Acquire::Retries=3 "$@"; then
      return 0
    fi

    warn "apt-get $* failed on attempt $attempt/3"
    sleep 5
  done

  fatal "apt-get $* failed after 3 attempts"
}

print_observability_diagnostics() {
  log "observability diagnostics for namespace $OBSERVABILITY_NAMESPACE"

  k3s kubectl get namespace "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1 || {
    warn "namespace $OBSERVABILITY_NAMESPACE does not exist"
    return 0
  }

  k3s kubectl get pods -n "$OBSERVABILITY_NAMESPACE" -o wide || true
  k3s kubectl get svc -n "$OBSERVABILITY_NAMESPACE" || true
  k3s kubectl get daemonset -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
  k3s kubectl get ingress -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
  k3s kubectl get ingressroute -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
  k3s kubectl get servicemonitor -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
  k3s kubectl get configmap -n "$OBSERVABILITY_NAMESPACE" | grep -E 'grafana|dashboard|otp|loki|alloy' || true
  k3s kubectl get events -n "$OBSERVABILITY_NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -n 100 || true

  if command -v helm >/dev/null 2>&1; then
    helm_k3s list -n "$OBSERVABILITY_NAMESPACE" || true
    helm_k3s status "$OBSERVABILITY_STACK_RELEASE" -n "$OBSERVABILITY_NAMESPACE" || true
    helm_k3s status "$OBSERVABILITY_LOKI_RELEASE" -n "$OBSERVABILITY_NAMESPACE" || true
    helm_k3s status "$OBSERVABILITY_ALLOY_RELEASE" -n "$OBSERVABILITY_NAMESPACE" || true
  fi

  k3s kubectl describe deploy -n "$OBSERVABILITY_NAMESPACE" -l app.kubernetes.io/name=grafana 2>/dev/null || true
  k3s kubectl describe statefulset -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
  k3s kubectl describe daemonset "$OBSERVABILITY_ALLOY_RELEASE" -n "$OBSERVABILITY_NAMESPACE" 2>/dev/null || true
}

fatal_observability() {
  local message="$1"
  warn "$message"
  print_observability_diagnostics
  fatal "$message"
}

ensure_helm_available() {
  local tmp_helm_install

  if _helm_available; then
    log "Helm is already installed: $(helm version --short 2>/dev/null || echo helm)"
    return 0
  fi

  log "Helm is not installed; installing Helm 3"
  run_apt_get_observability update
  run_apt_get_observability install -y --no-install-recommends curl ca-certificates openssl tar gzip

  tmp_helm_install="$(mktemp)"
  cleanup_tmp_helm_install() {
    rm -f "$tmp_helm_install"
  }
  trap cleanup_tmp_helm_install RETURN

  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$tmp_helm_install" || \
    fatal "failed to download Helm installer from GitHub"
  chmod +x "$tmp_helm_install"
  "$tmp_helm_install"

  command -v helm >/dev/null 2>&1 || fatal "Helm installation completed but helm is not available on PATH"
  log "Helm installed: $(helm version --short 2>/dev/null || echo helm)"
}

ensure_observability_namespace() {
  local source_dir
  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  log "ensuring observability namespace exists: $OBSERVABILITY_NAMESPACE"
  k3s kubectl create namespace "$OBSERVABILITY_NAMESPACE" --dry-run=client -o yaml | k3s kubectl apply -f -
}

_add_or_update_helm_repo() {
  local repo_name="$1"
  local repo_url="$2"

  log "adding/updating Helm repo: $repo_name -> $repo_url"
  ensure_helm_kubeconfig
  helm_k3s repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
}

_update_helm_repos() {
  ensure_helm_kubeconfig
  helm_k3s repo update || fatal_observability "Helm repo update failed"
}

install_kube_prometheus_stack() {
  local source_dir values_file

  source_dir="$(_observability_source_dir)"
  [ -n "$source_dir" ] || {
    log "OBSERVABILITY_DIR is not set; skipping kube-prometheus-stack install"
    return 0
  }
  [ -d "$source_dir" ] || {
    log "observability directory does not exist: $source_dir; skipping kube-prometheus-stack install"
    return 0
  }

  if [ "$OBSERVABILITY_INSTALL_STACK" != "1" ]; then
    log "OBSERVABILITY_INSTALL_STACK=$OBSERVABILITY_INSTALL_STACK; skipping kube-prometheus-stack Helm install"
    return 0
  fi

  values_file="$(_observability_values_file)"
  [ -f "$values_file" ] || fatal "OBSERVABILITY_INSTALL_STACK=1 but missing Helm values file: $values_file"

  ensure_observability_namespace
  ensure_helm_available
  _add_or_update_helm_repo "$OBSERVABILITY_STACK_REPO_NAME" "$OBSERVABILITY_STACK_REPO_URL"
  _update_helm_repos

  log "installing/upgrading kube-prometheus-stack release $OBSERVABILITY_STACK_RELEASE in namespace $OBSERVABILITY_NAMESPACE"
  log "Helm chart: $OBSERVABILITY_STACK_REPO_NAME/$OBSERVABILITY_STACK_CHART version $OBSERVABILITY_STACK_CHART_VERSION"
  log "Values file: $values_file"

  if ! helm_k3s upgrade --install "$OBSERVABILITY_STACK_RELEASE" \
    "$OBSERVABILITY_STACK_REPO_NAME/$OBSERVABILITY_STACK_CHART" \
    --namespace "$OBSERVABILITY_NAMESPACE" \
    --create-namespace \
    --version "$OBSERVABILITY_STACK_CHART_VERSION" \
    -f "$values_file" \
    --wait \
    --timeout "$OBSERVABILITY_HELM_TIMEOUT"; then
    fatal_observability "kube-prometheus-stack Helm install/upgrade failed"
  fi

  log "kube-prometheus-stack Helm install/upgrade completed"

  wait_with_progress "waiting for ServiceMonitor CRD from kube-prometheus-stack" 180 5 _service_monitor_crd_available || \
    fatal_observability "ServiceMonitor CRD did not become available after kube-prometheus-stack install"
  wait_with_progress "waiting for Grafana service from kube-prometheus-stack" 180 5 _grafana_service_available || \
    fatal_observability "Grafana service did not become available after kube-prometheus-stack install"
  wait_with_progress "waiting for Prometheus service from kube-prometheus-stack" 180 5 _prometheus_service_available || \
    fatal_observability "Prometheus service did not become available after kube-prometheus-stack install"
}

install_loki_stack_if_available() {
  local source_dir values_file

  source_dir="$(_observability_source_dir)"
  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  if [ "$OBSERVABILITY_INSTALL_STACK" != "1" ]; then
    log "OBSERVABILITY_INSTALL_STACK=$OBSERVABILITY_INSTALL_STACK; skipping Loki Helm install"
    return 0
  fi

  values_file="$(_observability_loki_values_file)"
  if [ ! -f "$values_file" ]; then
    log "Loki values file not found; skipping Loki Helm install: $values_file"
    return 0
  fi

  ensure_observability_namespace
  ensure_helm_available
  _add_or_update_helm_repo "$OBSERVABILITY_LOKI_REPO_NAME" "$OBSERVABILITY_LOKI_REPO_URL"
  _update_helm_repos

  log "installing/upgrading Loki release $OBSERVABILITY_LOKI_RELEASE in namespace $OBSERVABILITY_NAMESPACE"
  log "Helm chart: $OBSERVABILITY_LOKI_REPO_NAME/$OBSERVABILITY_LOKI_CHART version $OBSERVABILITY_LOKI_CHART_VERSION"
  log "Values file: $values_file"

  if ! helm_k3s upgrade --install "$OBSERVABILITY_LOKI_RELEASE" \
    "$OBSERVABILITY_LOKI_REPO_NAME/$OBSERVABILITY_LOKI_CHART" \
    --namespace "$OBSERVABILITY_NAMESPACE" \
    --create-namespace \
    --version "$OBSERVABILITY_LOKI_CHART_VERSION" \
    -f "$values_file" \
    --wait \
    --timeout "$OBSERVABILITY_HELM_TIMEOUT"; then
    fatal_observability "Loki Helm install/upgrade failed"
  fi

  wait_with_progress "waiting for Loki service" 180 5 _loki_service_available || \
    fatal_observability "Loki service did not become available after Helm install"

  log "Loki Helm install/upgrade completed"
}

install_alloy_stack_if_available() {
  local source_dir values_file

  source_dir="$(_observability_source_dir)"
  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  if [ "$OBSERVABILITY_INSTALL_STACK" != "1" ]; then
    log "OBSERVABILITY_INSTALL_STACK=$OBSERVABILITY_INSTALL_STACK; skipping Alloy Helm install"
    return 0
  fi

  values_file="$(_observability_alloy_values_file)"
  if [ ! -f "$values_file" ]; then
    log "Alloy values file not found; skipping Alloy Helm install: $values_file"
    return 0
  fi

  ensure_observability_namespace
  ensure_helm_available
  _add_or_update_helm_repo "$OBSERVABILITY_ALLOY_REPO_NAME" "$OBSERVABILITY_ALLOY_REPO_URL"
  _update_helm_repos

  log "installing/upgrading Alloy release $OBSERVABILITY_ALLOY_RELEASE in namespace $OBSERVABILITY_NAMESPACE"
  log "Helm chart: $OBSERVABILITY_ALLOY_REPO_NAME/$OBSERVABILITY_ALLOY_CHART version $OBSERVABILITY_ALLOY_CHART_VERSION"
  log "Values file: $values_file"

  if ! helm_k3s upgrade --install "$OBSERVABILITY_ALLOY_RELEASE" \
    "$OBSERVABILITY_ALLOY_REPO_NAME/$OBSERVABILITY_ALLOY_CHART" \
    --namespace "$OBSERVABILITY_NAMESPACE" \
    --create-namespace \
    --version "$OBSERVABILITY_ALLOY_CHART_VERSION" \
    -f "$values_file" \
    --wait \
    --timeout "$OBSERVABILITY_HELM_TIMEOUT"; then
    fatal_observability "Alloy Helm install/upgrade failed"
  fi

  wait_with_progress "waiting for Alloy DaemonSet" 180 5 _alloy_daemonset_available || \
    fatal_observability "Alloy DaemonSet did not become available after Helm install"

  log "Alloy Helm install/upgrade completed"
}

install_observability_helm_stacks() {
  install_kube_prometheus_stack
  install_loki_stack_if_available
  install_alloy_stack_if_available
}

_render_observability_manifest() {
  local source_file="$1"
  local rendered_file="$2"

  cp "$source_file" "$rendered_file"

  # The source files are kept readable in git with observability/grafana defaults.
  # Render runtime namespace/host here so .env remains the operator source of truth.
  sed -i \
    -e "s/namespace: observability/namespace: ${OBSERVABILITY_NAMESPACE}/g" \
    -e "s/grafana\.init-db\.lan/${GRAFANA_HOST}/g" \
    "$rendered_file"

  if grep -nE 'CHANGE_ME_|__[^[:space:]]+__|grafana\.init-db\.lan' "$rendered_file" >/dev/null 2>&1; then
    warn "unresolved placeholder detected in rendered observability manifest from $(basename "$source_file")"
    grep -nE 'CHANGE_ME_|__[^[:space:]]+__|grafana\.init-db\.lan' "$rendered_file" >&2 || true
    return 1
  fi
}

_apply_rendered_manifest() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  cleanup_observability_render_tmp() {
    rm -f "$tmp"
  }
  trap cleanup_observability_render_tmp RETURN

  _render_observability_manifest "$file" "$tmp" || fatal "failed to render observability manifest: $file"

  if ! k3s kubectl apply -f "$tmp"; then
    warn "failed to apply rendered observability manifest: $file"
    sed -n '1,160p' "$tmp" >&2 || true
    fatal_observability "observability manifest apply failed: $(basename "$file")"
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
        _apply_rendered_manifest "$file"
      elif [ "$OBSERVABILITY_INSTALL_STACK" = "1" ]; then
        fatal_observability "ServiceMonitor CRD is missing after kube-prometheus-stack install; cannot apply $base"
      else
        warn "skipping $base because ServiceMonitor CRD is not installed"
      fi
      ;;

    grafana-ingress.yaml|grafana-ingressroute.yaml)
      if _grafana_service_available; then
        log "applying Grafana IngressRoute manifest $base for host $GRAFANA_HOST"
        _apply_rendered_manifest "$file"
      elif [ "$OBSERVABILITY_INSTALL_STACK" = "1" ]; then
        fatal_observability "Grafana service $OBSERVABILITY_NAMESPACE/${OBSERVABILITY_STACK_RELEASE}-grafana is missing; cannot apply $base"
      else
        warn "skipping $base because service $OBSERVABILITY_NAMESPACE/${OBSERVABILITY_STACK_RELEASE}-grafana does not exist"
      fi
      ;;

    grafana-dashboard-*.yaml)
      if _grafana_service_available; then
        log "applying Grafana dashboard ConfigMap $base"
        _apply_rendered_manifest "$file"
      elif [ "$OBSERVABILITY_INSTALL_STACK" = "1" ]; then
        fatal_observability "Grafana is missing; cannot apply dashboard ConfigMap $base"
      else
        warn "skipping $base because Grafana is not installed in namespace $OBSERVABILITY_NAMESPACE"
      fi
      ;;

    *)
      log "applying observability manifest $base"
      _apply_rendered_manifest "$file"
      ;;
  esac
}

apply_observability_manifests() {
  local source_dir file applied=0

  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || {
    log "OBSERVABILITY_DIR is not set; skipping observability"
    return 0
  }
  [ -d "$source_dir" ] || {
    log "observability directory does not exist: $source_dir; skipping observability"
    return 0
  }

  install_observability_helm_stacks
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

  if [ "$OBSERVABILITY_INSTALL_STACK" = "1" ]; then
    _grafana_service_available || fatal_observability "observability install completed but Grafana service is missing"
    _prometheus_service_available || fatal_observability "observability install completed but Prometheus service is missing"
    _service_monitor_crd_available || fatal_observability "observability install completed but ServiceMonitor CRD is missing"

    if [ -f "$source_dir/loki-values.yaml" ]; then
      _loki_service_available || fatal_observability "observability install completed but Loki service is missing"
    fi

    if [ -f "$source_dir/alloy-values.yaml" ]; then
      _alloy_daemonset_available || fatal_observability "observability install completed but Alloy DaemonSet is missing"
    fi
  fi

  log "observability status summary"
  print_observability_diagnostics
}

_dry_run_single_observability_manifest() {
  local file="$1"
  local base tmp

  base="$(basename "$file")"

  if _is_helm_values_file "$base"; then
    log "skipping dry-run for Helm values file: $base"
    return 0
  fi

  tmp="$(mktemp)"
  cleanup_observability_dryrun_tmp() {
    rm -f "$tmp"
  }
  trap cleanup_observability_dryrun_tmp RETURN

  _render_observability_manifest "$file" "$tmp" || fatal "failed to render observability manifest for dry-run: $file"

  case "$base" in
    servicemonitor-*.yaml)
      if _service_monitor_crd_available; then
        k3s kubectl apply --dry-run=client -f "$tmp" >/dev/null
      else
        warn "skipping dry-run for $base because ServiceMonitor CRD is not installed yet"
      fi
      ;;
    grafana-ingress.yaml|grafana-ingressroute.yaml)
      if _grafana_service_available; then
        k3s kubectl apply --dry-run=client -f "$tmp" >/dev/null
      else
        warn "skipping dry-run for $base because Grafana service is not installed yet"
      fi
      ;;
    grafana-dashboard-*.yaml)
      if _grafana_service_available; then
        k3s kubectl apply --dry-run=client -f "$tmp" >/dev/null
      else
        warn "skipping dry-run for $base because Grafana is not installed yet"
      fi
      ;;
    *)
      k3s kubectl apply --dry-run=client -f "$tmp" >/dev/null
      ;;
  esac
}

dry_run_observability_manifests() {
  local source_dir file

  source_dir="$(_observability_source_dir)"

  [ -n "$source_dir" ] || return 0
  [ -d "$source_dir" ] || return 0

  for file in "$source_dir"/*.yaml; do
    [ -f "$file" ] || continue
    _dry_run_single_observability_manifest "$file"
  done
}
