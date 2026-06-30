#!/usr/bin/env bash
# Final cleanliness check, deployment summary, and install report generation.
# Source this file; do not execute it directly.

summary_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

summary_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

summary_value() {
  local value="${1:-}"
  local fallback="${2:-not-set}"

  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

summary_bool_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) printf 'enabled' ;;
    *) printf 'disabled' ;;
  esac
}

summary_kubectl() {
  if summary_cmd_exists k3s; then
    k3s kubectl "$@"
  elif summary_cmd_exists kubectl; then
    kubectl "$@"
  else
    return 127
  fi
}

summary_kubectl_available() {
  summary_kubectl get nodes >/dev/null 2>&1
}

summary_get_traefik_address() {
  local address=""

  if ! summary_kubectl_available; then
    return 0
  fi

  address="$(summary_kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -z "$address" ]; then
    address="$(summary_kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi
  if [ -z "$address" ]; then
    address="$(summary_kubectl -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi

  printf '%s' "$address"
}

summary_normalize_url() {
  local url="${1:-}"

  if [ -z "$url" ]; then
    printf 'not-set'
    return 0
  fi

  printf '%s' "${url%/}/"
}

summary_install_report_path() {
  local base="${INSTALL_DIR:-${SCRIPT_DIR:-$(pwd)}}"
  printf '%s/install-report.txt' "$base"
}

summary_append_command_output() {
  local report_file="$1"
  local title="$2"
  shift 2

  {
    printf '\n### %s\n\n' "$title"
    printf '$'
    printf ' %q' "$@"
    printf '\n'
  } >> "$report_file"

  if "$@" >> "$report_file" 2>&1; then
    return 0
  fi

  {
    printf '\n[command failed or unavailable; continuing summary generation]\n'
  } >> "$report_file"
}

check_working_tree_cleanliness() {
  local dirty_status=""

  log "checking deployment working tree cleanliness"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty_status="$(git status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty_status" ]; then
      warn "deployment working tree has uncommitted/generated files:"
      printf '%s\n' "$dirty_status" >&2
      warn "tracked modifications should now be unexpected; generated/frontend/server-local files should be covered by .gitignore"
    else
      log "deployment working tree is clean"
    fi
  else
    warn "deployment path is not a Git working tree; skipping cleanliness check"
  fi
}

write_install_report() {
  local report_file="${INSTALL_REPORT_PATH:-}"
  local namespace="${NAMESPACE:-otp-relay-devprod}"
  local observability_namespace="${OBSERVABILITY_NAMESPACE:-observability-devprod}"

  if [ -z "$report_file" ]; then
    report_file="$(summary_install_report_path)"
  fi

  mkdir -p "$(dirname "$report_file")" 2>/dev/null || true

  cat > "$report_file" <<EOF_REPORT
OTP Relay Kubernetes install report
Generated: $(summary_now_utc)

Configuration summary
---------------------
Portal URL:              $(summary_normalize_url "${PORTAL_URL:-}")
Grafana URL:             ${GRAFANA_URL_SUMMARY:-disabled}
NodePort URL:            ${NODEPORT_SUMMARY:-disabled}
Service type:            $(summary_value "${SERVICE_TYPE:-}")
LoadBalancer address:    $(summary_value "${ASSIGNED_LOADBALANCER_ADDRESS:-${LOADBALANCER_IP:-}}" "auto/none")
Ingress enabled:         ${INGRESS_ENABLED:-0}
TLS enabled:             ${TLS_ENABLED:-0}
Ingress/TLS host:        $(summary_value "${TLS_HOST:-}" "none")
TLS secret:              $(summary_value "${TLS_SECRET_NAME:-}" "none")
TLS self-signed:         ${TLS_SELF_SIGNED:-0}
MetalLB install:         ${INSTALL_METALLB:-0}
MetalLB range:           $(summary_value "${METALLB_IP_RANGE:-}" "none")
Namespace:               $namespace
Repo path:               $(summary_value "${INSTALL_DIR:-}")
OS/arch:                 $(summary_value "${OS_NAME:-}") / $(summary_value "${ARCH_RAW:-}")
Deploy mode:             ${DEPLOY_MODE:-full}
Runner requested:        ${INSTALL_GITHUB_RUNNER:-0}
Runner only:             ${RUNNER_ONLY:-0}
App replicas:            ${REPLICA_COUNT:-1}
App node selector:       $(summary_value "${APP_NODE_SELECTOR_KEY:-}" "none")=${APP_NODE_SELECTOR_VALUE:-}
Monitor node selector:   $(summary_value "${MONITOR_NODE_SELECTOR_KEY:-}" "none")=${MONITOR_NODE_SELECTOR_VALUE:-}
Redis node selector:     $(summary_value "${REDIS_NODE_SELECTOR_KEY:-}" "none")=${REDIS_NODE_SELECTOR_VALUE:-}
PVC storage:             ${PVC_STORAGE_CLASS:-default} / ${PVC_SIZE:-unknown}
NFS app storage:         $(summary_bool_enabled "${NFS_ENABLED:-0}") server=$(summary_value "${NFS_SERVER:-}" "none") path=$(summary_value "${NFS_PATH:-}" "none") class=${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs} pv=${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}
Redis:                   enabled=${REDIS_ENABLED:-0} required=${REDIS_REQUIRED:-0} url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/${REDIS_SIZE:-unknown} spread_recreate_pvcs=${REDIS_SPREAD_RECREATE_PVCS:-0}
Image distribution:      enabled=${DISTRIBUTE_IMAGES_TO_NODES:-0} importer=${IMAGE_IMPORTER_IMAGE:-none} port=${IMAGE_DISTRIBUTION_PORT:-none}
Observability:           namespace=$observability_namespace install_stack=${OBSERVABILITY_INSTALL_STACK:-1} grafana_host=${GRAFANA_HOST:-grafana-devprod.init-db.lan} chart=${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}
Monitor config:          PHONE_IP=${PHONE_IP:-not-set} PHONE_INTERFACE=${PHONE_INTERFACE:-not-set} interval=${PHONE_PING_INTERVAL:-not-set}s threshold=${PHONE_OFFLINE_THRESHOLD:-not-set}s
EOF_REPORT

  if summary_kubectl_available; then
    summary_append_command_output "$report_file" "Cluster nodes" summary_kubectl get nodes -o wide
    summary_append_command_output "$report_file" "OTP Relay pods" summary_kubectl get pods -n "$namespace" -o wide
    summary_append_command_output "$report_file" "OTP Relay services and ingress" summary_kubectl get svc,ingress -n "$namespace" -o wide
    summary_append_command_output "$report_file" "OTP Relay PVCs" summary_kubectl get pvc -n "$namespace" -o wide
    summary_append_command_output "$report_file" "OTP Relay Redis pods" summary_kubectl get pods -n "$namespace" -l app=otp-redis -o wide
    summary_append_command_output "$report_file" "Kube-system Traefik service" summary_kubectl -n kube-system get svc traefik -o wide

    if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
      summary_append_command_output "$report_file" "Observability resources" summary_kubectl get pods,svc,ingressroute,servicemonitor -n "$observability_namespace" -o wide
    fi
  else
    {
      printf '\nCluster status\n--------------\n'
      printf 'kubectl/k3s is unavailable or cluster is not reachable from this host.\n'
    } >> "$report_file"
  fi

  chmod 0644 "$report_file" 2>/dev/null || true
  INSTALL_REPORT_PATH="$report_file"
  export INSTALL_REPORT_PATH
}

print_deployment_summary() {
  local namespace="${NAMESPACE:-otp-relay-devprod}"
  local observability_namespace="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
  local traefik_address=""
  local portal_url_summary=""

  NODEPORT_SUMMARY="disabled"
  if [ "${SERVICE_TYPE:-}" = "NodePort" ]; then
    NODEPORT_SUMMARY="http://${SERVER_IP:-127.0.0.1}:${SERVICE_NODE_PORT:-30080}/"
  fi

  traefik_address="$(summary_get_traefik_address)"
  TLS_READYZ_COMMAND="# TLS is disabled or TLS_HOST is not configured."
  if [ "${TLS_ENABLED:-0}" = "1" ] && [ -n "${TLS_HOST:-}" ]; then
    if [ -n "$traefik_address" ]; then
      TLS_READYZ_COMMAND="curl -k --resolve ${TLS_HOST}:443:${traefik_address} https://${TLS_HOST}/readyz"
    else
      TLS_READYZ_COMMAND="curl -k --resolve ${TLS_HOST}:443:<TRAEFIK_LB_IP> https://${TLS_HOST}/readyz"
    fi
  fi

  GRAFANA_URL_SUMMARY="disabled"
  if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
    GRAFANA_URL_SUMMARY="https://${GRAFANA_HOST:-grafana-devprod.init-db.lan}/"
  fi

  portal_url_summary="$(summary_normalize_url "${PORTAL_URL:-}")"

  write_install_report

  cat <<EOF_DONE

OTP Relay Kubernetes deployment complete.

Portal URL:   $portal_url_summary
Guide pop-out: opened from the portal as /guide.html?step=<step>&page=<page>
Grafana URL:  $GRAFANA_URL_SUMMARY
NodePort URL: $NODEPORT_SUMMARY
Service type: ${SERVICE_TYPE:-not-set}
LoadBalancer: ${ASSIGNED_LOADBALANCER_ADDRESS:-${LOADBALANCER_IP:-auto/none}}
Ingress:      enabled=${INGRESS_ENABLED:-0} tls=${TLS_ENABLED:-0} host=${TLS_HOST:-none} secret=${TLS_SECRET_NAME:-none} self_signed=${TLS_SELF_SIGNED:-0}
MetalLB:      install=${INSTALL_METALLB:-0} range=${METALLB_IP_RANGE:-none}
Namespace:    $namespace
Repo path:    ${INSTALL_DIR:-unknown}
Install report: ${INSTALL_REPORT_PATH:-not-written}
OS/arch:      ${OS_NAME:-unknown} / ${ARCH_RAW:-unknown}
Monitor:      installed as required component
Runner:       ${INSTALL_GITHUB_RUNNER:-0}
Runner only:  ${RUNNER_ONLY:-0}
Deploy mode:  ${DEPLOY_MODE:-full}
App replicas:          ${REPLICA_COUNT:-1}
App rollout strategy:  managed by rendered Kubernetes deployment manifest
App node selector:     ${APP_NODE_SELECTOR_KEY:-none}=${APP_NODE_SELECTOR_VALUE:-}
Monitor node selector: ${MONITOR_NODE_SELECTOR_KEY:-none}=${MONITOR_NODE_SELECTOR_VALUE:-}
Redis node selector:   ${REDIS_NODE_SELECTOR_KEY:-none}=${REDIS_NODE_SELECTOR_VALUE:-}
PVC storage:           ${PVC_STORAGE_CLASS:-default} / ${PVC_SIZE:-unknown}
NFS app storage:       enabled=${NFS_ENABLED:-0} server=${NFS_SERVER:-none} path=${NFS_PATH:-none} class=${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs} pv=${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}
Redis:                 enabled=${REDIS_ENABLED:-0} required=${REDIS_REQUIRED:-0} url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/${REDIS_SIZE:-unknown} spread_recreate_pvcs=${REDIS_SPREAD_RECREATE_PVCS:-0}
Image distribution:    enabled=${DISTRIBUTE_IMAGES_TO_NODES:-0} importer=${IMAGE_IMPORTER_IMAGE:-none} port=${IMAGE_DISTRIBUTION_PORT:-none}
Observability:         namespace=$observability_namespace install_stack=${OBSERVABILITY_INSTALL_STACK:-1} grafana_host=${GRAFANA_HOST:-grafana-devprod.init-db.lan} chart=${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}

Useful commands:
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl get nodes -o wide
  k3s kubectl get pods -n $namespace -o wide
  k3s kubectl logs -n $namespace deployment/otp-relay
  k3s kubectl logs -n $namespace deployment/otp-monitor
  k3s kubectl get svc,ingress,pvc -n $namespace -o wide
  k3s kubectl get pods -n $namespace -l app=otp-redis -o wide
  k3s kubectl get pods -n $namespace -l app=otp-redis-sentinel -o wide
  k3s kubectl get pods -n $namespace -l app=otp-redis-haproxy -o wide
  k3s kubectl get pods,svc,ingressroute,servicemonitor -n $observability_namespace -o wide
  k3s kubectl get secret kube-prometheus-stack-grafana -n $observability_namespace -o jsonpath='{.data.admin-password}' | base64 -d; echo
  k3s kubectl -n kube-system get svc traefik -o wide
  $TLS_READYZ_COMMAND
  curl -i http://127.0.0.1/readyz
  # If SERVICE_TYPE=NodePort:
  # curl -i http://127.0.0.1:${SERVICE_NODE_PORT:-30080}/readyz

Monitor config is in ConfigMap otp-relay-config:
  PHONE_IP=${PHONE_IP:-not-set}
  PHONE_INTERFACE=${PHONE_INTERFACE:-not-set}
  PHONE_PING_INTERVAL=${PHONE_PING_INTERVAL:-not-set}
  PHONE_OFFLINE_THRESHOLD=${PHONE_OFFLINE_THRESHOLD:-not-set}
  PORTAL_URL=${PORTAL_URL:-not-set}

SMS webhook secret token was generated/stored in Kubernetes secret otp-relay-secrets.
To print it on this server:
  k3s kubectl get secret otp-relay-secrets -n $namespace -o jsonpath='{.data.SMS_SECRET_TOKEN}' | base64 -d; echo
EOF_DONE
}
