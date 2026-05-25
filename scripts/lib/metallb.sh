#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

install_metallb_if_requested() {
  if [ "${INSTALL_METALLB:-0}" != "1" ]; then
    log "INSTALL_METALLB=${INSTALL_METALLB:-0}; skipping MetalLB install/configuration"
    return 0
  fi

  [ -n "${METALLB_VERSION:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_VERSION to be set."
  [ -n "${METALLB_MANIFEST_URL:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_MANIFEST_URL to be set."
  [ -n "${METALLB_POOL_NAME:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_POOL_NAME to be set."
  [ -n "${METALLB_IP_RANGE:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_IP_RANGE, for example <first-ip>-<last-ip>."

  # Installing MetalLB is allowed even when the OTP Relay Service remains
  # ClusterIP behind Ingress. Do not force SERVICE_TYPE=LoadBalancer here.
  log "installing/configuring MetalLB $METALLB_VERSION from $METALLB_MANIFEST_URL"
  log "applying MetalLB upstream manifest; this may take a few minutes on a fresh cluster"
  k3s kubectl apply -f "$METALLB_MANIFEST_URL"

  log "waiting for MetalLB namespace and CRDs; timeout approximately 120s"
  for i in $(seq 1 60); do
    if k3s kubectl get namespace metallb-system >/dev/null 2>&1 \
      && k3s kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1 \
      && k3s kubectl get crd l2advertisements.metallb.io >/dev/null 2>&1; then
      log "MetalLB namespace and CRDs are present"
      break
    fi

    if [ $((i % 15)) -eq 0 ]; then
      log "still waiting for MetalLB namespace/CRDs after $((i * 2))s"
      k3s kubectl get namespace metallb-system 2>/dev/null || true
      k3s kubectl get crd ipaddresspools.metallb.io l2advertisements.metallb.io 2>/dev/null || true
    fi

    sleep 2
    [ "$i" -lt 60 ] || fatal "MetalLB CRDs were not ready after install"
  done

  log "waiting for MetalLB IPAddressPool CRD to be Established"
  k3s kubectl wait --for=condition=Established crd/ipaddresspools.metallb.io --timeout=120s
  log "MetalLB IPAddressPool CRD is Established"

  log "waiting for MetalLB L2Advertisement CRD to be Established"
  k3s kubectl wait --for=condition=Established crd/l2advertisements.metallb.io --timeout=120s
  log "MetalLB L2Advertisement CRD is Established"

  log "waiting for MetalLB controller rollout; this may take a few minutes"
  k3s kubectl rollout status deployment/controller -n metallb-system --timeout=180s
  log "MetalLB controller rollout completed"

  log "waiting for MetalLB speaker rollout; this may take a few minutes"
  k3s kubectl rollout status daemonset/speaker -n metallb-system --timeout=180s
  log "MetalLB speaker rollout completed"

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

  log "MetalLB address pool configured"
}

check_loadbalancer_prereqs() {
  [ "${SERVICE_TYPE:-}" = "LoadBalancer" ] || {
    log "SERVICE_TYPE=${SERVICE_TYPE:-unset}; skipping LoadBalancer prerequisite checks"
    return 0
  }

  log "SERVICE_TYPE=LoadBalancer selected"
  if [ -n "${LOADBALANCER_IP:-}" ]; then
    log "requested LoadBalancer IP: $LOADBALANCER_IP"
  else
    warn "LOADBALANCER_IP is not set. The cluster load balancer must allocate an address automatically."
  fi

  if [ "${INSTALL_METALLB:-0}" = "1" ]; then
    log "INSTALL_METALLB=1 set; MetalLB install/configuration handled by installer"
    return 0
  fi

  log "checking for existing MetalLB namespace"
  if k3s kubectl get namespace metallb-system >/dev/null 2>&1; then
    log "MetalLB namespace found"
    k3s kubectl get pods -n metallb-system --no-headers 2>/dev/null || true
  elif [ "${REQUIRE_METALLB:-0}" = "1" ]; then
    fatal "SERVICE_TYPE=LoadBalancer requires MetalLB, but namespace metallb-system was not found and INSTALL_METALLB is not enabled."
  else
    warn "MetalLB namespace was not found. LoadBalancer service may stay pending unless another load balancer is installed."
  fi
}
