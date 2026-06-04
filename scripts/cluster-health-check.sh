#!/usr/bin/env bash
set +e
set -o pipefail

LOG="${1:-/tmp/k8s-ansible-health-check-$(date +%Y%m%d-%H%M%S).log}"
REPO="${REPO:-/opt/k8s-ansible}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-85.0.1}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.8.1}"

NAMESPACE="${NAMESPACE:-otp-relay}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
KPS_RELEASE="${KPS_RELEASE:-kube-prometheus-stack}"
LOKI_RELEASE="${LOKI_RELEASE:-loki}"
ALLOY_RELEASE="${ALLOY_RELEASE:-alloy}"
LOKI_SERVICE="${LOKI_SERVICE:-loki}"
LOKI_PORT="${LOKI_PORT:-3100}"
# Some Loki chart versions expose a gateway instead of service/loki.
# Keep service/loki as the preferred SCH target, but auto-detect a usable fallback
# so the health check reports the real live state instead of only one assumed name.
LOKI_GATEWAY_SERVICE="${LOKI_GATEWAY_SERVICE:-loki-gateway}"

APP_LABEL_SELECTOR="${APP_LABEL_SELECTOR:-app=otp-relay}"
MONITOR_LABEL_SELECTOR="${MONITOR_LABEL_SELECTOR:-app=otp-monitor}"
REDIS_LABEL_SELECTOR="${REDIS_LABEL_SELECTOR:-app=otp-redis}"
SENTINEL_LABEL_SELECTOR="${SENTINEL_LABEL_SELECTOR:-app=otp-redis-sentinel}"
HAPROXY_LABEL_SELECTOR="${HAPROXY_LABEL_SELECTOR:-app=otp-redis-haproxy}"

APP_DEPLOYMENT="${APP_DEPLOYMENT:-otp-relay}"
MONITOR_DEPLOYMENT="${MONITOR_DEPLOYMENT:-otp-monitor}"
REDIS_STATEFULSET="${REDIS_STATEFULSET:-otp-redis}"
SENTINEL_DEPLOYMENT="${SENTINEL_DEPLOYMENT:-otp-redis-sentinel}"
HAPROXY_DEPLOYMENT="${HAPROXY_DEPLOYMENT:-otp-redis-haproxy}"

PORTAL_SERVICE="${PORTAL_SERVICE:-otp-relay}"
PORTAL_READYZ_PATH="${PORTAL_READYZ_PATH:-/readyz}"
PORTAL_INSECURE_TLS="${PORTAL_INSECURE_TLS:-1}"

REDIS_SERVICE="${REDIS_SERVICE:-otp-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
SENTINEL_SERVICE="${SENTINEL_SERVICE:-otp-redis-sentinel}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
SENTINEL_MASTER_NAME="${SENTINEL_MASTER_NAME:-mymaster}"
HAPROXY_SERVICE="${HAPROXY_SERVICE:-otp-redis-haproxy}"
HAPROXY_PORT="${HAPROXY_PORT:-6379}"

PROBLEMS=()
WARNINGS=()

mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

section() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "================================================================================"
}

run() {
  echo
  echo "+ $*"
  "$@"
  local rc=$?
  echo "[rc=$rc]"
  return "$rc"
}

run_sh() {
  echo
  echo "+ $*"
  bash -lc "$*"
  local rc=$?
  echo "[rc=$rc]"
  return "$rc"
}

problem() {
  PROBLEMS+=("$1")
  echo "PROBLEM: $1"
}

warning() {
  WARNINGS+=("$1")
  echo "WARNING: $1"
}

jsonpath() {
  kubectl "$@" 2>/dev/null || true
}

first_pod() {
  local ns="$1"
  local selector="$2"
  kubectl -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

check_deployment_ready() {
  local ns="$1"
  local name="$2"
  local label="$3"

  if ! kubectl -n "$ns" get deployment "$name" >/dev/null 2>&1; then
    problem "$label deployment missing: $ns/$name"
    return
  fi

  local desired ready available
  desired="$(kubectl -n "$ns" get deployment "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  ready="$(kubectl -n "$ns" get deployment "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  available="$(kubectl -n "$ns" get deployment "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  desired="${desired:-0}"
  ready="${ready:-0}"
  available="${available:-0}"

  if [ "$desired" != "$ready" ] || [ "$desired" != "$available" ]; then
    problem "$label deployment not ready: desired=$desired ready=$ready available=$available"
  else
    echo "OK: $label deployment ready: desired=$desired ready=$ready available=$available"
  fi
}

check_statefulset_ready() {
  local ns="$1"
  local name="$2"
  local label="$3"

  if ! kubectl -n "$ns" get statefulset "$name" >/dev/null 2>&1; then
    problem "$label StatefulSet missing: $ns/$name"
    return
  fi

  local desired ready
  desired="$(kubectl -n "$ns" get statefulset "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  ready="$(kubectl -n "$ns" get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="${desired:-0}"
  ready="${ready:-0}"

  if [ "$desired" != "$ready" ]; then
    problem "$label StatefulSet not ready: desired=$desired ready=$ready"
  else
    echo "OK: $label StatefulSet ready: desired=$desired ready=$ready"
  fi
}

check_daemonset_ready() {
  local ns="$1"
  local name="$2"
  local label="$3"

  if ! kubectl -n "$ns" get daemonset "$name" >/dev/null 2>&1; then
    problem "$label DaemonSet missing: $ns/$name"
    return
  fi

  local desired ready available
  desired="$(kubectl -n "$ns" get daemonset "$name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  ready="$(kubectl -n "$ns" get daemonset "$name" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  available="$(kubectl -n "$ns" get daemonset "$name" -o jsonpath='{.status.numberAvailable}' 2>/dev/null || echo 0)"
  desired="${desired:-0}"
  ready="${ready:-0}"
  available="${available:-0}"

  if [ "$desired" = "0" ]; then
    problem "$label DaemonSet has zero desired pods: $ns/$name"
  elif [ "$desired" != "$ready" ] || [ "$desired" != "$available" ]; then
    problem "$label DaemonSet not ready: desired=$desired ready=$ready available=$available"
  else
    echo "OK: $label DaemonSet ready: desired=$desired ready=$ready available=$available"
  fi
}

check_service_endpoints() {
  local ns="$1"
  local svc="$2"
  local label="$3"

  if ! kubectl -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    problem "$label service missing: $ns/$svc"
    return
  fi

  local endpoints
  endpoints="$(kubectl -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"

  if [ -z "$endpoints" ]; then
    problem "$label service has no ready endpoints: $ns/$svc"
  else
    echo "OK: $label service endpoints: $endpoints"
  fi
}

detect_loki_service() {
  local ns="$1"

  if kubectl -n "$ns" get svc "$LOKI_SERVICE" >/dev/null 2>&1; then
    printf '%s\n' "$LOKI_SERVICE"
    return 0
  fi

  if kubectl -n "$ns" get svc "$LOKI_GATEWAY_SERVICE" >/dev/null 2>&1; then
    printf '%s\n' "$LOKI_GATEWAY_SERVICE"
    return 0
  fi

  # Fall back to the first non-memberlist Loki service if the chart produced
  # version-specific service names.
  kubectl -n "$ns" get svc -l app.kubernetes.io/instance="$LOKI_RELEASE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -Ev 'memberlist$' \
    | head -1
}

check_loki_workload_present() {
  local ns="$1"
  local count

  count="$(kubectl -n "$ns" get pod -l app.kubernetes.io/instance="$LOKI_RELEASE" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}x{end}' 2>/dev/null | wc -c | xargs)"

  if [ "${count:-0}" = "0" ]; then
    problem "Loki Helm release exists but no running Loki pods were found for app.kubernetes.io/instance=$LOKI_RELEASE"
  else
    echo "OK: Loki running pod marker count: $count"
  fi
}

section "Health check metadata"
echo "Started: $(date -Is)"
echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "User: $(id)"
echo "Repo: $REPO"
echo "Log: $LOG"
echo "KUBECONFIG_PATH: $KUBECONFIG_PATH"
echo "Namespace: $NAMESPACE"
echo "Observability namespace: $OBSERVABILITY_NAMESPACE"

section "Repository presence"
if [ -d "$REPO" ]; then
  cd "$REPO" || exit 1
  run pwd
  run ls -lah
else
  problem "repo directory does not exist: $REPO"
fi

section "Core tool versions"
run_sh "command -v kubectl && kubectl version --client=true"
run_sh "command -v k3s && k3s --version"
run_sh "command -v helm && helm version --short || true"
run_sh "command -v docker && docker --version || true"
run_sh "command -v ansible && ansible --version | head -5 || true"
run_sh "command -v python3 && python3 --version"
run_sh "command -v node && node --version || true"
run_sh "command -v npm && npm --version || true"

section "Kubernetes access"
if ! kubectl get --raw=/readyz >/dev/null 2>&1; then
  problem "Kubernetes API /readyz failed"
else
  echo "OK: Kubernetes API /readyz passed"
fi
run kubectl cluster-info
run kubectl get nodes -o wide
run kubectl get nodes -L observability/role,otp-relay/app-node,otp-relay/redis-node,otp-relay/storage-node,otp-relay/monitor-node

section "Helm access"
run_sh "helm -n $OBSERVABILITY_NAMESPACE list -a || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm -n $OBSERVABILITY_NAMESPACE list -a || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm -n $OBSERVABILITY_NAMESPACE status $KPS_RELEASE || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm -n $OBSERVABILITY_NAMESPACE status $LOKI_RELEASE || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm -n $OBSERVABILITY_NAMESPACE status $ALLOY_RELEASE || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo list || true"

if ! sudo KUBECONFIG="$KUBECONFIG_PATH" helm -n "$OBSERVABILITY_NAMESPACE" status "$KPS_RELEASE" >/dev/null 2>&1; then
  problem "Helm release missing or unhealthy: $OBSERVABILITY_NAMESPACE/$KPS_RELEASE"
fi

if [ -f "$REPO/k8s/observability/loki-values.yaml" ]; then
  if ! sudo KUBECONFIG="$KUBECONFIG_PATH" helm -n "$OBSERVABILITY_NAMESPACE" status "$LOKI_RELEASE" >/dev/null 2>&1; then
    problem "Helm release missing or unhealthy: $OBSERVABILITY_NAMESPACE/$LOKI_RELEASE"
  fi
fi

if [ -f "$REPO/k8s/observability/alloy-values.yaml" ]; then
  if ! sudo KUBECONFIG="$KUBECONFIG_PATH" helm -n "$OBSERVABILITY_NAMESPACE" status "$ALLOY_RELEASE" >/dev/null 2>&1; then
    problem "Helm release missing or unhealthy: $OBSERVABILITY_NAMESPACE/$ALLOY_RELEASE"
  fi
fi

section "Namespaces"
run kubectl get ns
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || problem "namespace missing: $NAMESPACE"
kubectl get ns "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1 || warning "observability namespace missing: $OBSERVABILITY_NAMESPACE"

section "OTP Relay workload readiness"
run kubectl -n "$NAMESPACE" get pods -o wide
run kubectl -n "$NAMESPACE" get svc -o wide
run kubectl -n "$NAMESPACE" get ingress -o wide
run_sh "kubectl -n '$NAMESPACE' get ingressroute 2>/dev/null || true"
run_sh "kubectl -n '$NAMESPACE' get deploy,statefulset,daemonset,cm,secret,pvc,pv 2>/dev/null || true"

check_deployment_ready "$NAMESPACE" "$APP_DEPLOYMENT" "App"
check_deployment_ready "$NAMESPACE" "$MONITOR_DEPLOYMENT" "Monitor"
check_statefulset_ready "$NAMESPACE" "$REDIS_STATEFULSET" "Redis"
check_deployment_ready "$NAMESPACE" "$SENTINEL_DEPLOYMENT" "Redis Sentinel"
check_deployment_ready "$NAMESPACE" "$HAPROXY_DEPLOYMENT" "Redis HAProxy"

check_service_endpoints "$NAMESPACE" "$PORTAL_SERVICE" "Portal"
check_service_endpoints "$NAMESPACE" "$REDIS_SERVICE" "Redis"
check_service_endpoints "$NAMESPACE" "$SENTINEL_SERVICE" "Redis Sentinel"
check_service_endpoints "$NAMESPACE" "$HAPROXY_SERVICE" "Redis HAProxy"

section "Shared PVC / NFS validation"
run kubectl -n "$NAMESPACE" get pvc -o wide
APP_PVC="$(kubectl -n "$NAMESPACE" get pvc otp-relay-data -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ -z "$APP_PVC" ]; then
  problem "app shared PVC missing: otp-relay-data"
else
  APP_PV="$(kubectl -n "$NAMESPACE" get pvc otp-relay-data -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  APP_SC="$(kubectl -n "$NAMESPACE" get pvc otp-relay-data -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  APP_ACCESS="$(kubectl -n "$NAMESPACE" get pvc otp-relay-data -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || true)"
  echo "otp-relay-data PV=$APP_PV storageClass=$APP_SC accessModes=$APP_ACCESS"

  if [ "$APP_SC" != "otp-relay-nfs" ]; then
    problem "otp-relay-data is not using otp-relay-nfs; storageClass=$APP_SC"
  fi

  if ! printf '%s\n' "$APP_ACCESS" | grep -q "ReadWriteMany"; then
    problem "otp-relay-data is not RWX; accessModes=$APP_ACCESS"
  fi

  if [ -n "$APP_PV" ]; then
    run_sh "kubectl get pv '$APP_PV' -o yaml | grep -E 'storageClassName:|accessModes:|nfs:|server:|path:|persistentVolumeReclaimPolicy:' -A4"
    if ! kubectl get pv "$APP_PV" -o yaml 2>/dev/null | grep -q "nfs:"; then
      problem "PV backing otp-relay-data does not show nfs: $APP_PV"
    fi
  fi
fi

section "Runtime shared PVC write/read proof"
PODS=($(kubectl -n "$NAMESPACE" get pods -l "$APP_LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null))
echo "App pods: ${PODS[*]}"
if [ "${#PODS[@]}" -ge 2 ]; then
  TEST_FILE="/app/data/shared-pvc-health-check.txt"
  run_sh "kubectl -n '$NAMESPACE' exec '${PODS[0]}' -- sh -c 'date -Is > $TEST_FILE && hostname >> $TEST_FILE'"
  run_sh "kubectl -n '$NAMESPACE' exec '${PODS[1]}' -- cat '$TEST_FILE'"
else
  warning "less than two app pods found; skipping cross-pod shared PVC proof"
fi

section "Redis / Sentinel / HAProxy functional checks"
REDIS_POD="$(first_pod "$NAMESPACE" "$REDIS_LABEL_SELECTOR")"
SENTINEL_POD="$(first_pod "$NAMESPACE" "$SENTINEL_LABEL_SELECTOR")"
HAPROXY_POD="$(first_pod "$NAMESPACE" "$HAPROXY_LABEL_SELECTOR")"
echo "REDIS_POD=$REDIS_POD"
echo "SENTINEL_POD=$SENTINEL_POD"
echo "HAPROXY_POD=$HAPROXY_POD"

if [ -n "$REDIS_POD" ]; then
  run_sh "kubectl -n '$NAMESPACE' exec '$REDIS_POD' -- redis-cli -p '$REDIS_PORT' ping"
else
  problem "No Redis pod found by selector $REDIS_LABEL_SELECTOR"
fi

if [ -n "$SENTINEL_POD" ]; then
  run_sh "kubectl -n '$NAMESPACE' exec '$SENTINEL_POD' -- redis-cli -p '$SENTINEL_PORT' ping"
  run_sh "kubectl -n '$NAMESPACE' exec '$SENTINEL_POD' -- redis-cli -p '$SENTINEL_PORT' sentinel get-master-addr-by-name '$SENTINEL_MASTER_NAME'"
else
  problem "No Sentinel pod found by selector $SENTINEL_LABEL_SELECTOR"
fi

if [ -n "$HAPROXY_POD" ]; then
  run_sh "kubectl -n '$NAMESPACE' exec '$HAPROXY_POD' -- sh -c 'echo PING | nc -w 3 127.0.0.1 $HAPROXY_PORT || true'"
else
  warning "No HAProxy pod found by selector $HAPROXY_LABEL_SELECTOR"
fi

section "Portal readyz checks"
INTERNAL_READYZ="http://${PORTAL_SERVICE}.${NAMESPACE}.svc.cluster.local${PORTAL_READYZ_PATH}"
run_sh "kubectl -n '$NAMESPACE' run portal-readyz-check --rm -i --restart=Never --image=curlimages/curl:latest -- curl -fsS '$INTERNAL_READYZ' || true"

PORTAL_URL_FROM_CONFIG="$(kubectl -n "$NAMESPACE" get cm otp-relay-config -o jsonpath='{.data.PORTAL_URL}' 2>/dev/null || true)"
echo "PORTAL_URL_FROM_CONFIG=$PORTAL_URL_FROM_CONFIG"
if [ -n "$PORTAL_URL_FROM_CONFIG" ]; then
  CURL_TLS_FLAG=""
  if [ "$PORTAL_INSECURE_TLS" = "1" ]; then
    CURL_TLS_FLAG="-k"
  fi
  run_sh "curl $CURL_TLS_FLAG -sS -m 10 -w '\nHTTP_CODE=%{http_code}\n' '${PORTAL_URL_FROM_CONFIG}${PORTAL_READYZ_PATH}' || true"
fi

section "Frontend static files inside live OTP pod"
OTP_POD="$(first_pod "$NAMESPACE" "$APP_LABEL_SELECTOR")"
echo "OTP_POD=$OTP_POD"
if [ -n "$OTP_POD" ]; then
  run_sh "kubectl -n '$NAMESPACE' exec '$OTP_POD' -- sh -c 'ls -lah /app/frontend && echo ---index--- && grep -n \"script.*app.js\\|guide.html\" /app/frontend/index.html || true && echo ---markers--- && grep -o \"Enter your token\\|Request your OTP\\|RTA Access Wizard\\|Help & Docs\" /app/frontend/app.js | sort -u || true'"
else
  problem "No OTP app pod found for frontend validation"
fi

section "Observability resources"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get pods -o wide 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get svc -o wide 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get daemonset -o wide 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get ingressroute -o wide 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get servicemonitor -o wide 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get prometheus,alertmanager 2>/dev/null || true"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get configmap otp-relay-live-dashboard 2>/dev/null || true"

check_service_endpoints "$OBSERVABILITY_NAMESPACE" "${KPS_RELEASE}-grafana" "Grafana"
check_service_endpoints "$OBSERVABILITY_NAMESPACE" "${KPS_RELEASE}-prometheus" "Prometheus"

if [ -f "$REPO/k8s/observability/loki-values.yaml" ]; then
  check_loki_workload_present "$OBSERVABILITY_NAMESPACE"

  DETECTED_LOKI_SERVICE="$(detect_loki_service "$OBSERVABILITY_NAMESPACE")"
  if [ -n "$DETECTED_LOKI_SERVICE" ]; then
    echo "Detected Loki service for health checks: $DETECTED_LOKI_SERVICE"
    check_service_endpoints "$OBSERVABILITY_NAMESPACE" "$DETECTED_LOKI_SERVICE" "Loki"
  else
    problem "Loki service missing: no usable Loki service found in namespace $OBSERVABILITY_NAMESPACE"
  fi
fi

if [ -f "$REPO/k8s/observability/alloy-values.yaml" ]; then
  check_daemonset_ready "$OBSERVABILITY_NAMESPACE" "$ALLOY_RELEASE" "Alloy"
fi

section "Metrics endpoints from inside cluster"
run_sh "kubectl -n '$NAMESPACE' run curl-metrics-test --rm -i --restart=Never --image=curlimages/curl:latest -- sh -c '
echo --- otp-relay metrics ---
curl -fsS http://otp-relay.otp-relay.svc.cluster.local/metrics | grep -E \"otp_queue_depth|otp_active_user|otp_delivered_total|otp_claims_total\" | head -30 || true
echo --- otp-monitor metrics ---
curl -fsS http://otp-monitor.otp-relay.svc.cluster.local:9101/metrics | grep -E \"otp_iphone_present|otp_monitor_arp_last_success_timestamp_seconds|otp_iphone_absence_events_total\" | head -30 || true
' || true"

section "Loki and Alloy log pipeline checks"
if [ -f "$REPO/k8s/observability/loki-values.yaml" ]; then
  DETECTED_LOKI_SERVICE="$(detect_loki_service "$OBSERVABILITY_NAMESPACE")"

  if [ -z "$DETECTED_LOKI_SERVICE" ]; then
    problem "Skipping Loki API checks because no usable Loki service was detected"
  else
    LOKI_URL="http://${DETECTED_LOKI_SERVICE}.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:${LOKI_PORT}"
    echo "LOKI_URL=$LOKI_URL"

    run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' run loki-api-check --rm -i --restart=Never --image=curlimages/curl:latest -- curl -fsS '$LOKI_URL/ready' || true"

    run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' run loki-labels-check --rm -i --restart=Never --image=curlimages/curl:latest -- curl -fsS '$LOKI_URL/loki/api/v1/labels' | head -40 || true"

    run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' run loki-query-check --rm -i --restart=Never --image=curlimages/curl:latest -- curl -fsS --get '$LOKI_URL/loki/api/v1/query' --data-urlencode 'query={namespace=\"otp-relay\"}' | head -80 || true"
  fi
else
  warning "loki-values.yaml not present; skipping Loki API checks"
fi

if [ -f "$REPO/k8s/observability/alloy-values.yaml" ]; then
  run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' logs daemonset/'$ALLOY_RELEASE' --tail=80 --all-containers=true 2>/dev/null || true"
else
  warning "alloy-values.yaml not present; skipping Alloy log checks"
fi

section "Prometheus targets and dashboard queries"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' run prometheus-api-check --rm -i --restart=Never --image=curlimages/curl:latest -- sh -c '
set -eu
PROM_URL=\"http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090\"

echo --- prometheus ready ---
curl -fsS \"\$PROM_URL/-/ready\"
echo

echo --- target API contains OTP jobs ---
curl -fsS \"\$PROM_URL/api/v1/targets\" \
  | grep -o \"otp-relay\\|otp-monitor\\|health\\\":\\\"[^\\\"]*\\\"\" \
  | head -120 || true

echo
echo --- instant queries ---
for q in \
  \"max(up{job=\\\"otp-relay\\\"})\" \
  \"max(up{job=\\\"otp-monitor\\\"})\" \
  \"max(otp_queue_depth)\" \
  \"max(otp_active_user)\" \
  \"max(otp_iphone_present)\" \
  \"sum(increase(otp_delivered_total[24h]))\" \
  \"sum(increase(otp_claims_total[5m]))\" \
  \"sum(increase(otp_iphone_absence_events_total[5m]))\" \
  \"clamp_min(time() - max(otp_monitor_arp_last_success_timestamp_seconds > 0), 0)\"
do
  echo \"QUERY: \$q\"
  curl -fsS --get \"\$PROM_URL/api/v1/query\" --data-urlencode \"query=\$q\" \
    | sed \"s/,/,\n/g\" \
    | grep -E \"status|resultType|metric|value|error\" \
    | head -40 || true
  echo
done
' || true"

section "Dashboard ConfigMap and query flags"
run_sh "kubectl -n '$OBSERVABILITY_NAMESPACE' get configmap otp-relay-live-dashboard -o jsonpath='{.data.otp-relay-live\\.json}' 2>/dev/null | grep -o '\"expr\":\"[^\"]*\"\\|\"range\":[^,}]*\\|\"instant\":[^,}]*' | head -160 || true"

section "Pending or unhealthy pods"
run_sh "kubectl get pods -A --field-selector=status.phase!=Running -o wide || true"
run_sh "kubectl get pods -A | awk 'NR==1 || \$3 !~ /Running|Completed/ || \$2 !~ /^[0-9]+\\/\\1$/' || true"

section "Recent events"
run_sh "kubectl get events -A --sort-by=.lastTimestamp | tail -150 || true"

section "Repo syntax checks: shell"
if [ -d "$REPO/scripts" ]; then
  run_sh "find scripts -type f -name '*.sh' -print0 | while IFS= read -r -d '' f; do echo \"--- \$f\"; bash -n \"\$f\" && echo OK || echo FAILED; done"
fi

section "Repo dry-run checks: Kubernetes YAML"
if [ -d "$REPO/k8s" ]; then
  run_sh "find k8s -type f \\( -name '*.yaml' -o -name '*.yml' \\) ! -name '*values.yaml' -print0 | while IFS= read -r -d '' f; do echo \"--- \$f\"; kubectl apply --dry-run=client -f \"\$f\" >/dev/null && echo OK || echo FAILED; done"
fi

section "Repo Helm values render check"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null 2>&1 || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null 2>&1 || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null 2>&1 || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo update >/dev/null 2>&1 || true"
run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm repo list || true"

if [ -f "$REPO/k8s/observability/prometheus-stack-values.yaml" ]; then
  KPS_RENDER="$(mktemp /tmp/kps-rendered-health-check.XXXXXX.yaml)"
  run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace '$OBSERVABILITY_NAMESPACE' --version '$KPS_CHART_VERSION' -f k8s/observability/prometheus-stack-values.yaml >'$KPS_RENDER' && echo OK || echo FAILED"
fi

if [ -f "$REPO/k8s/observability/loki-values.yaml" ]; then
  LOKI_RENDER="$(mktemp /tmp/loki-rendered-health-check.XXXXXX.yaml)"
  if [ -n "$LOKI_CHART_VERSION" ]; then
    run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm template loki grafana-community/loki --namespace '$OBSERVABILITY_NAMESPACE' --version '$LOKI_CHART_VERSION' -f k8s/observability/loki-values.yaml >'$LOKI_RENDER' && echo OK || echo FAILED"
  else
    run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm template loki grafana-community/loki --namespace '$OBSERVABILITY_NAMESPACE' -f k8s/observability/loki-values.yaml >'$LOKI_RENDER' && echo OK || echo FAILED"
  fi
fi

if [ -f "$REPO/k8s/observability/alloy-values.yaml" ]; then
  ALLOY_RENDER="$(mktemp /tmp/alloy-rendered-health-check.XXXXXX.yaml)"
  run_sh "sudo KUBECONFIG=$KUBECONFIG_PATH helm template alloy grafana/alloy --namespace '$OBSERVABILITY_NAMESPACE' --version '$ALLOY_CHART_VERSION' -f k8s/observability/alloy-values.yaml >'$ALLOY_RENDER' && echo OK || echo FAILED"
fi

section "Installer recent log tail"
run_sh "tail -250 /tmp/otp-relay-installer-current.log 2>/dev/null || true"

section "Final summary"
echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
echo
echo "Problems: ${#PROBLEMS[@]}"
for p in "${PROBLEMS[@]}"; do
  echo " - $p"
done
echo
echo "Warnings: ${#WARNINGS[@]}"
for w in "${WARNINGS[@]}"; do
  echo " - $w"
done

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  echo
  echo "OK: OTP Relay Kubernetes stack health check passed."
  exit 0
fi

echo
echo "FAILED: OTP Relay Kubernetes stack health check found problems."
exit 2
