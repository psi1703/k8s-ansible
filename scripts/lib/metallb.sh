#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

_ipv4_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<EOF_IP
$ip
EOF_IP
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
  printf '%s\n' $((a * 16777216 + b * 65536 + c * 256 + d))
}

_int_to_ipv4() {
  local n="$1"
  printf '%s.%s.%s.%s\n' \
    $(((n >> 24) & 255)) \
    $(((n >> 16) & 255)) \
    $(((n >> 8) & 255)) \
    $((n & 255))
}

_validate_ipv4() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<EOF_IP
$ip
EOF_IP
  for part in "$a" "$b" "$c" "$d"; do
    case "$part" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}

_metallb_reserved_ip() {
  local ip="$1"
  local reserved

  for reserved in \
    "${SERVER_IP:-}" \
    "${HOST_IP:-}" \
    "${GATEWAY:-}" \
    "${NFS_SERVER:-}" \
    "${PHONE_IP:-}" \
    "${WORKER1_IP:-}" \
    "${WORKER2_IP:-}" \
    ${RESERVED_IPS:-}; do
    [ -n "$reserved" ] || continue
    reserved="${reserved%%/*}"
    [ "$ip" = "$reserved" ] && return 0
  done

  if ip -4 addr show 2>/dev/null | awk '{print $2}' | cut -d/ -f1 | grep -Fxq "$ip"; then
    return 0
  fi

  return 1
}

_detect_lan_probe_interface() {
  local probe_ip="$1"
  local iface

  if [ -n "${METALLB_PROBE_INTERFACE:-}" ]; then
    printf '%s\n' "$METALLB_PROBE_INTERFACE"
    return 0
  fi

  if [ -n "${BRIDGE_NAME:-}" ] && ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    printf '%s\n' "$BRIDGE_NAME"
    return 0
  fi

  iface="$(ip route get "$probe_ip" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [ -n "$iface" ] || iface="$(ip route | awk '/^default / {print $5; exit}')"
  [ -n "$iface" ] || return 1
  printf '%s\n' "$iface"
}

_check_metallb_ip_free() {
  local ip="$1"
  local iface="$2"
  local previous_neigh after_neigh

  _validate_ipv4 "$ip" || {
    warn "MetalLB candidate IP is not a valid IPv4 address: $ip"
    return 1
  }

  if _metallb_reserved_ip "$ip"; then
    warn "MetalLB candidate IP is reserved or already assigned locally; skipping: $ip"
    return 1
  fi

  if k3s kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.loadBalancerIP} {.status.loadBalancer.ingress[*].ip}{"\n"}{end}' 2>/dev/null | awk -v ip="$ip" '$0 ~ ip {found=1} END {exit found ? 0 : 1}'; then
    warn "MetalLB candidate IP is already referenced by an existing Kubernetes LoadBalancer service; skipping: $ip"
    return 1
  fi

  previous_neigh="$(ip neigh show "$ip" dev "$iface" 2>/dev/null || true)"
  if printf '%s\n' "$previous_neigh" | grep -qE 'lladdr|REACHABLE|STALE|DELAY|PROBE|PERMANENT'; then
    warn "MetalLB candidate IP already has a neighbor/ARP entry on $iface; skipping: $ip"
    warn "$previous_neigh"
    return 1
  fi

  ip neigh flush "$ip" dev "$iface" >/dev/null 2>&1 || true

  if ping -c 1 -W 1 -I "$iface" "$ip" >/dev/null 2>&1; then
    after_neigh="$(ip neigh show "$ip" dev "$iface" 2>/dev/null || true)"
    warn "MetalLB candidate IP answers ping before assignment; skipping: $ip"
    [ -z "$after_neigh" ] || warn "$after_neigh"
    return 1
  fi

  after_neigh="$(ip neigh show "$ip" dev "$iface" 2>/dev/null || true)"
  if printf '%s\n' "$after_neigh" | grep -qE 'lladdr|REACHABLE|STALE|DELAY|PROBE|PERMANENT'; then
    warn "MetalLB candidate IP produced a neighbor/ARP owner before assignment; skipping: $ip"
    warn "$after_neigh"
    return 1
  fi

  return 0
}

_select_free_metallb_ip() {
  local range="$1"
  local first last first_int last_int current ip iface

  case "$range" in
    *-*)
      first="${range%-*}"
      last="${range#*-}"
      ;;
    *)
      first="$range"
      last="$range"
      ;;
  esac

  _validate_ipv4 "$first" || fatal "METALLB_IP_RANGE starts with invalid IPv4 address: $first"
  _validate_ipv4 "$last" || fatal "METALLB_IP_RANGE ends with invalid IPv4 address: $last"

  first_int="$(_ipv4_to_int "$first")"
  last_int="$(_ipv4_to_int "$last")"
  [ "$first_int" -le "$last_int" ] || fatal "METALLB_IP_RANGE is invalid; first IP is greater than last IP: $range"

  iface="$(_detect_lan_probe_interface "$first")" || fatal "Could not detect LAN interface for MetalLB IP probing. Set METALLB_PROBE_INTERFACE or BRIDGE_NAME."
  log "probing MetalLB range $range on interface $iface"

  current="$first_int"
  while [ "$current" -le "$last_int" ]; do
    ip="$(_int_to_ipv4 "$current")"
    log "checking MetalLB candidate IP: $ip"
    if _check_metallb_ip_free "$ip" "$iface"; then
      printf '%s\n' "$ip"
      return 0
    fi
    current=$((current + 1))
  done

  fatal "No free MetalLB IP found in range $range. Check for LAN conflicts or expand METALLB_IP_RANGE."
}

resolve_loadbalancer_ip() {
  [ "${INSTALL_METALLB:-0}" = "1" ] || return 0
  [ -n "${METALLB_IP_RANGE:-}" ] || return 0

  if [ -n "${LOADBALANCER_IP:-}" ]; then
    local iface
    iface="$(_detect_lan_probe_interface "$LOADBALANCER_IP")" || fatal "Could not detect LAN interface for requested LOADBALANCER_IP=$LOADBALANCER_IP"
    log "validating requested LoadBalancer IP $LOADBALANCER_IP on $iface"
    _check_metallb_ip_free "$LOADBALANCER_IP" "$iface" || fatal "Requested LOADBALANCER_IP=$LOADBALANCER_IP appears occupied or unsafe. Choose another IP or leave LOADBALANCER_IP empty for auto-selection."
    export LOADBALANCER_IP
    export ASSIGNED_LOADBALANCER_ADDRESS="$LOADBALANCER_IP"
    return 0
  fi

  LOADBALANCER_IP="$(_select_free_metallb_ip "$METALLB_IP_RANGE")"
  ASSIGNED_LOADBALANCER_ADDRESS="$LOADBALANCER_IP"
  export LOADBALANCER_IP ASSIGNED_LOADBALANCER_ADDRESS
  log "selected free MetalLB LoadBalancer IP: $LOADBALANCER_IP"
}

patch_traefik_loadbalancer_ip() {
  [ "${INGRESS_ENABLED:-0}" = "1" ] || return 0
  [ -n "${LOADBALANCER_IP:-}" ] || return 0

  if ! k3s kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    warn "Traefik service kube-system/traefik was not found; cannot set Traefik loadBalancerIP yet"
    return 0
  fi

  log "setting Traefik LoadBalancer IP to $LOADBALANCER_IP"
  k3s kubectl -n kube-system patch svc traefik --type=merge -p "{\"spec\":{\"loadBalancerIP\":\"$LOADBALANCER_IP\"}}"

  log "waiting for Traefik LoadBalancer IP $LOADBALANCER_IP"
  for i in $(seq 1 60); do
    assigned="$(k3s kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ "$assigned" = "$LOADBALANCER_IP" ]; then
      ok "Traefik LoadBalancer IP assigned: $assigned"
      return 0
    fi
    if [ $((i % 10)) -eq 0 ]; then
      log "still waiting for Traefik LoadBalancer IP after $((i * 2))s; current=${assigned:-none}"
      k3s kubectl -n kube-system get svc traefik -o wide || true
    fi
    sleep 2
  done

  fatal "Traefik did not receive requested LoadBalancer IP $LOADBALANCER_IP"
}

install_metallb_if_requested() {
  if [ "${INSTALL_METALLB:-0}" != "1" ]; then
    log "INSTALL_METALLB=${INSTALL_METALLB:-0}; skipping MetalLB install/configuration"
    return 0
  fi

  [ -n "${METALLB_VERSION:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_VERSION to be set."
  [ -n "${METALLB_MANIFEST_URL:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_MANIFEST_URL to be set."
  [ -n "${METALLB_POOL_NAME:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_POOL_NAME to be set."
  [ -n "${METALLB_IP_RANGE:-}" ] || fatal "INSTALL_METALLB=1 requires METALLB_IP_RANGE, for example <first-ip>-<last-ip>."

  # Pick a clean LAN IP before applying the pool so the first pool address is not
  # accepted blindly when it is already owned by another device.
  resolve_loadbalancer_ip

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

  patch_traefik_loadbalancer_ip
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
