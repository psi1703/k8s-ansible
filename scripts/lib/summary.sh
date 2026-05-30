#!/usr/bin/env bash
# Final cleanliness check and deployment summary.

check_working_tree_cleanliness() {
  log "checking deployment working tree cleanliness"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty_status="$(git status --porcelain)"
    if [ -n "$dirty_status" ]; then
      warn "deployment working tree has uncommitted/generated files:"
      printf '%s\n' "$dirty_status" >&2
      warn "tracked modifications should now be unexpected; generated/frontend/server-local files should be covered by .gitignore"
    else
      log "deployment working tree is clean"
    fi
  fi
}

print_deployment_summary() {
  NODEPORT_SUMMARY="disabled"
  if [ "${SERVICE_TYPE:-}" = "NodePort" ]; then
    NODEPORT_SUMMARY="http://${SERVER_IP:-127.0.0.1}:${SERVICE_NODE_PORT:-30080}/"
  fi

  TLS_READYZ_COMMAND="# TLS is disabled or TLS_HOST is not configured."
  if [ "${TLS_ENABLED:-0}" = "1" ] && [ -n "${TLS_HOST:-}" ]; then
    TLS_READYZ_COMMAND="curl -k --resolve ${TLS_HOST}:443:<TRAEFIK_LB_IP> https://${TLS_HOST}/readyz"
  fi

  GRAFANA_URL_SUMMARY="disabled"
  if [ "${OBSERVABILITY_INSTALL_STACK:-1}" = "1" ]; then
    GRAFANA_URL_SUMMARY="https://${GRAFANA_HOST:-grafana-test.lan}/"
  fi

  cat <<EOF_DONE

OTP Relay Kubernetes deployment complete.

Portal URL:   ${PORTAL_URL:-not-set}/
Guide pop-out: opened from the portal as /guide.html?step=<step>&page=<page>
Grafana URL:  $GRAFANA_URL_SUMMARY
NodePort URL: $NODEPORT_SUMMARY
Service type: ${SERVICE_TYPE:-not-set}
LoadBalancer: ${ASSIGNED_LOADBALANCER_ADDRESS:-${LOADBALANCER_IP:-auto/none}}
Ingress:      enabled=${INGRESS_ENABLED:-0} tls=${TLS_ENABLED:-0} host=${TLS_HOST:-none} secret=${TLS_SECRET_NAME:-none} self_signed=${TLS_SELF_SIGNED:-0}
MetalLB:      install=${INSTALL_METALLB:-0} range=${METALLB_IP_RANGE:-none}
Namespace:    ${NAMESPACE:-otp-relay}
Repo path:    ${INSTALL_DIR:-unknown}
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
NFS app storage:       enabled=${NFS_ENABLED:-0} server=${NFS_SERVER:-none} path=${NFS_PATH:-none} class=${NFS_STORAGE_CLASS:-nfs-client} pv=${NFS_PV_NAME:-otp-relay-nfs-pv}
Redis:                 enabled=${REDIS_ENABLED:-0} required=${REDIS_REQUIRED:-0} url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/${REDIS_SIZE:-unknown} spread_recreate_pvcs=${REDIS_SPREAD_RECREATE_PVCS:-0}
Image distribution:    enabled=${DISTRIBUTE_IMAGES_TO_NODES:-0} importer=${IMAGE_IMPORTER_IMAGE:-none} port=${IMAGE_DISTRIBUTION_PORT:-none}
Observability:         namespace=${OBSERVABILITY_NAMESPACE:-observability} install_stack=${OBSERVABILITY_INSTALL_STACK:-1} grafana_host=${GRAFANA_HOST:-grafana-test.lan} chart=${OBSERVABILITY_STACK_CHART_VERSION:-85.0.1}

Useful commands:
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl get pods -n ${NAMESPACE:-otp-relay}
  k3s kubectl logs -n ${NAMESPACE:-otp-relay} deployment/otp-relay
  k3s kubectl logs -n ${NAMESPACE:-otp-relay} deployment/otp-monitor
  k3s kubectl get svc,ingress -n ${NAMESPACE:-otp-relay}
  k3s kubectl get pods -n ${NAMESPACE:-otp-relay} -l app=otp-redis -o wide
  k3s kubectl get pods -n ${NAMESPACE:-otp-relay} -l app=otp-redis-sentinel -o wide
  k3s kubectl get pods -n ${NAMESPACE:-otp-relay} -l app=otp-redis-haproxy -o wide
  k3s kubectl get pods,svc,ingressroute,servicemonitor -n ${OBSERVABILITY_NAMESPACE:-observability}
  k3s kubectl get secret kube-prometheus-stack-grafana -n ${OBSERVABILITY_NAMESPACE:-observability} -o jsonpath='{.data.admin-password}' | base64 -d; echo
  k3s kubectl -n kube-system get svc traefik -o wide
  $TLS_READYZ_COMMAND
  curl -i http://127.0.0.1/
  # If SERVICE_TYPE=NodePort:
  # curl -i http://127.0.0.1:${SERVICE_NODE_PORT:-30080}/

Monitor config is in ConfigMap otp-relay-config:
  PHONE_IP=${PHONE_IP:-not-set}
  PHONE_INTERFACE=${PHONE_INTERFACE:-not-set}
  PHONE_PING_INTERVAL=${PHONE_PING_INTERVAL:-not-set}
  PHONE_OFFLINE_THRESHOLD=${PHONE_OFFLINE_THRESHOLD:-not-set}
  PORTAL_URL=${PORTAL_URL:-not-set}

SMS webhook secret token was generated/stored in Kubernetes secret otp-relay-secrets.
To print it on this server:
  k3s kubectl get secret otp-relay-secrets -n ${NAMESPACE:-otp-relay} -o jsonpath='{.data.SMS_SECRET_TOKEN}' | base64 -d; echo
EOF_DONE
}
