#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

image_distribution_server_ip() {
  if [ -n "${IMAGE_DISTRIBUTION_HOST:-}" ]; then
    printf '%s\n' "$IMAGE_DISTRIBUTION_HOST"
    return 0
  fi

  if [ -n "${SERVER_IP:-}" ] && [ "$SERVER_IP" != "127.0.0.1" ]; then
    printf '%s\n' "$SERVER_IP"
    return 0
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

sanitize_k8s_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-48
}

wait_for_importer_logs() {
  local namespace="$1"
  local selector="$2"
  local expected="$3"
  local timeout_seconds="$4"
  local start_ts
  local now_ts
  local elapsed=0
  local last_progress=0

  start_ts="$(date +%s)"
  log "waiting for image importer completion on $expected node(s); timeout=${timeout_seconds}s"

  while true; do
    local pod_rows=""
    local completed_nodes=""
    local completed_count=0

    pod_rows="$(
      k3s kubectl get pods -n "$namespace" -l "$selector" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || true
    )"

    while read -r pod node phase; do
      [ -n "$pod" ] || continue
      if k3s kubectl logs -n "$namespace" "$pod" -c importer --tail=-1 2>/dev/null | grep -q 'IMAGE_IMPORT_DONE'; then
        completed_nodes="${completed_nodes}${node} "
        completed_count=$((completed_count + 1))
      fi
    done <<EOF_IMPORTER_ROWS
$pod_rows
EOF_IMPORTER_ROWS

    completed_nodes="$(printf '%s' "$completed_nodes" | xargs || true)"

    if [ "$completed_count" -ge "$expected" ]; then
      log "image importer completed on $completed_count/$expected node(s): ${completed_nodes:-unknown}"
      return 0
    fi

    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))

    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      warn "image importer completed on $completed_count/$expected node(s): ${completed_nodes:-none}"
      warn "image importer pod status:"
      k3s kubectl get pods -n "$namespace" -l "$selector" -o wide >&2 || true

      warn "image importer logs by pod:"
      while read -r pod node phase; do
        [ -n "$pod" ] || continue
        warn "----- importer pod=$pod node=${node:-unknown} phase=${phase:-unknown} -----"
        k3s kubectl logs -n "$namespace" "$pod" -c importer --tail=160 >&2 || true
      done <<EOF_IMPORTER_ROWS
$pod_rows
EOF_IMPORTER_ROWS

      return 1
    fi

    if [ $((elapsed - last_progress)) -ge 30 ]; then
      last_progress="$elapsed"
      log "still waiting for image importer completion after ${elapsed}s: $completed_count/$expected node(s) done"
      k3s kubectl get pods -n "$namespace" -l "$selector" -o wide || true
    fi

    sleep 3
  done
}

distribute_image_tar_to_all_nodes() {
  local image_name="$1"
  local tar_path="$2"
  local label_suffix="$3"

  [ "$DISTRIBUTE_IMAGES_TO_NODES" = "1" ] || {
    log "DISTRIBUTE_IMAGES_TO_NODES=0; skipping cross-node image distribution for $image_name"
    return 0
  }

  [ -f "$tar_path" ] || fatal "image tar does not exist: $tar_path"

  local node_count
  node_count="$(k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {count++} END {print count+0}')"
  node_count="$(printf '%s' "$node_count" | xargs)"
  node_count="${node_count:-0}"

  if [ "$node_count" -le 1 ]; then
    log "single ready node detected; no cross-node image distribution needed for $image_name"
    return 0
  fi

  local serve_ip
  serve_ip="$(image_distribution_server_ip | xargs)"
  [ -n "$serve_ip" ] || fatal "could not determine image distribution host IP"

  local serve_dir
  local tar_name
  local ds_name
  local app_label
  local http_pid
  local http_log

  serve_dir="$(dirname "$tar_path")"
  tar_name="$(basename "$tar_path")"
  ds_name="image-importer-$(sanitize_k8s_name "$label_suffix")"
  app_label="otp-relay-image-importer-${label_suffix}"
  http_log="$GENERATED_DIR/${ds_name}-http.log"

  log "distributing image $image_name to $node_count ready K3s node(s) without a registry"
  log "image tar path: $tar_path"
  log "temporary image tar URL: http://${serve_ip}:${IMAGE_DISTRIBUTION_PORT}/${tar_name}"
  log "starting temporary image tar server on ${serve_ip}:${IMAGE_DISTRIBUTION_PORT}"

  python3 -m http.server "$IMAGE_DISTRIBUTION_PORT" --bind 0.0.0.0 --directory "$serve_dir" >"$http_log" 2>&1 &
  http_pid="$!"

  sleep 2

  if ! kill -0 "$http_pid" >/dev/null 2>&1; then
    cat "$http_log" >&2 || true
    fatal "failed to start temporary image distribution server on port $IMAGE_DISTRIBUTION_PORT"
  fi

  log "temporary image tar server started with pid $http_pid; log=$http_log"

  cleanup_image_importer() {
    log "cleaning up image importer resources for $image_name"
    k3s kubectl delete daemonset "$ds_name" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

    if [ -n "${http_pid:-}" ]; then
      kill "$http_pid" >/dev/null 2>&1 || true
      wait "$http_pid" >/dev/null 2>&1 || true
    fi
  }

  log "removing any previous image importer DaemonSet: $NAMESPACE/$ds_name"
  k3s kubectl delete daemonset "$ds_name" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

  log "creating image importer DaemonSet $NAMESPACE/$ds_name"
  cat <<EOF_IMPORTER | k3s kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $ds_name
  namespace: $NAMESPACE
  labels:
    app: $app_label
spec:
  selector:
    matchLabels:
      app: $app_label
  template:
    metadata:
      labels:
        app: $app_label
    spec:
      hostNetwork: true
      tolerations:
        - operator: Exists
      restartPolicy: Always
      containers:
        - name: importer
          image: $IMAGE_IMPORTER_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          command:
            - sh
            - -c
            - |
              set -eu
              echo "Downloading image tar for $image_name from http://$serve_ip:$IMAGE_DISTRIBUTION_PORT/$tar_name"
              wget -O /tmp/image.tar "http://$serve_ip:$IMAGE_DISTRIBUTION_PORT/$tar_name"
              /host-bin/k3s ctr images import /tmp/image.tar
              rm -f /tmp/image.tar
              echo IMAGE_IMPORT_DONE
              sleep 3600
          volumeMounts:
            - name: k3s-bin
              mountPath: /host-bin/k3s
              readOnly: true
            - name: containerd-sock
              mountPath: /run/k3s/containerd/containerd.sock
      volumes:
        - name: k3s-bin
          hostPath:
            path: /usr/local/bin/k3s
            type: File
        - name: containerd-sock
          hostPath:
            path: /run/k3s/containerd/containerd.sock
            type: Socket
EOF_IMPORTER

  log "waiting for image importer DaemonSet rollout; this can take a few minutes on fresh worker nodes"
  if ! k3s kubectl rollout status daemonset/"$ds_name" -n "$NAMESPACE" --timeout=180s; then
    warn "image importer DaemonSet did not become ready; dumping diagnostics"
    k3s kubectl get pods -n "$NAMESPACE" -l "app=$app_label" -o wide || true
    k3s kubectl describe daemonset "$ds_name" -n "$NAMESPACE" || true
    cleanup_image_importer
    fatal "image importer DaemonSet did not become ready"
  fi
  log "image importer DaemonSet rollout completed"

  if ! wait_for_importer_logs "$NAMESPACE" "app=$app_label" "$node_count" 180; then
    warn "image import did not complete on every expected importer pod; dumping logs"
    k3s kubectl get pods -n "$NAMESPACE" -l "app=$app_label" -o wide || true
    k3s kubectl logs -n "$NAMESPACE" -l "app=$app_label" --tail=100 --prefix=true || true
    cleanup_image_importer
    fatal "image import did not complete on every expected importer pod for $image_name; see node-specific importer logs above"
  fi

  cleanup_image_importer
  log "image $image_name imported on all ready K3s nodes"
}
