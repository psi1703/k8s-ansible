#!/usr/bin/env bash
# Final cleanliness check and deployment summary.

check_working_tree_cleanliness() {
log "checking deployment working tree cleanliness"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty_status="$(git status --porcelain)"
  if [ -n "$dirty_status" ]; then
    warn "deployment working tree has uncommitted/generated files:"
    printf '%s\n' "$dirty_status" >&2
    warn "tracked modifications should now be unexpected; generated frontend files should be covered by .gitignore"
  else
    log "deployment working tree is clean"
  fi
fi

}

print_deployment_summary() {
NODEPORT_SUMMARY="disabled"
if [ "$SERVICE_TYPE" = "NodePort" ]; then
  NODEPORT_SUMMARY="http://$SERVER_IP:$SERVICE_NODE_PORT/"
fi

cat <<EOF_DONE

OTP Relay Kubernetes deployment complete.

Portal URL:   $PORTAL_URL/
NodePort URL: $NODEPORT_SUMMARY
Service type: $SERVICE_TYPE
LoadBalancer: ${ASSIGNED_LOADBALANCER_ADDRESS:-${LOADBALANCER_IP:-auto/none}}
Ingress:      enabled=$INGRESS_ENABLED tls=$TLS_ENABLED host=${TLS_HOST:-none} secret=${TLS_SECRET_NAME:-none} self_signed=$TLS_SELF_SIGNED
MetalLB:      install=$INSTALL_METALLB range=${METALLB_IP_RANGE:-none}
Namespace:    $NAMESPACE
Repo path:    $INSTALL_DIR
OS/arch:      $OS_NAME / $ARCH_RAW
Monitor:      installed as required component
Runner:       $INSTALL_GITHUB_RUNNER
Runner only:  $RUNNER_ONLY
Deploy mode:  $DEPLOY_MODE
App replicas:          $REPLICA_COUNT
App rollout strategy:  RollingUpdate maxUnavailable=0 maxSurge=1
App node selector:     ${APP_NODE_SELECTOR_KEY:-none}=${APP_NODE_SELECTOR_VALUE:-}
Monitor node selector: ${MONITOR_NODE_SELECTOR_KEY:-none}=${MONITOR_NODE_SELECTOR_VALUE:-}
Redis node selector:   ${REDIS_NODE_SELECTOR_KEY:-none}=${REDIS_NODE_SELECTOR_VALUE:-}
PVC storage:           ${PVC_STORAGE_CLASS:-default} / $PVC_SIZE
NFS app storage:       enabled=$NFS_ENABLED server=${NFS_SERVER:-none} path=${NFS_PATH:-none} class=$NFS_STORAGE_CLASS pv=$NFS_PV_NAME
Redis:                 enabled=$REDIS_ENABLED required=$REDIS_REQUIRED url=${REDIS_URL:-none} storage=${REDIS_STORAGE_CLASS:-default}/$REDIS_SIZE spread_recreate_pvcs=$REDIS_SPREAD_RECREATE_PVCS
Image distribution:    enabled=$DISTRIBUTE_IMAGES_TO_NODES importer=$IMAGE_IMPORTER_IMAGE port=$IMAGE_DISTRIBUTION_PORT
Observability YAMLs:   applied from k8s/observability when present

Useful commands:
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl get pods -n $NAMESPACE
  k3s kubectl logs -n $NAMESPACE deployment/otp-relay
  k3s kubectl logs -n $NAMESPACE deployment/otp-monitor
  k3s kubectl get svc,ingress -n $NAMESPACE
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis -o wide
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis-sentinel -o wide
  k3s kubectl get pods -n $NAMESPACE -l app=otp-redis-haproxy -o wide
  k3s kubectl -n kube-system get svc traefik -o wide
  curl -k --resolve ${TLS_HOST}:443:<TRAEFIK_LB_IP> https://${TLS_HOST}/readyz
  curl -i http://127.0.0.1/
  # If SERVICE_TYPE=NodePort:
  # curl -i http://127.0.0.1:$SERVICE_NODE_PORT/

Monitor config is in ConfigMap otp-relay-config:
  PHONE_IP=$PHONE_IP
  PHONE_INTERFACE=$PHONE_INTERFACE
  PHONE_PING_INTERVAL=$PHONE_PING_INTERVAL
  PHONE_OFFLINE_THRESHOLD=$PHONE_OFFLINE_THRESHOLD
  PORTAL_URL=$PORTAL_URL

SMS webhook secret token was generated/stored in Kubernetes secret otp-relay-secrets.
To print it on this server:
  k3s kubectl get secret otp-relay-secrets -n $NAMESPACE -o jsonpath='{.data.SMS_SECRET_TOKEN}' | base64 -d; echo
EOF_DONE

}
