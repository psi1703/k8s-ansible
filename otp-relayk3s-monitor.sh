#!/usr/bin/env bash
set -u
set -o pipefail

ENV_FILE="${ENV_FILE:-/etc/otp-relay-k3s-monitor.env}"
KUBECTL="${KUBECTL:-kubectl}"

ALERT_STATE_DIR="${ALERT_STATE_DIR:-/var/tmp/otp-relay-k3s-monitor}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
NOW_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

mkdir -p "$ALERT_STATE_DIR"

PROBLEMS=()
DETAILS=()

add_problem() {
  PROBLEMS+=("$1")
}

add_detail() {
  DETAILS+=("$1")
}

kubectl_ok() {
  "$KUBECTL" version --client >/dev/null 2>&1
}

cluster_ok() {
  "$KUBECTL" get --raw=/readyz >/dev/null 2>&1
}

env_get_existing() {
  local key="$1"

  if [ -f "$ENV_FILE" ]; then
    grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
  fi
}

preserve_or_default() {
  local key="$1"
  local default_value="$2"
  local existing

  existing="$(env_get_existing "$key")"

  if [ -n "$existing" ] && [ "$existing" != "CHANGEME" ]; then
    echo "$existing"
  else
    echo "$default_value"
  fi
}

detect_namespace() {
  local existing
  existing="$(env_get_existing NAMESPACE)"

  if [ -n "$existing" ] && "$KUBECTL" get namespace "$existing" >/dev/null 2>&1; then
    echo "$existing"
    return
  fi

  if "$KUBECTL" get namespace otp-relay >/dev/null 2>&1; then
    echo "otp-relay"
    return
  fi

  "$KUBECTL" get deployments -A --no-headers 2>/dev/null \
    | awk '$2 ~ /otp-relay|relay/ {print $1; exit}'
}

detect_deployment_by_pattern() {
  local ns="$1"
  local pattern="$2"
  local exclude="${3:-}"

  "$KUBECTL" -n "$ns" get deployments --no-headers 2>/dev/null \
    | awk -v pattern="$pattern" -v exclude="$exclude" '
      $1 ~ pattern {
        if (exclude == "" || $1 !~ exclude) {
          print $1
          exit
        }
      }
    '
}

detect_statefulset_by_pattern() {
  local ns="$1"
  local pattern="$2"
  local exclude="${3:-}"

  "$KUBECTL" -n "$ns" get statefulsets --no-headers 2>/dev/null \
    | awk -v pattern="$pattern" -v exclude="$exclude" '
      $1 ~ pattern {
        if (exclude == "" || $1 !~ exclude) {
          print $1
          exit
        }
      }
    '
}

safe_selector_for_workload() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local fallback="$4"

  [ -z "$name" ] && {
    echo "$fallback"
    return
  }

  local selector
  selector="$("$KUBECTL" -n "$ns" get "$kind" "$name" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    labels = obj.get("spec", {}).get("selector", {}).get("matchLabels", {})
    print(",".join(f"{k}={v}" for k, v in labels.items()))
except Exception:
    print("")
' 2>/dev/null || true)"

  if [ -n "$selector" ]; then
    echo "$selector"
  else
    echo "$fallback"
  fi
}

detect_service_by_selector() {
  local ns="$1"
  local selector="$2"

  [ -z "$selector" ] && return

  "$KUBECTL" -n "$ns" get svc -o json 2>/dev/null | python3 - "$selector" <<'PY'
import json, sys

wanted = {}
for item in sys.argv[1].split(","):
    if "=" in item:
        k, v = item.split("=", 1)
        wanted[k] = v

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for svc in data.get("items", []):
    sel = svc.get("spec", {}).get("selector", {}) or {}
    if wanted and all(sel.get(k) == v for k, v in wanted.items()):
        print(svc["metadata"]["name"])
        break
PY
}

detect_service_by_pattern() {
  local ns="$1"
  local pattern="$2"
  local exclude="${3:-}"

  "$KUBECTL" -n "$ns" get svc --no-headers 2>/dev/null \
    | awk -v pattern="$pattern" -v exclude="$exclude" '
      $1 ~ pattern {
        if (exclude == "" || $1 !~ exclude) {
          print $1
          exit
        }
      }
    '
}

service_port() {
  local ns="$1"
  local svc="$2"

  [ -z "$svc" ] && return

  "$KUBECTL" -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true
}

detect_portal_url() {
  local ns="$1"
  local svc="$2"

  [ -z "$svc" ] && return

  local ip
  ip="$("$KUBECTL" -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

  if [ -n "$ip" ]; then
    echo "http://${ip}"
    return
  fi

  local node_port
  node_port="$("$KUBECTL" -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"

  if [ -n "$node_port" ]; then
    local node_ip
    node_ip="$("$KUBECTL" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

    if [ -n "$node_ip" ]; then
      echo "http://${node_ip}:${node_port}"
    fi
  fi
}

detect_sentinel_kind() {
  local ns="$1"

  if "$KUBECTL" -n "$ns" get deployment otp-redis-sentinel >/dev/null 2>&1; then
    echo "deployment"
    return
  fi

  if "$KUBECTL" -n "$ns" get statefulset otp-redis-sentinel >/dev/null 2>&1; then
    echo "statefulset"
    return
  fi

  if "$KUBECTL" -n "$ns" get deployments --no-headers 2>/dev/null | awk '$1 ~ /sentinel/ {found=1} END {exit !found}'; then
    echo "deployment"
    return
  fi

  if "$KUBECTL" -n "$ns" get statefulsets --no-headers 2>/dev/null | awk '$1 ~ /sentinel/ {found=1} END {exit !found}'; then
    echo "statefulset"
    return
  fi

  echo ""
}

detect_sentinel_workload() {
  local ns="$1"
  local kind="$2"

  if [ "$kind" = "deployment" ]; then
    detect_deployment_by_pattern "$ns" "sentinel"
  elif [ "$kind" = "statefulset" ]; then
    detect_statefulset_by_pattern "$ns" "sentinel"
  fi
}

detect_sentinel_master_name() {
  local ns="$1"
  local selector="$2"
  local port="$3"

  [ -z "$selector" ] && {
    echo "mymaster"
    return
  }

  local pod
  pod="$("$KUBECTL" -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  [ -z "$pod" ] && {
    echo "mymaster"
    return
  }

  local masters
  masters="$("$KUBECTL" -n "$ns" exec "$pod" -- redis-cli -p "$port" sentinel masters 2>/dev/null || true)"

  local name
  name="$(printf '%s\n' "$masters" | awk '
    previous == "name" {
      print $0
      exit
    }
    $0 == "name" {
      previous = "name"
      next
    }
    {
      previous = ""
    }
  ')"

  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "mymaster"
  fi
}

write_env_file() {
  if ! kubectl_ok; then
    echo "ERROR: kubectl is not installed or not usable."
    exit 1
  fi

  if ! cluster_ok; then
    echo "ERROR: Kubernetes API /readyz failed."
    exit 1
  fi

  local ns
  ns="$(detect_namespace)"

  if [ -z "$ns" ]; then
    echo "ERROR: Could not detect namespace."
    exit 1
  fi

  local app_deployment monitor_deployment redis_statefulset sentinel_kind sentinel_workload haproxy_deployment
  app_deployment="$(detect_deployment_by_pattern "$ns" "otp-relay|relay" "redis|sentinel|haproxy|monitor")"
  monitor_deployment="$(detect_deployment_by_pattern "$ns" "monitor")"
  redis_statefulset="$(detect_statefulset_by_pattern "$ns" "redis" "sentinel|haproxy")"
  sentinel_kind="$(detect_sentinel_kind "$ns")"
  sentinel_workload="$(detect_sentinel_workload "$ns" "$sentinel_kind")"
  haproxy_deployment="$(detect_deployment_by_pattern "$ns" "haproxy")"

  local app_selector monitor_selector redis_selector sentinel_selector haproxy_selector
  app_selector="$(safe_selector_for_workload "$ns" deployment "$app_deployment" "app=otp-relay")"
  monitor_selector="$(safe_selector_for_workload "$ns" deployment "$monitor_deployment" "app=otp-monitor")"
  redis_selector="$(safe_selector_for_workload "$ns" statefulset "$redis_statefulset" "app=otp-redis")"

  if [ "$sentinel_kind" = "deployment" ]; then
    sentinel_selector="$(safe_selector_for_workload "$ns" deployment "$sentinel_workload" "app=otp-redis-sentinel")"
  elif [ "$sentinel_kind" = "statefulset" ]; then
    sentinel_selector="$(safe_selector_for_workload "$ns" statefulset "$sentinel_workload" "app=otp-redis-sentinel")"
  else
    sentinel_selector="app=otp-redis-sentinel"
  fi

  haproxy_selector="$(safe_selector_for_workload "$ns" deployment "$haproxy_deployment" "app=otp-redis-haproxy")"

  local portal_service redis_service sentinel_service haproxy_service
  portal_service="$(detect_service_by_selector "$ns" "$app_selector")"
  [ -z "$portal_service" ] && portal_service="$(detect_service_by_pattern "$ns" "otp-relay|relay|portal" "redis|sentinel|haproxy")"

  redis_service="$(detect_service_by_pattern "$ns" "^otp-redis$")"
  [ -z "$redis_service" ] && redis_service="$(detect_service_by_pattern "$ns" "redis" "sentinel|headless")"

  sentinel_service="$(detect_service_by_selector "$ns" "$sentinel_selector")"
  [ -z "$sentinel_service" ] && sentinel_service="$(detect_service_by_pattern "$ns" "sentinel")"

  haproxy_service="$(detect_service_by_selector "$ns" "$haproxy_selector")"
  [ -z "$haproxy_service" ] && haproxy_service="$(detect_service_by_pattern "$ns" "haproxy")"

  local redis_port sentinel_port haproxy_port portal_url sentinel_master_name
  redis_port="$(service_port "$ns" "$redis_service")"
  sentinel_port="$(service_port "$ns" "$sentinel_service")"
  haproxy_port="$(service_port "$ns" "$haproxy_service")"

  redis_port="${redis_port:-6379}"
  sentinel_port="${sentinel_port:-26379}"
  haproxy_port="${haproxy_port:-6379}"

  portal_url="$(detect_portal_url "$ns" "$portal_service")"
  sentinel_master_name="$(detect_sentinel_master_name "$ns" "$sentinel_selector" "$sentinel_port")"

  local smtp_host smtp_port smtp_tls smtp_user smtp_pass smtp_from smtp_to cooldown
  smtp_host="$(preserve_or_default SMTP_HOST CHANGEME)"
  smtp_port="$(preserve_or_default SMTP_PORT 587)"
  smtp_tls="$(preserve_or_default SMTP_TLS 1)"
  smtp_user="$(preserve_or_default SMTP_USER CHANGEME)"
  smtp_pass="$(preserve_or_default SMTP_PASS CHANGEME)"
  smtp_from="$(preserve_or_default SMTP_FROM CHANGEME)"
  smtp_to="$(preserve_or_default SMTP_TO CHANGEME)"
  cooldown="$(preserve_or_default ALERT_COOLDOWN_SECONDS 1800)"

  local tmp
  tmp="$(mktemp)"

  cat > "$tmp" <<EOF
NAMESPACE=$ns
KUBECTL=$KUBECTL

APP_DEPLOYMENT=$app_deployment
APP_LABEL_SELECTOR=$app_selector

MONITOR_DEPLOYMENT=$monitor_deployment
MONITOR_LABEL_SELECTOR=$monitor_selector

REDIS_STATEFULSET=$redis_statefulset
REDIS_LABEL_SELECTOR=$redis_selector
REDIS_SERVICE=$redis_service
REDIS_PORT=$redis_port

SENTINEL_KIND=$sentinel_kind
SENTINEL_WORKLOAD=$sentinel_workload
SENTINEL_SERVICE=$sentinel_service
SENTINEL_LABEL_SELECTOR=$sentinel_selector
SENTINEL_MASTER_NAME=$sentinel_master_name
SENTINEL_PORT=$sentinel_port

HAPROXY_DEPLOYMENT=$haproxy_deployment
HAPROXY_SERVICE=$haproxy_service
HAPROXY_LABEL_SELECTOR=$haproxy_selector
HAPROXY_PORT=$haproxy_port

PORTAL_SERVICE=$portal_service
PORTAL_URL=$portal_url
PORTAL_READYZ_PATH=/readyz

ALERT_STATE_DIR=$ALERT_STATE_DIR
ALERT_COOLDOWN_SECONDS=$cooldown

SMTP_HOST=$smtp_host
SMTP_PORT=$smtp_port
SMTP_TLS=$smtp_tls
SMTP_USER=$smtp_user
SMTP_PASS=$smtp_pass
SMTP_FROM=$smtp_from
SMTP_TO=$smtp_to
EOF

  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"

  echo "Wrote smart environment file: $ENV_FILE"
  echo
  echo "Detected:"
  echo "  Namespace:             $ns"
  echo "  App Deployment:        $app_deployment"
  echo "  App Selector:          $app_selector"
  echo "  Redis StatefulSet:     $redis_statefulset"
  echo "  Redis Selector:        $redis_selector"
  echo "  Sentinel:              $sentinel_kind/$sentinel_workload"
  echo "  Sentinel Selector:     $sentinel_selector"
  echo "  Sentinel Service:      $sentinel_service"
  echo "  Sentinel Master:       $sentinel_master_name"
  echo "  Redis HAProxy:         $haproxy_deployment"
  echo "  HAProxy Selector:      $haproxy_selector"
  echo "  Redis HAProxy Service: $haproxy_service"
  echo "  Portal Service:        $portal_service"
  echo "  Portal URL:            $portal_url"
}

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    write_env_file
  fi

  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

selector_required() {
  local selector="$1"
  local label="$2"

  if [ -z "$selector" ]; then
    add_problem "$label selector is empty; run --init-env to refresh detection"
    return 1
  fi

  return 0
}

cooldown_active() {
  local key="$1"
  local file="$ALERT_STATE_DIR/$key.last"
  local now
  local last

  mkdir -p "$ALERT_STATE_DIR"
  now="$(date +%s)"

  [ ! -f "$file" ] && return 1

  last="$(cat "$file" 2>/dev/null || echo 0)"

  [ $((now - last)) -lt "$ALERT_COOLDOWN_SECONDS" ]
}

mark_alert_sent() {
  local key="$1"
  mkdir -p "$ALERT_STATE_DIR"
  date +%s > "$ALERT_STATE_DIR/$key.last"
}

send_email() {
  local subject="$1"
  local body="$2"

  if [ -z "${SMTP_HOST:-}" ] || [ "${SMTP_HOST:-}" = "CHANGEME" ] \
    || [ -z "${SMTP_FROM:-}" ] || [ "${SMTP_FROM:-}" = "CHANGEME" ] \
    || [ -z "${SMTP_TO:-}" ] || [ "${SMTP_TO:-}" = "CHANGEME" ]; then
    echo "SMTP settings incomplete. Alert not sent."
    echo "Edit: sudo nano $ENV_FILE"
    return 1
  fi

  SMTP_HOST="$SMTP_HOST" \
  SMTP_PORT="$SMTP_PORT" \
  SMTP_USER="${SMTP_USER:-}" \
  SMTP_PASS="${SMTP_PASS:-}" \
  SMTP_FROM="$SMTP_FROM" \
  SMTP_TO="$SMTP_TO" \
  SMTP_TLS="${SMTP_TLS:-1}" \
  ALERT_SUBJECT="$subject" \
  ALERT_BODY="$body" \
  python3 <<'PY'
import os
import smtplib
from email.message import EmailMessage

host = os.environ["SMTP_HOST"]
port = int(os.environ.get("SMTP_PORT", "587"))
user = os.environ.get("SMTP_USER", "")
password = os.environ.get("SMTP_PASS", "")
sender = os.environ["SMTP_FROM"]
recipients = [x.strip() for x in os.environ["SMTP_TO"].split(",") if x.strip()]
use_tls = os.environ.get("SMTP_TLS", "1") == "1"

msg = EmailMessage()
msg["From"] = sender
msg["To"] = ", ".join(recipients)
msg["Subject"] = os.environ["ALERT_SUBJECT"]
msg.set_content(os.environ["ALERT_BODY"])

with smtplib.SMTP(host, port, timeout=30) as server:
    server.ehlo()
    if use_tls:
        server.starttls()
        server.ehlo()
    if user and user != "CHANGEME":
        server.login(user, password)
    server.send_message(msg)
PY
}

check_cluster_basics() {
  if ! kubectl_ok; then
    add_problem "kubectl is not installed or not usable"
    return
  fi

  add_detail "kubectl client is available."

  if ! cluster_ok; then
    add_problem "Kubernetes API /readyz check failed"
    return
  fi

  add_detail "Kubernetes API /readyz check passed."

  if ! "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    add_problem "Namespace '$NAMESPACE' does not exist"
    return
  fi

  add_detail "Namespace '$NAMESPACE' exists."
}

check_nodes() {
  local bad
  bad="$("$KUBECTL" get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1 " status=" $2}' || true)"

  if [ -n "$bad" ]; then
    add_problem "One or more nodes are not Ready"
    add_detail "$bad"
  else
    add_detail "All Kubernetes nodes are Ready."
  fi
}

check_pods() {
  local bad
  bad="$("$KUBECTL" -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '
    $3 != "Running" && $3 != "Completed" {
      print $1 " ready=" $2 " status=" $3 " restarts=" $4
    }
  ' || true)"

  if [ -n "$bad" ]; then
    add_problem "One or more pods are not healthy"
    add_detail "$bad"
  else
    add_detail "All pods in namespace '$NAMESPACE' are Running or Completed."
  fi
}

check_deployment_ready() {
  local name="$1"
  local label="$2"

  [ -z "$name" ] && {
    add_detail "$label Deployment not detected; skipping."
    return
  }

  local desired ready available
  desired="$("$KUBECTL" -n "$NAMESPACE" get deployment "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  ready="$("$KUBECTL" -n "$NAMESPACE" get deployment "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  available="$("$KUBECTL" -n "$NAMESPACE" get deployment "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"

  desired="${desired:-0}"
  ready="${ready:-0}"
  available="${available:-0}"

  if [ "$desired" != "$ready" ] || [ "$desired" != "$available" ]; then
    add_problem "$label Deployment '$name' is not fully ready"
    add_detail "$label Deployment '$name': desired=$desired ready=$ready available=$available"
  else
    add_detail "$label Deployment '$name' is ready: desired=$desired ready=$ready available=$available."
  fi
}

check_statefulset_ready() {
  local name="$1"
  local label="$2"

  [ -z "$name" ] && {
    add_detail "$label StatefulSet not detected; skipping."
    return
  }

  local desired ready
  desired="$("$KUBECTL" -n "$NAMESPACE" get statefulset "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  ready="$("$KUBECTL" -n "$NAMESPACE" get statefulset "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

  desired="${desired:-0}"
  ready="${ready:-0}"

  if [ "$desired" != "$ready" ]; then
    add_problem "$label StatefulSet '$name' is not fully ready"
    add_detail "$label StatefulSet '$name': desired=$desired ready=$ready"
  else
    add_detail "$label StatefulSet '$name' is ready: desired=$desired ready=$ready."
  fi
}

check_service_endpoints() {
  local svc="$1"
  local label="$2"

  [ -z "$svc" ] && {
    add_detail "$label Service not detected; skipping."
    return
  }

  local endpoints
  endpoints="$("$KUBECTL" -n "$NAMESPACE" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"

  if [ -z "$endpoints" ]; then
    add_problem "$label Service '$svc' has no ready endpoints"
  else
    add_detail "$label Service '$svc' has endpoints: $endpoints"
  fi
}

first_pod_for_selector() {
  local selector="$1"

  [ -z "$selector" ] && return

  "$KUBECTL" -n "$NAMESPACE" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

check_redis() {
  check_statefulset_ready "$REDIS_STATEFULSET" "Redis"
  check_service_endpoints "$REDIS_SERVICE" "Redis"

  selector_required "$REDIS_LABEL_SELECTOR" "Redis" || return

  local pod
  pod="$(first_pod_for_selector "$REDIS_LABEL_SELECTOR")"

  if [ -z "$pod" ]; then
    add_problem "Could not find Redis pod using selector '$REDIS_LABEL_SELECTOR'"
    return
  fi

  local result
  result="$("$KUBECTL" -n "$NAMESPACE" exec "$pod" -- redis-cli -p "$REDIS_PORT" ping 2>&1 || true)"

  if ! printf '%s\n' "$result" | grep -q '^PONG$'; then
    add_problem "Redis ping failed inside pod '$pod'"
    add_detail "$result"
  else
    add_detail "Redis ping succeeded inside pod '$pod'."
  fi
}

check_sentinel() {
  [ -z "${SENTINEL_WORKLOAD:-}" ] && {
    add_detail "Redis Sentinel not detected; skipping."
    return
  }

  if [ "$SENTINEL_KIND" = "deployment" ]; then
    check_deployment_ready "$SENTINEL_WORKLOAD" "Redis Sentinel"
  else
    check_statefulset_ready "$SENTINEL_WORKLOAD" "Redis Sentinel"
  fi

  check_service_endpoints "$SENTINEL_SERVICE" "Redis Sentinel"

  selector_required "$SENTINEL_LABEL_SELECTOR" "Redis Sentinel" || return

  local pod
  pod="$(first_pod_for_selector "$SENTINEL_LABEL_SELECTOR")"

  if [ -z "$pod" ]; then
    add_problem "Could not find Sentinel pod using selector '$SENTINEL_LABEL_SELECTOR'"
    return
  fi

  local ping_result
  ping_result="$("$KUBECTL" -n "$NAMESPACE" exec "$pod" -- redis-cli -p "$SENTINEL_PORT" ping 2>&1 || true)"

  if ! printf '%s\n' "$ping_result" | grep -q '^PONG$'; then
    add_problem "Redis Sentinel ping failed inside pod '$pod'"
    add_detail "$ping_result"
    return
  fi

  add_detail "Redis Sentinel ping succeeded inside pod '$pod'."

  local master_addr
  master_addr="$("$KUBECTL" -n "$NAMESPACE" exec "$pod" -- redis-cli -p "$SENTINEL_PORT" sentinel get-master-addr-by-name "$SENTINEL_MASTER_NAME" 2>&1 || true)"

  if [ -z "$master_addr" ] || printf '%s\n' "$master_addr" | grep -qiE 'ERR|NOAUTH|Could not connect|Connection refused|DENIED'; then
    add_problem "Redis Sentinel master lookup failed for '$SENTINEL_MASTER_NAME'"
    add_detail "$master_addr"
  else
    add_detail "Redis Sentinel master lookup succeeded for '$SENTINEL_MASTER_NAME':
$master_addr"
  fi
}

check_haproxy() {
  [ -z "${HAPROXY_DEPLOYMENT:-}" ] && {
    add_detail "Redis HAProxy not detected; skipping."
    return
  }

  check_deployment_ready "$HAPROXY_DEPLOYMENT" "Redis HAProxy"
  check_service_endpoints "$HAPROXY_SERVICE" "Redis HAProxy"

  selector_required "$HAPROXY_LABEL_SELECTOR" "Redis HAProxy" || return

  local pod
  pod="$(first_pod_for_selector "$HAPROXY_LABEL_SELECTOR")"

  if [ -z "$pod" ]; then
    add_problem "Could not find Redis HAProxy pod using selector '$HAPROXY_LABEL_SELECTOR'"
    return
  fi

  add_detail "Redis HAProxy pod detected: $pod"
}

check_all_services() {
  local services
  services="$("$KUBECTL" -n "$NAMESPACE" get svc --no-headers 2>/dev/null || true)"

  add_detail "Services:
$services"

  while read -r svc _; do
    [ -z "$svc" ] && continue
    check_service_endpoints "$svc" "Service"
  done <<< "$services"
}

check_pvcs() {
  local bad
  bad="$("$KUBECTL" -n "$NAMESPACE" get pvc --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1 " status=" $2}' || true)"

  if [ -n "$bad" ]; then
    add_problem "One or more PVCs are not Bound"
    add_detail "$bad"
  else
    add_detail "All PVCs in namespace '$NAMESPACE' are Bound."
  fi
}

check_portal_readyz() {
  [ -z "${PORTAL_URL:-}" ] && {
    add_problem "Portal URL was not detected"
    return
  }

  local url="${PORTAL_URL}${PORTAL_READYZ_PATH}"
  local response
  local code

  response="$(curl -sS -m 10 -w '\nHTTP_CODE=%{http_code}' "$url" 2>&1 || true)"
  code="$(printf '%s\n' "$response" | awk -F= '/HTTP_CODE=/{print $2}')"

  if [ "$code" != "200" ]; then
    add_problem "Portal readyz check failed at $url"
    add_detail "$response"
    return
  fi

  if ! printf '%s\n' "$response" | grep -qi '"redis":"ok"'; then
    add_problem "Portal readyz did not confirm Redis status as ok"
    add_detail "$response"
    return
  fi

  add_detail "Portal readyz check passed at $url."
  add_detail "$response"
}

build_alert_body() {
  {
    echo "OTP Relay K3s health monitor detected a problem."
    echo
    echo "Host: $HOSTNAME_FQDN"
    echo "Time: $NOW_UTC"
    echo "Namespace: $NAMESPACE"
    echo
    echo "Problems:"
    printf ' - %s\n' "${PROBLEMS[@]}"
    echo
    echo "Detected configuration:"
    echo "APP_DEPLOYMENT=$APP_DEPLOYMENT"
    echo "APP_LABEL_SELECTOR=$APP_LABEL_SELECTOR"
    echo "REDIS_STATEFULSET=$REDIS_STATEFULSET"
    echo "REDIS_LABEL_SELECTOR=$REDIS_LABEL_SELECTOR"
    echo "REDIS_SERVICE=$REDIS_SERVICE"
    echo "SENTINEL_KIND=$SENTINEL_KIND"
    echo "SENTINEL_WORKLOAD=$SENTINEL_WORKLOAD"
    echo "SENTINEL_LABEL_SELECTOR=$SENTINEL_LABEL_SELECTOR"
    echo "SENTINEL_SERVICE=$SENTINEL_SERVICE"
    echo "HAPROXY_DEPLOYMENT=$HAPROXY_DEPLOYMENT"
    echo "HAPROXY_LABEL_SELECTOR=$HAPROXY_LABEL_SELECTOR"
    echo "HAPROXY_SERVICE=$HAPROXY_SERVICE"
    echo "PORTAL_SERVICE=$PORTAL_SERVICE"
    echo "PORTAL_URL=$PORTAL_URL"
    echo
    echo "Details:"
    printf '%s\n\n' "${DETAILS[@]}"
    echo
    echo "Nodes:"
    "$KUBECTL" get nodes -o wide 2>&1 || true
    echo
    echo "Pods:"
    "$KUBECTL" -n "$NAMESPACE" get pods -o wide 2>&1 || true
    echo
    echo "Deployments:"
    "$KUBECTL" -n "$NAMESPACE" get deployments -o wide 2>&1 || true
    echo
    echo "StatefulSets:"
    "$KUBECTL" -n "$NAMESPACE" get statefulsets -o wide 2>&1 || true
    echo
    echo "Services:"
    "$KUBECTL" -n "$NAMESPACE" get svc -o wide 2>&1 || true
    echo
    echo "Endpoints:"
    "$KUBECTL" -n "$NAMESPACE" get endpoints 2>&1 || true
    echo
    echo "PVCs:"
    "$KUBECTL" -n "$NAMESPACE" get pvc 2>&1 || true
  }
}

run_monitor() {
  load_env

  check_cluster_basics

  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    check_nodes
    check_pods
    check_deployment_ready "$APP_DEPLOYMENT" "App"
    check_deployment_ready "$MONITOR_DEPLOYMENT" "Monitor"
    check_redis
    check_sentinel
    check_haproxy
    check_all_services
    check_pvcs
    check_portal_readyz
  fi

  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    echo "OK: OTP Relay K3s deployment is healthy."
    exit 0
  fi

  local subject
  local body

  subject="[ALERT] OTP Relay K3s health issue on ${HOSTNAME_FQDN}"
  body="$(build_alert_body)"

  echo "$body"

  if cooldown_active "health-alert"; then
    echo "Alert cooldown is active. Email not sent."
    exit 2
  fi

  if send_email "$subject" "$body"; then
    mark_alert_sent "health-alert"
    echo "Alert email sent."
  else
    echo "Failed to send alert email."
    exit 3
  fi

  exit 2
}

case "${1:-}" in
  --init-env|--discover|--refresh-env)
    write_env_file
    ;;
  --print-env)
    write_env_file
    cat "$ENV_FILE"
    ;;
  --help|-h)
    echo "Usage:"
    echo "  sudo $0 --init-env"
    echo "  sudo $0"
    echo "  sudo $0 --print-env"
    ;;
  *)
    run_monitor
    ;;
esac
