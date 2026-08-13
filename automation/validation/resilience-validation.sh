#!/usr/bin/env bash
set -Eeuo pipefail

# OTP Relay Kubernetes resilience validation
#
# Purpose:
#   Validate that the live OTP Relay Kubernetes deployment remains available
#   during controlled restarts, Redis failover, and worker node drain tests.
#
# Default behavior:
#   - Runs non-destructive health checks only.
#   - Does not restart pods, delete Redis pods, drain nodes, or mutate the cluster
#     unless RUN_DESTRUCTIVE_TESTS=1 is set.
#
# Example non-destructive run:
#   bash automation/validation/resilience-validation.sh
#
# Example full resilience run:
#   RUN_DESTRUCTIVE_TESTS=1 ASSUME_YES=1 bash automation/validation/resilience-validation.sh

LOG_FILE="${LOG_FILE:-/tmp/otp-relay-resilience-validation-$(date +%Y%m%d-%H%M%S).log}"
NAMESPACE="${NAMESPACE:-otp-relay}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL_BIN="${KUBECTL_BIN:-}"
HELM_BIN="${HELM_BIN:-helm}"
CURL_BIN="${CURL_BIN:-curl}"

APP_DEPLOYMENT="${APP_DEPLOYMENT:-otp-relay}"
APP_LABEL_SELECTOR="${APP_LABEL_SELECTOR:-app=otp-relay}"
APP_SERVICE="${APP_SERVICE:-otp-relay}"
APP_READY_PATH="${APP_READY_PATH:-/readyz}"
APP_PORT_NAME="${APP_PORT_NAME:-http}"

MONITOR_DEPLOYMENT="${MONITOR_DEPLOYMENT:-otp-monitor}"
MONITOR_LABEL_SELECTOR="${MONITOR_LABEL_SELECTOR:-app=otp-monitor}"
MONITOR_SERVICE="${MONITOR_SERVICE:-otp-monitor}"

REDIS_STATEFULSET="${REDIS_STATEFULSET:-otp-redis}"
REDIS_LABEL_SELECTOR="${REDIS_LABEL_SELECTOR:-app=otp-redis}"
REDIS_SERVICE="${REDIS_SERVICE:-otp-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_EXPECTED_READY="${REDIS_EXPECTED_READY:-3}"
REDIS_MIN_READY_DURING_MAINTENANCE="${REDIS_MIN_READY_DURING_MAINTENANCE:-2}"

SENTINEL_DEPLOYMENT="${SENTINEL_DEPLOYMENT:-otp-redis-sentinel}"
SENTINEL_LABEL_SELECTOR="${SENTINEL_LABEL_SELECTOR:-app=otp-redis-sentinel}"
SENTINEL_SERVICE="${SENTINEL_SERVICE:-otp-redis-sentinel}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
SENTINEL_MASTER_NAME="${SENTINEL_MASTER_NAME:-mymaster}"
SENTINEL_EXPECTED_READY="${SENTINEL_EXPECTED_READY:-3}"

HAPROXY_DEPLOYMENT="${HAPROXY_DEPLOYMENT:-otp-redis-haproxy}"
HAPROXY_LABEL_SELECTOR="${HAPROXY_LABEL_SELECTOR:-app=otp-redis-haproxy}"
HAPROXY_SERVICE="${HAPROXY_SERVICE:-otp-redis-haproxy}"
HAPROXY_PORT="${HAPROXY_PORT:-6379}"
HAPROXY_EXPECTED_READY="${HAPROXY_EXPECTED_READY:-2}"

TRAEFIK_NAMESPACE="${TRAEFIK_NAMESPACE:-kube-system}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-traefik}"
INGRESS_NAME="${INGRESS_NAME:-otp-relay}"
INGRESS_HOST="${INGRESS_HOST:-}"
PORTAL_URL="${PORTAL_URL:-}"
PORTAL_SCHEME="${PORTAL_SCHEME:-http}"
PORTAL_TLS_INSECURE="${PORTAL_TLS_INSECURE:-1}"

LOKI_RELEASE="${LOKI_RELEASE:-loki}"
KPS_RELEASE="${KPS_RELEASE:-kube-prometheus-stack}"
ALLOY_RELEASE="${ALLOY_RELEASE:-alloy}"

WORKER_NODES="${WORKER_NODES:-}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-420s}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-420s}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-420}"
PORTAL_CHECK_ATTEMPTS="${PORTAL_CHECK_ATTEMPTS:-30}"
PORTAL_CHECK_SLEEP="${PORTAL_CHECK_SLEEP:-2}"
RUN_DESTRUCTIVE_TESTS="${RUN_DESTRUCTIVE_TESTS:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
REQUIRE_OBSERVABILITY="${REQUIRE_OBSERVABILITY:-0}"
REQUIRE_REAL_OTP_CONFIRMATION="${REQUIRE_REAL_OTP_CONFIRMATION:-0}"

PROBLEMS=()
WARNINGS=()
TEMP_FILES=()
STARTED_AT="$(date -Is)"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee "$LOG_FILE") 2>&1

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    rm -f "$file" 2>/dev/null || true
  done
}
trap cleanup EXIT

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { WARNINGS+=("$*"); printf '[WARN] %s\n' "$*" >&2; }
problem() { PROBLEMS+=("$*"); printf '[FAIL] %s\n' "$*" >&2; }
fatal() { problem "$*"; print_summary; exit 1; }

section() {
  printf '\n================================================================================\n'
  printf '%s\n' "$1"
  printf '================================================================================\n'
}

run_cmd() {
  printf '\n+ %s\n' "$*"
  "$@"
}

kubectl_cmd() {
  if [ -n "$KUBECTL_BIN" ]; then
    "$KUBECTL_BIN" "$@"
  elif command -v k3s >/dev/null 2>&1; then
    sudo k3s kubectl "$@"
  elif command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
  else
    fatal "Neither k3s nor kubectl is available"
  fi
}

helm_cmd() {
  KUBECONFIG="$KUBECONFIG_PATH" sudo -E "$HELM_BIN" "$@"
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fatal "Missing required command: $cmd"
}

jsonpath() {
  kubectl_cmd "$@" 2>/dev/null || true
}

wait_seconds() {
  local seconds="$1"
  local label="$2"
  local i

  for i in $(seq 1 "$seconds"); do
    if [ $((i % 10)) -eq 0 ]; then
      info "Waiting for $label: ${i}s/${seconds}s"
    fi
    sleep 1
  done
}

confirm_destructive_tests() {
  if [ "$RUN_DESTRUCTIVE_TESTS" != "1" ]; then
    info "RUN_DESTRUCTIVE_TESTS is not 1; destructive restart/delete/drain tests will be skipped."
    return 0
  fi

  if [ "$ASSUME_YES" = "1" ]; then
    warn "RUN_DESTRUCTIVE_TESTS=1 and ASSUME_YES=1; destructive tests are enabled."
    return 0
  fi

  printf '\nThis will restart deployments, delete a Redis pod, and drain worker nodes.\n'
  printf 'Type YES to continue: '
  local answer
  read -r answer
  if [ "$answer" != "YES" ]; then
    fatal "Destructive tests were requested but confirmation was not provided"
  fi
}

pod_ready_names() {
  local ns="$1"
  local selector="$2"

  kubectl_cmd -n "$ns" get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[*]}{.type}{"="}{.status}{";"}{end}{"\n"}{end}' \
    | awk -F '\t' '$2 == "Running" && $3 ~ /Ready=True/ {print $1}'
}

first_ready_pod() {
  local ns="$1"
  local selector="$2"

  pod_ready_names "$ns" "$selector" | head -1
}

ready_pod_count() {
  local ns="$1"
  local selector="$2"

  pod_ready_names "$ns" "$selector" | wc -l | tr -d ' '
}

deployment_ready_counts() {
  local ns="$1"
  local name="$2"

  kubectl_cmd -n "$ns" get deployment "$name" -o jsonpath='{.status.replicas}{" "}{.status.readyReplicas}{" "}{.status.availableReplicas}' 2>/dev/null || true
}

statefulset_ready_counts() {
  local ns="$1"
  local name="$2"

  kubectl_cmd -n "$ns" get statefulset "$name" -o jsonpath='{.status.replicas}{" "}{.status.readyReplicas}' 2>/dev/null || true
}

check_deployment_ready() {
  local ns="$1"
  local name="$2"
  local label="$3"
  local counts desired ready available

  if ! kubectl_cmd -n "$ns" get deployment "$name" >/dev/null 2>&1; then
    problem "$label deployment missing: $ns/$name"
    return 1
  fi

  counts="$(deployment_ready_counts "$ns" "$name")"
  read -r desired ready available <<EOF_COUNTS
${counts:-0 0 0}
EOF_COUNTS
  desired="${desired:-0}"
  ready="${ready:-0}"
  available="${available:-0}"

  if [ "$desired" = "$ready" ] && [ "$desired" = "$available" ] && [ "$desired" != "0" ]; then
    ok "$label deployment ready: desired=$desired ready=$ready available=$available"
    return 0
  fi

  problem "$label deployment not ready: desired=$desired ready=$ready available=$available"
  return 1
}

check_statefulset_ready() {
  local ns="$1"
  local name="$2"
  local label="$3"
  local min_ready="$4"
  local counts desired ready

  if ! kubectl_cmd -n "$ns" get statefulset "$name" >/dev/null 2>&1; then
    problem "$label StatefulSet missing: $ns/$name"
    return 1
  fi

  counts="$(statefulset_ready_counts "$ns" "$name")"
  read -r desired ready <<EOF_COUNTS
${counts:-0 0}
EOF_COUNTS
  desired="${desired:-0}"
  ready="${ready:-0}"

  if [ "$ready" -ge "$min_ready" ] && [ "$desired" != "0" ]; then
    ok "$label StatefulSet acceptable: desired=$desired ready=$ready min_ready=$min_ready"
    return 0
  fi

  problem "$label StatefulSet not acceptable: desired=$desired ready=$ready min_ready=$min_ready"
  return 1
}

check_service_endpoints() {
  local ns="$1"
  local svc="$2"
  local label="$3"
  local endpoints

  if ! kubectl_cmd -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    problem "$label service missing: $ns/$svc"
    return 1
  fi

  endpoints="$(kubectl_cmd -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [ -n "$endpoints" ]; then
    ok "$label service has ready endpoints: $endpoints"
    return 0
  fi

  problem "$label service has no ready endpoints: $ns/$svc"
  return 1
}

get_ingress_host() {
  if [ -n "$INGRESS_HOST" ]; then
    printf '%s\n' "$INGRESS_HOST"
    return 0
  fi

  kubectl_cmd -n "$NAMESPACE" get ingress "$INGRESS_NAME" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true
}

get_traefik_external_ip() {
  kubectl_cmd -n "$TRAEFIK_NAMESPACE" get svc "$TRAEFIK_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

build_portal_url() {
  local lb_ip host path

  if [ -n "$PORTAL_URL" ]; then
    printf '%s\n' "$PORTAL_URL"
    return 0
  fi

  lb_ip="$(get_traefik_external_ip)"
  host="$(get_ingress_host)"
  path="$APP_READY_PATH"

  if [ -n "$lb_ip" ]; then
    printf '%s://%s%s\n' "$PORTAL_SCHEME" "$lb_ip" "$path"
    return 0
  fi

  if [ -n "$host" ]; then
    printf '%s://%s%s\n' "$PORTAL_SCHEME" "$host" "$path"
    return 0
  fi

  return 1
}

curl_portal_once() {
  local url="$1"
  local host_header="$2"
  local curl_args=(-fsS --connect-timeout 5 --max-time 12)

  if [ "$PORTAL_TLS_INSECURE" = "1" ]; then
    curl_args+=(-k)
  fi

  if [ -n "$host_header" ]; then
    curl_args+=(-H "Host: ${host_header}")
  fi

  "$CURL_BIN" "${curl_args[@]}" "$url" >/tmp/otp-relay-readyz-body.$$ 2>/tmp/otp-relay-readyz-error.$$
}

check_portal_ready() {
  local url host_header attempt rc body error

  url="$(build_portal_url)" || {
    problem "Could not determine portal URL from PORTAL_URL, Traefik LoadBalancer IP, or Ingress host"
    return 1
  }
  host_header="$(get_ingress_host)"

  for attempt in $(seq 1 "$PORTAL_CHECK_ATTEMPTS"); do
    if curl_portal_once "$url" "$host_header"; then
      body="$(cat /tmp/otp-relay-readyz-body.$$ 2>/dev/null || true)"
      rm -f /tmp/otp-relay-readyz-body.$$ /tmp/otp-relay-readyz-error.$$
      ok "Portal readiness reachable on attempt $attempt: $url"
      if [ -n "$body" ]; then
        printf '%s\n' "$body" | head -20
      fi
      return 0
    fi

    rc="$?"
    error="$(cat /tmp/otp-relay-readyz-error.$$ 2>/dev/null || true)"
    rm -f /tmp/otp-relay-readyz-body.$$ /tmp/otp-relay-readyz-error.$$
    warn "Portal readiness attempt $attempt/$PORTAL_CHECK_ATTEMPTS failed rc=$rc url=$url ${error}"
    sleep "$PORTAL_CHECK_SLEEP"
  done

  problem "Portal readiness failed after $PORTAL_CHECK_ATTEMPTS attempts: $url"
  return 1
}

check_nodes_ready() {
  local not_ready

  section "Kubernetes nodes"
  run_cmd kubectl_cmd get nodes -o wide
  not_ready="$(kubectl_cmd get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1":"$2}' || true)"
  if [ -n "$not_ready" ]; then
    problem "NotReady nodes found: $not_ready"
    return 1
  fi
  ok "All nodes are Ready"
}

check_core_workloads() {
  local redis_min_ready="$1"

  section "Core OTP Relay workloads"
  run_cmd kubectl_cmd -n "$NAMESPACE" get pods -o wide
  run_cmd kubectl_cmd -n "$NAMESPACE" get svc -o wide
  run_cmd kubectl_cmd -n "$NAMESPACE" get ingress -o wide

  check_deployment_ready "$NAMESPACE" "$APP_DEPLOYMENT" "OTP Relay app" || true
  check_deployment_ready "$NAMESPACE" "$MONITOR_DEPLOYMENT" "OTP monitor" || true
  check_statefulset_ready "$NAMESPACE" "$REDIS_STATEFULSET" "Redis" "$redis_min_ready" || true
  check_deployment_ready "$NAMESPACE" "$SENTINEL_DEPLOYMENT" "Redis Sentinel" || true
  check_deployment_ready "$NAMESPACE" "$HAPROXY_DEPLOYMENT" "Redis HAProxy" || true

  check_service_endpoints "$NAMESPACE" "$APP_SERVICE" "OTP Relay app" || true
  check_service_endpoints "$NAMESPACE" "$MONITOR_SERVICE" "OTP monitor" || true
  check_service_endpoints "$NAMESPACE" "$REDIS_SERVICE" "Redis" || true
  check_service_endpoints "$NAMESPACE" "$SENTINEL_SERVICE" "Redis Sentinel" || true
  check_service_endpoints "$NAMESPACE" "$HAPROXY_SERVICE" "Redis HAProxy" || true
}

check_redis_stack() {
  local mode="$1"
  local redis_min_ready sentinel_ready haproxy_ready redis_pod sentinel_pod

  section "Redis/Sentinel/HAProxy validation (${mode})"

  if [ "$mode" = "maintenance" ]; then
    redis_min_ready="$REDIS_MIN_READY_DURING_MAINTENANCE"
  else
    redis_min_ready="$REDIS_EXPECTED_READY"
  fi

  check_statefulset_ready "$NAMESPACE" "$REDIS_STATEFULSET" "Redis" "$redis_min_ready" || true

  sentinel_ready="$(ready_pod_count "$NAMESPACE" "$SENTINEL_LABEL_SELECTOR")"
  if [ "$sentinel_ready" -ge "$SENTINEL_EXPECTED_READY" ]; then
    ok "Redis Sentinel ready pod count acceptable: $sentinel_ready/$SENTINEL_EXPECTED_READY"
  else
    problem "Redis Sentinel ready pod count too low: $sentinel_ready/$SENTINEL_EXPECTED_READY"
  fi

  haproxy_ready="$(ready_pod_count "$NAMESPACE" "$HAPROXY_LABEL_SELECTOR")"
  if [ "$haproxy_ready" -ge "$HAPROXY_EXPECTED_READY" ]; then
    ok "Redis HAProxy ready pod count acceptable: $haproxy_ready/$HAPROXY_EXPECTED_READY"
  else
    problem "Redis HAProxy ready pod count too low: $haproxy_ready/$HAPROXY_EXPECTED_READY"
  fi

  redis_pod="$(first_ready_pod "$NAMESPACE" "$REDIS_LABEL_SELECTOR")"
  if [ -z "$redis_pod" ]; then
    problem "No Running/Ready Redis pod available for redis-cli validation"
  else
    if kubectl_cmd -n "$NAMESPACE" exec "$redis_pod" -- redis-cli -p "$REDIS_PORT" PING | grep -q '^PONG$'; then
      ok "Redis PING passed using Running/Ready pod: $redis_pod"
    else
      problem "Redis PING failed using pod: $redis_pod"
    fi
  fi

  sentinel_pod="$(first_ready_pod "$NAMESPACE" "$SENTINEL_LABEL_SELECTOR")"
  if [ -z "$sentinel_pod" ]; then
    problem "No Running/Ready Sentinel pod available for sentinel validation"
  else
    if kubectl_cmd -n "$NAMESPACE" exec "$sentinel_pod" -- redis-cli -p "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$SENTINEL_MASTER_NAME" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      ok "Sentinel master lookup passed using Running/Ready pod: $sentinel_pod"
    else
      problem "Sentinel master lookup failed using pod: $sentinel_pod"
    fi
  fi
}

check_storage_and_pdbs() {
  section "Storage, PDBs, resources, probes"

  run_cmd kubectl_cmd -n "$NAMESPACE" get pvc -o wide || true
  run_cmd kubectl_cmd -n "$NAMESPACE" get pdb -o wide || true

  local pdbs bad_pdbs
  pdbs="$(kubectl_cmd -n "$NAMESPACE" get pdb --no-headers 2>/dev/null || true)"
  if [ -z "$pdbs" ]; then
    warn "No PodDisruptionBudgets found in namespace $NAMESPACE"
  else
    bad_pdbs="$(printf '%s\n' "$pdbs" | awk '$3 == "0" {print $1}' || true)"
    if [ -n "$bad_pdbs" ]; then
      problem "PDBs currently allow zero disruptions: $bad_pdbs"
    else
      ok "PDBs currently allow disruptions where required"
    fi
  fi

  local no_requests
  no_requests="$(kubectl_cmd -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{":"}{.resources.requests.cpu}{","}{.resources.requests.memory}{";"}{end}{"\n"}{end}' 2>/dev/null | awk -F '\t' '$2 ~ /:<none>|:;|,,/ {print $1}' || true)"
  if [ -n "$no_requests" ]; then
    warn "Some pods may have incomplete resource requests: $no_requests"
  else
    ok "No obvious missing pod resource requests detected"
  fi
}

check_observability() {
  section "Observability validation"

  if ! kubectl_cmd get namespace "$OBSERVABILITY_NAMESPACE" >/dev/null 2>&1; then
    if [ "$REQUIRE_OBSERVABILITY" = "1" ]; then
      problem "Observability namespace missing: $OBSERVABILITY_NAMESPACE"
    else
      warn "Observability namespace missing; skipping because REQUIRE_OBSERVABILITY is not 1"
    fi
    return 0
  fi

  run_cmd kubectl_cmd -n "$OBSERVABILITY_NAMESPACE" get pods -o wide
  run_cmd kubectl_cmd -n "$OBSERVABILITY_NAMESPACE" get svc -o wide

  if command -v "$HELM_BIN" >/dev/null 2>&1; then
    helm_cmd -n "$OBSERVABILITY_NAMESPACE" list || warn "Helm list failed for observability namespace"
  else
    warn "Helm is not installed or not in PATH; skipping Helm release checks"
  fi

  local loki_pods
  loki_pods="$(kubectl_cmd -n "$OBSERVABILITY_NAMESPACE" get pods -l app.kubernetes.io/instance="$LOKI_RELEASE" --field-selector=status.phase=Running -o name 2>/dev/null || true)"
  if [ -n "$loki_pods" ]; then
    ok "Loki running workload exists"
    printf '%s\n' "$loki_pods"
  elif [ "$REQUIRE_OBSERVABILITY" = "1" ]; then
    problem "No running Loki pods found for release $LOKI_RELEASE"
  else
    warn "No running Loki pods found for release $LOKI_RELEASE"
  fi

  local grafana_pods prometheus_pods
  grafana_pods="$(kubectl_cmd -n "$OBSERVABILITY_NAMESPACE" get pods -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running -o name 2>/dev/null || true)"
  prometheus_pods="$(kubectl_cmd -n "$OBSERVABILITY_NAMESPACE" get pods -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running -o name 2>/dev/null || true)"

  if [ -n "$grafana_pods" ]; then
    ok "Grafana running pod exists"
  elif [ "$REQUIRE_OBSERVABILITY" = "1" ]; then
    problem "Grafana running pod missing"
  else
    warn "Grafana running pod missing"
  fi

  if [ -n "$prometheus_pods" ]; then
    ok "Prometheus running pod exists"
  elif [ "$REQUIRE_OBSERVABILITY" = "1" ]; then
    problem "Prometheus running pod missing"
  else
    warn "Prometheus running pod missing"
  fi
}

check_repo_syntax() {
  section "Repository syntax checks"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  info "Detected repo root: $repo_root"

  if [ ! -d "$repo_root/.git" ] && [ ! -f "$repo_root/install-otp-relay-k8s.sh" ]; then
    warn "Could not confirm repo root; skipping repo syntax checks"
    return 0
  fi

  local file failed=0
  for file in \
    "$repo_root/install-otp-relay-k8s.sh" \
    "$repo_root/scripts/lib/env.sh" \
    "$repo_root/scripts/lib/preflight.sh" \
    "$repo_root/scripts/lib/metallb.sh" \
    "$repo_root/scripts/lib/summary.sh" \
    "$repo_root/scripts/sync-repo.sh" \
    "$repo_root/scripts/install-repo-sync-timer.sh" \
    "$repo_root/automation/libvirt/provision-vms.sh"; do
    if [ -f "$file" ]; then
      if bash -n "$file"; then
        ok "bash syntax OK: ${file#$repo_root/}"
      else
        problem "bash syntax failed: ${file#$repo_root/}"
        failed=1
      fi
    fi
  done

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$repo_root" <<'PY' || failed=1
from pathlib import Path
import sys
try:
    import yaml
except Exception as exc:
    print(f"[WARN] PyYAML not available; skipping YAML parse checks: {exc}")
    raise SystemExit(0)
root = Path(sys.argv[1])
files = [
    root / "automation/ansible/roles/k3s_server/tasks/main.yml",
    root / "automation/ansible/roles/k3s_agent/tasks/main.yml",
    root / "automation/ansible/roles/otp_relay_deploy/tasks/main.yml",
    root / "k8s/observability/loki-values.yaml",
]
for file in files:
    if file.exists():
        yaml.safe_load(file.read_text())
        print(f"[OK] YAML parse OK: {file.relative_to(root)}")
PY
  fi

  if [ "$failed" != "0" ]; then
    problem "One or more repository syntax checks failed"
  fi
}

wait_for_rollout() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local label="$4"

  if kubectl_cmd -n "$ns" rollout status "$kind/$name" --timeout="$ROLLOUT_TIMEOUT"; then
    ok "$label rollout completed"
    return 0
  fi

  problem "$label rollout failed or timed out"
  return 1
}

restart_deployment_test() {
  local ns="$1"
  local deployment="$2"
  local label="$3"

  section "Restart test: $label"
  kubectl_cmd -n "$ns" rollout restart "deployment/$deployment"
  wait_for_rollout "$ns" deployment "$deployment" "$label" || true
  check_portal_ready || true
}

find_current_redis_master_pod() {
  local sentinel_pod master_ip pod

  sentinel_pod="$(first_ready_pod "$NAMESPACE" "$SENTINEL_LABEL_SELECTOR")"
  if [ -z "$sentinel_pod" ]; then
    return 1
  fi

  master_ip="$(kubectl_cmd -n "$NAMESPACE" exec "$sentinel_pod" -- redis-cli -p "$SENTINEL_PORT" SENTINEL get-master-addr-by-name "$SENTINEL_MASTER_NAME" | awk 'NR == 1 {print $1}')"
  if [ -z "$master_ip" ]; then
    return 1
  fi

  pod="$(kubectl_cmd -n "$NAMESPACE" get pods -l "$REDIS_LABEL_SELECTOR" -o wide --no-headers 2>/dev/null | awk -v ip="$master_ip" '$6 == ip {print $1; exit}')"
  if [ -n "$pod" ]; then
    printf '%s\n' "$pod"
    return 0
  fi

  return 1
}

redis_master_delete_test() {
  local master_pod

  section "Redis master pod deletion/failover test"
  master_pod="$(find_current_redis_master_pod || true)"
  if [ -z "$master_pod" ]; then
    warn "Could not identify Redis master pod; falling back to first Running/Ready Redis pod"
    master_pod="$(first_ready_pod "$NAMESPACE" "$REDIS_LABEL_SELECTOR")"
  fi

  if [ -z "$master_pod" ]; then
    problem "No Redis pod available for deletion test"
    return 1
  fi

  warn "Deleting Redis pod for resilience test: $master_pod"
  kubectl_cmd -n "$NAMESPACE" delete pod "$master_pod" --wait=false
  wait_for_recovery "Redis master deletion recovery" "$REDIS_EXPECTED_READY"
}

wait_for_recovery() {
  local label="$1"
  local redis_min_ready="$2"
  local elapsed=0

  section "Recovery wait: $label"

  while [ "$elapsed" -le "$RECOVERY_TIMEOUT_SECONDS" ]; do
    local before_count
    before_count="${#PROBLEMS[@]}"

    check_portal_ready || true
    check_statefulset_ready "$NAMESPACE" "$REDIS_STATEFULSET" "Redis" "$redis_min_ready" || true
    check_deployment_ready "$NAMESPACE" "$APP_DEPLOYMENT" "OTP Relay app" || true
    check_deployment_ready "$NAMESPACE" "$SENTINEL_DEPLOYMENT" "Redis Sentinel" || true
    check_deployment_ready "$NAMESPACE" "$HAPROXY_DEPLOYMENT" "Redis HAProxy" || true

    if [ "${#PROBLEMS[@]}" -eq "$before_count" ]; then
      ok "$label completed after ${elapsed}s"
      return 0
    fi

    # Remove transient problems added during retry window. Final pass will report real failures.
    while [ "${#PROBLEMS[@]}" -gt "$before_count" ]; do
      local last_index
      last_index=$(( ${#PROBLEMS[@]} - 1 ))
      unset "PROBLEMS[$last_index]"
      PROBLEMS=("${PROBLEMS[@]}")
    done

    sleep 10
    elapsed=$((elapsed + 10))
  done

  problem "$label did not recover within ${RECOVERY_TIMEOUT_SECONDS}s"
  return 1
}

detect_worker_nodes() {
  if [ -n "$WORKER_NODES" ]; then
    printf '%s\n' $WORKER_NODES
    return 0
  fi

  kubectl_cmd get nodes --no-headers 2>/dev/null \
    | awk '$3 !~ /control-plane|master/ {print $1}'
}

drain_worker_test() {
  local node="$1"

  section "Worker drain test: $node"

  warn "Draining worker node: $node"
  if ! kubectl_cmd drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"; then
    problem "Drain failed for node $node"
    kubectl_cmd describe node "$node" | tail -120 || true
    kubectl_cmd -n "$NAMESPACE" get pods -o wide || true
    kubectl_cmd uncordon "$node" || true
    return 1
  fi

  check_portal_ready || true
  check_core_workloads "$REDIS_MIN_READY_DURING_MAINTENANCE" || true
  check_redis_stack maintenance || true

  warn "Uncordoning worker node: $node"
  kubectl_cmd uncordon "$node"
  wait_for_recovery "worker $node uncordon recovery" "$REDIS_EXPECTED_READY"
}

real_otp_confirmation_gate() {
  section "Real OTP flow confirmation gate"

  if [ "$REQUIRE_REAL_OTP_CONFIRMATION" != "1" ]; then
    warn "Real OTP confirmation gate skipped. Set REQUIRE_REAL_OTP_CONFIRMATION=1 to require manual confirmation."
    return 0
  fi

  printf '\nTrigger the real SMS/OTP flow now. Confirm that the iPhone received the OTP and the iOS Shortcut posted it to the portal.\n'
  printf 'Type OTP_OK to continue: '
  local answer
  read -r answer
  if [ "$answer" = "OTP_OK" ]; then
    ok "Manual OTP confirmation accepted"
    return 0
  fi

  problem "Manual OTP confirmation failed or was not provided"
  return 1
}

print_summary() {
  section "Validation summary"
  printf 'Started: %s\n' "$STARTED_AT"
  printf 'Finished: %s\n' "$(date -Is)"
  printf 'Log: %s\n' "$LOG_FILE"
  printf 'Warnings: %s\n' "${#WARNINGS[@]}"
  printf 'Problems: %s\n' "${#PROBLEMS[@]}"

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\nWarnings:\n'
    printf ' - %s\n' "${WARNINGS[@]}"
  fi

  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    printf '\nProblems:\n'
    printf ' - %s\n' "${PROBLEMS[@]}"
  fi

  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    printf '\nRESULT: PASS\n'
  else
    printf '\nRESULT: FAIL\n'
  fi
}

main() {
  section "OTP Relay Kubernetes resilience validation"
  info "Started: $STARTED_AT"
  info "Log: $LOG_FILE"
  info "Namespace: $NAMESPACE"
  info "Observability namespace: $OBSERVABILITY_NAMESPACE"
  info "RUN_DESTRUCTIVE_TESTS: $RUN_DESTRUCTIVE_TESTS"

  require_command "$CURL_BIN"
  confirm_destructive_tests

  check_nodes_ready || true
  check_core_workloads "$REDIS_EXPECTED_READY" || true
  check_redis_stack strict || true
  check_storage_and_pdbs || true
  check_observability || true
  check_repo_syntax || true

  section "Portal readiness"
  check_portal_ready || true

  real_otp_confirmation_gate || true

  if [ "$RUN_DESTRUCTIVE_TESTS" = "1" ]; then
    restart_deployment_test "$NAMESPACE" "$APP_DEPLOYMENT" "OTP Relay app" || true
    restart_deployment_test "$NAMESPACE" "$MONITOR_DEPLOYMENT" "OTP monitor" || true
    restart_deployment_test "$NAMESPACE" "$SENTINEL_DEPLOYMENT" "Redis Sentinel" || true
    restart_deployment_test "$NAMESPACE" "$HAPROXY_DEPLOYMENT" "Redis HAProxy" || true
    redis_master_delete_test || true

    local worker
    for worker in $(detect_worker_nodes); do
      drain_worker_test "$worker" || true
    done

    section "Final strict recovery check"
    wait_for_recovery "final strict recovery" "$REDIS_EXPECTED_READY" || true
    check_nodes_ready || true
    check_core_workloads "$REDIS_EXPECTED_READY" || true
    check_redis_stack strict || true
    check_portal_ready || true
  fi

  print_summary

  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    exit 0
  fi

  exit 1
}

main "$@"
