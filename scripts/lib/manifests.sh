#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

apply_runtime_configmap() {
  if [ -n "${MANIFEST_DIR:-}" ] && [ -f "$MANIFEST_DIR/configmap.yaml" ]; then
    log "applying rendered ConfigMap manifest from repository template"
    k3s kubectl apply -f "$MANIFEST_DIR/configmap.yaml"
    return 0
  fi

  warn "rendered configmap.yaml is not available; falling back to generated live ConfigMap"
  k3s kubectl create configmap otp-relay-config \
    --namespace "$NAMESPACE" \
    --from-literal=CLAIM_EXPIRY_SEC="$CLAIM_EXPIRY_SEC" \
    --from-literal=OTP_DISPLAY_SEC="$OTP_DISPLAY_SEC" \
    --from-literal=CONCURRENT_RISK_SEC="$CONCURRENT_RISK_SEC" \
    --from-literal=OTP_RELAY_DATA_DIR="$OTP_RELAY_DATA_DIR" \
    --from-literal=USERS_EXCEL_PATH="$USERS_EXCEL_PATH" \
    --from-literal=AUDIT_LOG_PATH="$AUDIT_LOG_PATH" \
    --from-literal=PHONE_IP="$PHONE_IP" \
    --from-literal=PHONE_INTERFACE="$PHONE_INTERFACE" \
    --from-literal=PHONE_PING_INTERVAL="$PHONE_PING_INTERVAL" \
    --from-literal=PHONE_OFFLINE_THRESHOLD="$PHONE_OFFLINE_THRESHOLD" \
    --from-literal=SERVER_HOSTNAME="$SERVER_HOSTNAME" \
    --from-literal=SERVER_IP="$SERVER_IP" \
    --from-literal=PORTAL_URL="$PORTAL_URL" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
}

render_manifests() {
  log "rendering runtime values into staged repository manifests"
  MANIFEST_DIR="$MANIFEST_DIR" \
  NAMESPACE="$NAMESPACE" \
  APP_IMAGE="$APP_IMAGE" \
  MONITOR_IMAGE="$MONITOR_IMAGE" \
  SERVICE_TYPE="$SERVICE_TYPE" \
  SERVICE_NODE_PORT="$SERVICE_NODE_PORT" \
  LOADBALANCER_IP="$LOADBALANCER_IP" \
  TLS_ENABLED="$TLS_ENABLED" \
  TLS_HOST="$TLS_HOST" \
  TLS_SECRET_NAME="$TLS_SECRET_NAME" \
  PVC_STORAGE_CLASS="$PVC_STORAGE_CLASS" \
  PVC_SIZE="$PVC_SIZE" \
  REPLICA_COUNT="$REPLICA_COUNT" \
  APP_NODE_SELECTOR_KEY="$APP_NODE_SELECTOR_KEY" \
  APP_NODE_SELECTOR_VALUE="$APP_NODE_SELECTOR_VALUE" \
  MONITOR_NODE_SELECTOR_KEY="$MONITOR_NODE_SELECTOR_KEY" \
  MONITOR_NODE_SELECTOR_VALUE="$MONITOR_NODE_SELECTOR_VALUE" \
  REDIS_NODE_SELECTOR_KEY="$REDIS_NODE_SELECTOR_KEY" \
  REDIS_NODE_SELECTOR_VALUE="$REDIS_NODE_SELECTOR_VALUE" \
  PHONE_IP="$PHONE_IP" \
  PHONE_INTERFACE="$PHONE_INTERFACE" \
  PHONE_PING_INTERVAL="$PHONE_PING_INTERVAL" \
  PHONE_OFFLINE_THRESHOLD="$PHONE_OFFLINE_THRESHOLD" \
  PHONE_ARP_COUNT="$PHONE_ARP_COUNT" \
  PHONE_ARP_TIMEOUT="$PHONE_ARP_TIMEOUT" \
  MONITOR_METRICS_PORT="$MONITOR_METRICS_PORT" \
  OTP_RELAY_DATA_DIR="$OTP_RELAY_DATA_DIR" \
  USERS_EXCEL_PATH="$USERS_EXCEL_PATH" \
  AUDIT_LOG_PATH="$AUDIT_LOG_PATH" \
  CLAIM_EXPIRY_SEC="$CLAIM_EXPIRY_SEC" \
  OTP_DISPLAY_SEC="$OTP_DISPLAY_SEC" \
  CONCURRENT_RISK_SEC="$CONCURRENT_RISK_SEC" \
  SERVER_HOSTNAME="$SERVER_HOSTNAME" \
  SERVER_IP="$SERVER_IP" \
  PORTAL_URL="$PORTAL_URL" \
  REDIS_ENABLED="$REDIS_ENABLED" \
  REDIS_URL="$REDIS_URL" \
  REDIS_REQUIRED="$REDIS_REQUIRED" \
  REDIS_STORAGE_CLASS="$REDIS_STORAGE_CLASS" \
  REDIS_SIZE="$REDIS_SIZE" \
  NFS_ENABLED="$NFS_ENABLED" \
  NFS_SERVER="$NFS_SERVER" \
  NFS_PATH="$NFS_PATH" \
  NFS_STORAGE_CLASS="$NFS_STORAGE_CLASS" \
  NFS_PV_NAME="$NFS_PV_NAME" \
  NFS_MOUNT_OPTIONS="$NFS_MOUNT_OPTIONS" \
  python3 - <<'PY_RENDER_MANIFESTS'
import os
import re
from pathlib import Path

manifest_dir = Path(os.environ["MANIFEST_DIR"])
namespace = os.environ["NAMESPACE"]


def read(name: str) -> str:
    return (manifest_dir / name).read_text(encoding="utf-8")


def write(name: str, text: str) -> None:
    (manifest_dir / name).write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")


def replace_namespace(text: str) -> str:
    return re.sub(r"(\n  namespace: )otp-relay(\n)", rf"\g<1>{namespace}\2", text)


def set_data_value(text: str, key: str, value: str) -> str:
    escaped = value.replace('"', '\\"')
    line = f'  {key}: "{escaped}"'
    pattern = rf"^  {re.escape(key)}: .*?$"
    if re.search(pattern, text, flags=re.MULTILINE):
        return re.sub(pattern, line, text, flags=re.MULTILINE)
    if not text.endswith("\n"):
        text += "\n"
    return text + line + "\n"


def set_replicas(text: str, replicas: str) -> str:
    if re.search(r"^  replicas: .*$", text, flags=re.MULTILINE):
        return re.sub(r"^  replicas: .*$", f"  replicas: {replicas}", text, flags=re.MULTILINE)
    return text.replace("spec:\n", f"spec:\n  replicas: {replicas}\n", 1)


def set_app_strategy(text: str) -> str:
    replacement = (
        "  strategy:\n"
        "    type: RollingUpdate\n"
        "    rollingUpdate:\n"
        "      maxUnavailable: 0\n"
        "      maxSurge: 1\n"
        "  template:"
    )
    if re.search(r"  strategy:\n(?:    .*\n)+?  template:", text):
        return re.sub(r"  strategy:\n(?:    .*\n)+?  template:", replacement, text)
    return text.replace("  template:", replacement, 1)


def set_recreate_strategy(text: str) -> str:
    replacement = "  strategy:\n    type: Recreate\n  template:"
    if re.search(r"  strategy:\n(?:    .*\n)+?  template:", text):
        return re.sub(r"  strategy:\n(?:    .*\n)+?  template:", replacement, text)
    return text.replace("  template:", replacement, 1)


def set_first_image(text: str, image: str) -> str:
    return re.sub(r"(\n\s*image: ).*", rf"\g<1>{image}", text, count=1)

def set_volume_mount_path(text: str, mount_path: str) -> str:
    return re.sub(r"(\n\s*mountPath: ).*", rf"\g<1>{mount_path}", text)


def remove_nodesel(text: str) -> str:
    return re.sub(r"\n      nodeSelector:\n(?:        .+\n)+", "\n", text)


def add_nodesel(text: str, key: str, value: str) -> str:
    text = remove_nodesel(text)
    if not key:
        return text
    block = f"      nodeSelector:\n        {key}: \"{value}\"\n"
    return text.replace("    spec:\n", "    spec:\n" + block, 1)

# Namespace
if (manifest_dir / "namespace.yaml").exists():
    write("namespace.yaml", f"apiVersion: v1\nkind: Namespace\nmetadata:\n  name: {namespace}\n")

# ConfigMap
if (manifest_dir / "configmap.yaml").exists():
    text = replace_namespace(read("configmap.yaml"))
    values = {
        "CLAIM_EXPIRY_SEC": os.environ["CLAIM_EXPIRY_SEC"],
        "OTP_DISPLAY_SEC": os.environ["OTP_DISPLAY_SEC"],
        "CONCURRENT_RISK_SEC": os.environ["CONCURRENT_RISK_SEC"],
        "OTP_RELAY_DATA_DIR": os.environ["OTP_RELAY_DATA_DIR"],
        "USERS_EXCEL_PATH": os.environ["USERS_EXCEL_PATH"],
        "AUDIT_LOG_PATH": os.environ["AUDIT_LOG_PATH"],
        "PHONE_IP": os.environ["PHONE_IP"],
        "PHONE_INTERFACE": os.environ["PHONE_INTERFACE"],
        "PHONE_PING_INTERVAL": os.environ["PHONE_PING_INTERVAL"],
        "PHONE_OFFLINE_THRESHOLD": os.environ["PHONE_OFFLINE_THRESHOLD"],
        "PHONE_ARP_COUNT": os.environ["PHONE_ARP_COUNT"],
        "PHONE_ARP_TIMEOUT": os.environ["PHONE_ARP_TIMEOUT"],
        "MONITOR_METRICS_PORT": os.environ["MONITOR_METRICS_PORT"],
        "SERVER_HOSTNAME": os.environ["SERVER_HOSTNAME"],
        "SERVER_IP": os.environ["SERVER_IP"],
        "PORTAL_URL": os.environ["PORTAL_URL"],
    }
    for key, value in values.items():
        text = set_data_value(text, key, value)
    write("configmap.yaml", text)

# App PVC and optional static NFS PV. This renderer does not delete or migrate storage.
if (manifest_dir / "pvc.yaml").exists():
    text = replace_namespace(read("pvc.yaml"))
    text = re.sub(r"\n  storageClassName: .*", "", text)
    text = re.sub(r"(\n      storage: ).*", rf"\g<1>{os.environ['PVC_SIZE']}", text)

    if os.environ.get("NFS_ENABLED") == "1":
        text = re.sub(r"    - ReadWriteOnce", "    - ReadWriteMany", text)
        text = re.sub(r"\n  volumeName: .*", "", text)
        text = text.replace("spec:\n", f"spec:\n  volumeName: {os.environ['NFS_PV_NAME']}\n", 1)
    else:
        text = re.sub(r"    - ReadWriteMany", "    - ReadWriteOnce", text)
        text = re.sub(r"\n  volumeName: .*", "", text)

    storage_class = os.environ.get("PVC_STORAGE_CLASS", "")
    if storage_class:
        text = text.replace("  accessModes:\n", f"  storageClassName: {storage_class}\n  accessModes:\n", 1)
    write("pvc.yaml", text)

if (manifest_dir / "pv-nfs.yaml").exists():
    if os.environ.get("NFS_ENABLED") == "1":
        text = read("pv-nfs.yaml")
        text = re.sub(r"^  name: .*$", f"  name: {os.environ['NFS_PV_NAME']}", text, flags=re.MULTILINE)
        text = re.sub(r"(\n    storage: ).*", rf"\g<1>{os.environ['PVC_SIZE']}", text)
        text = re.sub(r"(\n  storageClassName: ).*", rf"\g<1>{os.environ['NFS_STORAGE_CLASS']}", text)
        opts = [x.strip() for x in os.environ.get("NFS_MOUNT_OPTIONS", "").split(",") if x.strip()]
        mount_block = ""
        if opts:
            mount_block = "  mountOptions:\n" + "".join(f"    - {opt}\n" for opt in opts)
        text = re.sub(r"\n  mountOptions:\n(?:    - .*\n)+", "\n" + mount_block, text)
        text = re.sub(r"(\n    server: ).*", rf"\g<1>{os.environ['NFS_SERVER']}", text)
        text = re.sub(r"(\n    path: ).*", rf"\g<1>{os.environ['NFS_PATH']}", text)
        write("pv-nfs.yaml", text)
    else:
        (manifest_dir / "pv-nfs.yaml").unlink()

# App deployment
if (manifest_dir / "deployment.yaml").exists():
    text = replace_namespace(read("deployment.yaml"))
    text = set_replicas(text, os.environ["REPLICA_COUNT"])
    text = set_app_strategy(text)
    text = set_first_image(text, os.environ["APP_IMAGE"])
    text = set_volume_mount_path(text, os.environ["OTP_RELAY_DATA_DIR"])
    text = add_nodesel(text, os.environ.get("APP_NODE_SELECTOR_KEY", ""), os.environ.get("APP_NODE_SELECTOR_VALUE", ""))

    text = re.sub(r"\n            - name: REDIS_URL\n              value: .*", "", text)
    text = re.sub(r"\n            - name: REDIS_REQUIRED\n              value: .*", "", text)
    if os.environ.get("REDIS_ENABLED") == "1":
        redis_env = (
            f"            - name: REDIS_URL\n"
            f"              value: {os.environ['REDIS_URL']}\n"
            f"            - name: REDIS_REQUIRED\n"
            f"              value: \"{os.environ['REDIS_REQUIRED']}\"\n"
        )
        text = text.replace("            - name: SMS_SECRET_TOKEN\n", redis_env + "            - name: SMS_SECRET_TOKEN\n", 1)
    write("deployment.yaml", text)

# Monitor deployment: monitor remains required and single-replica.
if (manifest_dir / "deployment-monitor.yaml").exists():
    text = replace_namespace(read("deployment-monitor.yaml"))
    text = set_replicas(text, "1")
    text = set_recreate_strategy(text)
    text = set_first_image(text, os.environ["MONITOR_IMAGE"])
    text = set_volume_mount_path(text, os.environ["OTP_RELAY_DATA_DIR"])
    text = add_nodesel(text, os.environ.get("MONITOR_NODE_SELECTOR_KEY", ""), os.environ.get("MONITOR_NODE_SELECTOR_VALUE", ""))
    write("deployment-monitor.yaml", text)

# Monitor metrics Service. This is internal-only and is selected by
# k8s/observability/servicemonitor-otp-monitor.yaml.
if (manifest_dir / "monitor-service.yaml").exists():
    text = replace_namespace(read("monitor-service.yaml"))
    write("monitor-service.yaml", text)

# Service
if (manifest_dir / "service.yaml").exists():
    text = replace_namespace(read("service.yaml"))
    text = re.sub(r"^  type: .*$", f"  type: {os.environ['SERVICE_TYPE']}", text, flags=re.MULTILINE)
    text = re.sub(r"\n  loadBalancerIP: .*", "", text)
    text = re.sub(r"\n      nodePort: .*", "", text)
    if os.environ["SERVICE_TYPE"] == "LoadBalancer" and os.environ.get("LOADBALANCER_IP"):
        text = text.replace(f"  type: {os.environ['SERVICE_TYPE']}\n", f"  type: {os.environ['SERVICE_TYPE']}\n  loadBalancerIP: {os.environ['LOADBALANCER_IP']}\n", 1)
    if os.environ["SERVICE_TYPE"] == "NodePort":
        text = text.replace("      targetPort: 8000\n", f"      targetPort: 8000\n      nodePort: {os.environ['SERVICE_NODE_PORT']}\n", 1)
    write("service.yaml", text)

# Redis HA manifests.
redis_manifests = [
    "redis-service.yaml",
    "redis-configmap.yaml",
    "redis-statefulset.yaml",
    "redis-sentinel-configmap.yaml",
    "redis-sentinel-deployment.yaml",
    "redis-sentinel-service.yaml",
    "redis-haproxy-configmap.yaml",
    "redis-haproxy-deployment.yaml",
    "redis-pdb.yaml",
    "redis-sentinel-pdb.yaml",
    "redis-haproxy-pdb.yaml",
]
for name in redis_manifests:
    path = manifest_dir / name
    if path.exists():
        text = replace_namespace(read(name))
        if name == "redis-statefulset.yaml":
            text = add_nodesel(text, os.environ.get("REDIS_NODE_SELECTOR_KEY", ""), os.environ.get("REDIS_NODE_SELECTOR_VALUE", ""))
            text = re.sub(r"\n        storageClassName: .*", "", text)
            redis_storage_class = os.environ.get("REDIS_STORAGE_CLASS", "")
            if redis_storage_class:
                text = text.replace("        accessModes:\n", f"        storageClassName: {redis_storage_class}\n        accessModes:\n", 1)
            text = re.sub(r"(\n            storage: ).*", rf"\g<1>{os.environ['REDIS_SIZE']}", text)
        elif name in ["redis-sentinel-deployment.yaml", "redis-haproxy-deployment.yaml"]:
            text = add_nodesel(text, os.environ.get("REDIS_NODE_SELECTOR_KEY", ""), os.environ.get("REDIS_NODE_SELECTOR_VALUE", ""))
        write(name, text)

# Ingress
if (manifest_dir / "ingress.yaml").exists():
    text = replace_namespace(read("ingress.yaml"))
    ingress_enabled = os.environ.get("INGRESS_ENABLED", "1") == "1"
    tls_enabled = os.environ.get("TLS_ENABLED") == "1"
    tls_host = os.environ.get("TLS_HOST", "").strip()
    tls_secret_name = os.environ.get("TLS_SECRET_NAME", "otp-relay-tls").strip()

    if ingress_enabled and not tls_host:
        raise SystemExit("TLS_HOST is required when INGRESS_ENABLED=1")
    if tls_enabled and not tls_host:
        raise SystemExit("TLS_HOST is required when TLS_ENABLED=1")

    if tls_host:
        # Replace both empty and populated rule host lines, for example:
        #   - host:
        #   - host: old.example
        text = re.sub(
            r"^(\s*-\s*host:)\s*.*$",
            rf"\1 {tls_host}",
            text,
            flags=re.MULTILINE,
        )

    if tls_enabled:
        # Rebuild the TLS section instead of trying to patch possibly empty
        # template values such as '- ""' or '-'. This avoids invalid ingress
        # output when the template host is blank.
        text = re.sub(r"\n  tls:\n(?:    .+\n)+", "\n", text)
        text = text.rstrip() + (
            "\n  tls:\n"
            "    - hosts:\n"
            f"        - {tls_host}\n"
            f"      secretName: {tls_secret_name}\n"
        )
    else:
        text = re.sub(r"\n  tls:\n(?:    .+\n)+", "\n", text)

    write("ingress.yaml", text)
PY_RENDER_MANIFESTS
}

apply_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    k3s kubectl apply -f "$file"
  fi
}
