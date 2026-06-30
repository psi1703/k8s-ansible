#!/usr/bin/env bash
# MetalLB helpers for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# Bundle-only policy:
#   - Validate MetalLB-related values that are recorded in release metadata.
#   - Do not install MetalLB.
#   - Do not apply MetalLB manifests.
#   - Do not query Kubernetes resources.
#   - Do not wait for controller/webhook readiness.
#
# The production server receives only the finished bundle.

_metallb_forbid_live_action() {
  local action="$1"

  fatal "forbidden MetalLB live-cluster action in bundle-only mode: $action"
}

validate_metallb_settings_for_bundle() {
  log "validating MetalLB settings for bundle metadata"

  case "${REQUIRE_METALLB:-0}" in
    0|1) ;;
    *) fatal "REQUIRE_METALLB must be 0 or 1" ;;
  esac

  case "${INSTALL_METALLB:-0}" in
    0|1) ;;
    *) fatal "INSTALL_METALLB must be 0 or 1" ;;
  esac

  if [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] && [ "${REQUIRE_METALLB:-0}" = "1" ] && [ "${INSTALL_METALLB:-0}" != "1" ]; then
    warn "SERVICE_TYPE=LoadBalancer and REQUIRE_METALLB=1, but INSTALL_METALLB=0"
    warn "bundle will record this intent only; production-side procedure must handle LoadBalancer prerequisites"
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    [ -n "${METALLB_VERSION:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_VERSION"
    [ -n "${METALLB_IP_RANGE:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_IP_RANGE"
    [ -n "${METALLB_POOL_NAME:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_POOL_NAME"

    log "MetalLB planned in metadata: version=${METALLB_VERSION} range=${METALLB_IP_RANGE} pool=${METALLB_POOL_NAME}"
  else
    log "MetalLB install not planned in bundle metadata"
  fi
}

install_metallb_if_requested() {
  validate_metallb_settings_for_bundle

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    log "skipping MetalLB installation in bundle-only mode"
    log "MetalLB intent is recorded only; production-side procedure must install/configure it if approved"
  else
    log "INSTALL_METALLB=0; no MetalLB intent beyond rendered service settings"
  fi
}

wait_for_metallb_ready() {
  _metallb_forbid_live_action "wait for MetalLB readiness"
}

apply_metallb_pool_if_requested() {
  _metallb_forbid_live_action "apply MetalLB IPAddressPool/L2Advertisement"
}

check_loadbalancer_prereqs() {
  log "checking LoadBalancer configuration values without contacting a cluster"

  if [ "${SERVICE_TYPE:-}" != "LoadBalancer" ]; then
    log "SERVICE_TYPE=${SERVICE_TYPE:-ClusterIP}; LoadBalancer prerequisite check not required"
    return 0
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    validate_metallb_settings_for_bundle
    log "LoadBalancer service requested; MetalLB intent recorded in bundle metadata"
    return 0
  fi

  if [ -n "${LOADBALANCER_IP:-}" ]; then
    log "LoadBalancer service requested with configured LOADBALANCER_IP=${LOADBALANCER_IP}"
    return 0
  fi

  warn "SERVICE_TYPE=LoadBalancer selected without INSTALL_METALLB=1 or LOADBALANCER_IP"
  warn "bundle will still be created; production-side procedure must provide a LoadBalancer implementation"
}

ensure_metallb_namespace() {
  _metallb_forbid_live_action "create/check MetalLB namespace"
}

apply_metallb_manifest() {
  _metallb_forbid_live_action "apply MetalLB upstream manifest"
}

apply_metallb_config() {
  _metallb_forbid_live_action "apply MetalLB config"
}

print_metallb_diagnostics() {
  log "skipping MetalLB diagnostics in bundle-only mode"
}
