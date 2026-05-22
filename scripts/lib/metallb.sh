#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

install_metallb_if_requested() {
  [ "${INSTALL_METALLB:-0}" = "1" ] || return 0
  [ -n "${METALLB_IP_RANGE:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_IP_RANGE, for example <first-ip>-<last-ip>"

  # Installing MetalLB is allowed even when the OTP Relay Service remains
  # ClusterIP behind Ingress. Do not force SERVICE_TYPE=LoadBalancer here.
  log "installing/configuring MetalLB $METALLB_VERSION from $METALLB_MANIFEST_URL"
  k3s kubectl apply -f "$METALLB_MANIFEST_URL"

  log "waiting for MetalLB namespace and CRDs"
  for i in $(seq 1 60); do
    if k3s kubectl get namespace metallb-system >/dev/null 2>&1 \
      && k3s kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1 \
      && k3s kubectl get crd l2advertisements.metallb.io >/dev/null 2>&1; then
      break
    fi
    sleep 2
    [ "$i" -lt 60 ] || fatal "MetalLB CRDs were not ready after install"
  done

  k3s kubectl wait --for=condition=Established crd/ipaddresspools.metallb.io --timeout=120s
  k3s kubectl wait --for=condition=Established crd/l2advertisements.metallb.io --timeout=120s

  log "waiting for MetalLB controller and speaker"
  k3s kubectl rollout status deployment/controller -n metallb-system --timeout=180s
  k3s kubectl rollout status daemonset/speaker -n metallb-system --timeout=180s

  log "configuring MetalLB L2 address pool $METALLB_POOL_NAME=$METALLB_IP_RANGE"
  cat <<EOF_METALLB | k3s kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $METALLB_POOL_NAME
  namespace: metallb-system
spec:
  addresses:
    - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${METALLB_POOL_NAME}-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - $METALLB_POOL_NAME
EOF_METALLB
}

check_loadbalancer_prereqs() {
  [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] || return 0

  log "SERVICE_TYPE=LoadBalancer selected"
  if [ -n "${LOADBALANCER_IP:-}" ]; then
    log "requested LoadBalancer IP: $LOADBALANCER_IP"
  else
    warn "LOADBALANCER_IP is not set. The cluster load balancer must allocate an address automatically."
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    log "INSTALL_METALLB=1 set; MetalLB will be installed/configured by the installer"
    return 0
  fi

  if k3s kubectl get namespace metallb-system >/dev/null 2>&1; then
    log "MetalLB namespace found"
    k3s kubectl get pods -n metallb-system --no-headers 2>/dev/null || true
  elif [ "${REQUIRE_METALLB:-0}" = "1" ]; then
    fatal "SERVICE_TYPE=LoadBalancer requires MetalLB, but namespace metallb-system was not found and INSTALL_METALLB is not enabled"
  else
    warn "MetalLB namespace was not found. LoadBalancer service may stay pending unless another load balancer is installed."
  fi
}
