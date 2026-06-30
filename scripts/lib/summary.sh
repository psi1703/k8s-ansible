#!/usr/bin/env bash
# Final cleanliness check, release bundle summary, and bundle report generation.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Report generated bundle artifacts only.
#   - Do not query Kubernetes.
#   - Do not print live kubectl/k3s commands as the result of this build.
#   - Do not claim deployment completed.
#
# The production server receives only the finished bundle.

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
  fatal "kubectl/k3s summary queries are forbidden in bundle-only mode"
}

summary_kubectl_available() {
  return 1
}

summary_get_traefik_address() {
  return 0
}

summary_normalize_url() {
  local url="${1:-}"

  if [ -z "$url" ]; then
    printf 'not-set'
    return 0
  fi

  printf '%s' "${url%/}/"
}

summary_release_report_path() {
  local base="${GENERATED_DIR:-${SCRIPT_DIR:-$(pwd)}}"
  printf '%s/release-report.txt' "$base"
}

summary_install_report_path() {
  summary_release_report_path
}

summary_append_command_output() {
  local report_file="$1"
  local title="$2"
  shift 2

  {
    printf '\n### %s\n\n' "$title"
    printf 'Command execution is disabled in bundle-only summary mode.\n'
    printf 'Requested command was not run:'
    printf ' %q' "$@"
    printf '\n'
  } >> "$report_file"
}

check_working_tree_cleanliness() {
  local dirty_status=""

  log "checking build working tree cleanliness"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty_status="$(git status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty_status" ]; then
      warn "build working tree has uncommitted/generated files:"
      printf '%s\n' "$dirty_status" >&2
      warn "review generated files and .gitignore; bundle creation can continue, but source state is not clean"
    else
      log "build working tree is clean"
    fi
  else
    warn "build path is not a Git working tree; skipping cleanliness check"
  fi
}

write_release_report() {
  local report_file="${INSTALL_REPORT_PATH:-}"
  local namespace="${NAMESPACE:-otp-relay-devprod}"
  local observability_namespace="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
  local generated_dir="${GENERATED_DIR:-not-set}"
  local release_bundle="${RELEASE_BUNDLE_PATH:-${BUNDLE_PATH:-not-set}}"
  local checksum_file="${RELEASE_BUNDLE_SHA256_PATH:-${BUNDLE_SHA256_PATH:-not-set}}"

  if [ -z "$report_file" ]; then
    report_file="$(summary_release_report_path)"
  fi

  mkdir -p "$(dirname "$report_file")" 2>/dev/null || true

  cat > "$report_file" <<EOF_REPORT
OTP Relay Kubernetes release bundle report
Generated: $(summary_now_utc)

Bundle-only status
------------------
Release mode:            bundle-only
Deployment executed:     no
K3s installed:           no
Helm executed:           no
Kubectl apply executed:  no
Image import executed:   no
Live validation:         no
VM provisioning:         no
GitHub runner install:   no

Bundle artifacts
----------------
Generated dir:           $generated_dir
Release bundle:          $release_bundle
Release checksum:        $checksum_file
Manifest dir:            $(summary_value "${MANIFEST_DIR:-}" "not-staged")
Observability dir:       $(summary_value "${OBSERVABILITY_DIR:-}" "not-staged")

Configuration summary
---------------------
Portal URL:              $(summary_normalize_url "${PORTAL_URL:-}")
Grafana URL:             ${GRAFANA_URL_SUMMARY:-planned/disabled}
NodePort URL:            ${NODEPORT_SUMMARY:-planned/disabled}
Service type:            $(summary_value "${SERVICE_TYPE:-}")
LoadBalancer address:    $(summary_value "${LOADBALANCER_IP:-}" "auto/none")
Ingress enabled:         ${INGRESS_ENABLED:-0}
TLS enabled:             ${TLS_ENABLED:-0}
Ingress/TLS host:        $(summary_value "${TLS_HOST:-}" "none")
TLS secret name:         $(summary_value "${TLS_SECRET_NAME:-}" "none")
TLS self-signed:         ${TLS_SELF_SIGNED:-0}
MetalLB planned:         ${INSTALL_METALLB:-0}
MetalLB range:           $(summary_value "${METALLB_IP_RANGE:-}" "none")
Namespace:               $namespace
Repo path:               $(summary_value "${INSTALL_DIR:-${SCRIPT_DIR:-}}" "not-set")
OS/arch:                 $(summary_value "${OS_NAME:-}") / $(summary_value "${ARCH_RAW:-}")
Artifact selector:       ${DEPLOY_MODE:-full}
Runner requested:        forced-disabled
App replicas:            ${REPLICA_COUNT:-1}
App node selector:       $(summary_value "${APP_NODE_SELECTOR_KEY:-}" "none")=${APP_NODE_SELECTOR_VALUE:-}
Monitor node selector:   $(summary_value "${MONITOR_NODE_SELECTOR_KEY:-}" "none")=${MONITOR_NODE_SELECTOR_VALUE:-}
Redis node selector:     $(summary_value "${REDIS_NODE_SELECTOR_KEY:-}" "none")=${REDIS_NODE_SELECTOR_VALUE:-}
PVC storage:             ${PVC_STORAGE_CLASS:-default} / ${PVC_SIZE:-unknown}
NFS app storage:         $(summary_bool_enabled "${NFS_ENABLED:-0}") server=$(summary_value "${NFS_SERVER:-}" "none") path=$(summary_value "${NFS_PATH:-}" "none") class=${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs} pv=${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}
Redis:                   enabled=${REDIS_ENABLED:-0} required=${REDIS_REQUIRED:-0} url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/${REDIS_SIZE:-unknown}
Image distribution:      disabled in build path
Observability:           namespace=$observability_namespace stack_planned=${OBSERVABILITY_INSTALL_STACK:-1} grafana_host=${GRAFANA_HOST:-grafana-devprod.init-db.lan} chart=${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}
Monitor config:          PHONE_IP=${PHONE_IP:-not-set} PHONE_INTERFACE=${PHONE_INTERFACE:-not-set} interval=${PHONE_PING_INTERVAL:-not-set}s threshold=${PHONE_OFFLINE_THRESHOLD:-not-set}s

Production handoff
------------------
The production server receives only the finished bundle.

Production-side installation, image loading, Helm execution, kubectl apply,
rollout validation, secret inspection, and operational checks are intentionally
outside this build path and must be performed only by the approved production
procedure.
EOF_REPORT

  chmod 0644 "$report_file" 2>/dev/null || true
  INSTALL_REPORT_PATH="$report_file"
  RELEASE_REPORT_PATH="$report_file"
  export INSTALL_REPORT_PATH
  export RELEASE_REPORT_PATH
}

write_install_report() {
  write_release_report
}

print_release_bundle_summary() {
  local namespace="${NAMESPACE:-otp-relay-devprod}"
  local observability_namespace="${OBSERVABILITY_NAMESPACE:-observability-devprod}"
  local portal_url_summary
  local release_bundle="${RELEASE_BUNDLE_PATH:-${BUNDLE_PATH:-not-set}}"
  local checksum_file="${RELEASE_BUNDLE_SHA256_PATH:-${BUNDLE_SHA256_PATH:-not-set}}"

  NODEPORT_SUMMARY="disabled"
  if [ "${SERVICE_TYPE:-}" = "NodePort" ]; then
    NODEPORT_SUMMARY="planned NodePort ${SERVICE_NODE_PORT:-30080}"
  fi

  GRAFANA_URL_SUMMARY="disabled"
  if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
    GRAFANA_URL_SUMMARY="planned https://${GRAFANA_HOST:-grafana-devprod.init-db.lan}/"
  fi

  portal_url_summary="$(summary_normalize_url "${PORTAL_URL:-}")"

  write_release_report

  cat <<EOF_DONE

OTP Relay Kubernetes release bundle complete.

Bundle-only result:
  Deployment executed:     no
  K3s installed:           no
  Helm executed:           no
  Kubectl apply executed:  no
  Image import executed:   no
  Live validation:         no
  VM provisioning:         no
  GitHub runner install:   no

Release artifacts:
  Bundle:          $release_bundle
  SHA256:          $checksum_file
  Release report:  ${RELEASE_REPORT_PATH:-not-written}
  Generated dir:   ${GENERATED_DIR:-not-set}
  Manifest dir:    ${MANIFEST_DIR:-not-staged}
  Observability:   ${OBSERVABILITY_DIR:-not-staged}

Planned runtime configuration inside the bundle:
  Portal URL:            $portal_url_summary
  Grafana URL:           $GRAFANA_URL_SUMMARY
  NodePort:              $NODEPORT_SUMMARY
  Service type:          ${SERVICE_TYPE:-not-set}
  LoadBalancer:          ${LOADBALANCER_IP:-auto/none}
  Ingress:               enabled=${INGRESS_ENABLED:-0} tls=${TLS_ENABLED:-0} host=${TLS_HOST:-none} secret=${TLS_SECRET_NAME:-none} self_signed=${TLS_SELF_SIGNED:-0}
  MetalLB:               planned=${INSTALL_METALLB:-0} range=${METALLB_IP_RANGE:-none}
  Namespace:             $namespace
  Artifact selector:     ${DEPLOY_MODE:-full}
  App replicas:          ${REPLICA_COUNT:-1}
  App node selector:     ${APP_NODE_SELECTOR_KEY:-none}=${APP_NODE_SELECTOR_VALUE:-}
  Monitor node selector: ${MONITOR_NODE_SELECTOR_KEY:-none}=${MONITOR_NODE_SELECTOR_VALUE:-}
  Redis node selector:   ${REDIS_NODE_SELECTOR_KEY:-none}=${REDIS_NODE_SELECTOR_VALUE:-}
  PVC storage:           ${PVC_STORAGE_CLASS:-default} / ${PVC_SIZE:-unknown}
  NFS app storage:       enabled=${NFS_ENABLED:-0} server=${NFS_SERVER:-none} path=${NFS_PATH:-none} class=${NFS_STORAGE_CLASS:-otp-relay-devprod-nfs} pv=${NFS_PV_NAME:-otp-relay-data-devprod-nfs-pv}
  Redis:                 enabled=${REDIS_ENABLED:-0} required=${REDIS_REQUIRED:-0} url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/${REDIS_SIZE:-unknown}
  Observability:         namespace=$observability_namespace stack_planned=${OBSERVABILITY_INSTALL_STACK:-1} grafana_host=${GRAFANA_HOST:-grafana-devprod.init-db.lan} chart=${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}
  Monitor config:        PHONE_IP=${PHONE_IP:-not-set} PHONE_INTERFACE=${PHONE_INTERFACE:-not-set} interval=${PHONE_PING_INTERVAL:-not-set}s threshold=${PHONE_OFFLINE_THRESHOLD:-not-set}s

Production handoff:
  The production server receives only the finished bundle.
  Production-side execution must be performed only by the approved prod procedure.
EOF_DONE
}

print_deployment_summary() {
  fatal "print_deployment_summary is forbidden in bundle-only mode; use print_release_bundle_summary"
}
