# Current Architecture and SCH Alignment

## Purpose

This document explains the current `k8s-ansible` architecture in the same layered style as the SCH Kubernetes branch.

It is not a deployment runbook. It is the architecture reference for understanding what the project does, why each layer exists, and where this repo intentionally extends the SCH baseline.

Detailed procedures belong in:

```text
docs/deployment/deployment-and-storage-guide.md
docs/operations/operations-and-validation-runbook.md
docs/operations/observability-and-grafana.md
docs/development/build-and-development-guide.md
```

---

## Architecture position

SCH's Kubernetes branch starts with a controlled migration of the existing OTP Relay portal:

```text
working portal
  -> containerized app
  -> K3s deployment
  -> one app replica first
  -> PVC-backed runtime files
  -> Redis added after the in-memory scaling limitation is proven
  -> observability and resilience added in controlled phases
```

This repo keeps that same application model, but it already includes the production-resilience extensions that SCH treats as later-phase work:

```text
SCH baseline
  + Redis-backed shared OTP/admin state
  + multiple app replicas
  + Redis Sentinel and HAProxy
  + NFS/RWX app data storage
  + MetalLB and Traefik ingress
  + Prometheus, Grafana, Loki, and Alloy observability
  + Ansible-based cluster/bootstrap automation
  + explicit repo-sync separated from deployment
```

The correct way to describe this repo is:

```text
SCH Kubernetes baseline plus production-resilience automation.
```

---

## Layer 1: Application model

The OTP Relay application layer contains the user-facing portal, the OTP business flow, and the internal phone monitor.

```text
Browser user
  -> opens portal
  -> claims active OTP session
  -> polls portal for OTP display

iPhone / iOS Shortcut
  -> receives SMS OTP
  -> posts OTP payload to portal endpoint
  -> portal matches OTP to active user/session
  -> browser displays OTP
```

Application components:

| Component | Role |
|---|---|
| FastAPI backend | Serves portal API, static frontend, health endpoints, metrics, and OTP flow |
| React frontend source | `frontend/app.jsx` |
| Generated frontend bundle | `frontend/app.js` |
| Portal help source | `docs/help/` |
| Generated portal help | `frontend/help/` |
| Runtime data mount | `/app/data` |

Runtime files under `/app/data`:

```text
users.xlsx
admin_auth.json
admin_config.json
wizard_progress.json
audit.log
```

OTP values must not be written to disk, committed files, documentation examples, generated manifests, or long-lived logs.

---

## Layer 2: Kubernetes runtime

The Kubernetes runtime layer runs the portal, monitor, Redis, storage mounts, services, and ingress.

Current runtime shape:

```text
Clients / browser / iPhone Shortcut
  -> internal DNS
  -> MetalLB-assigned Traefik LoadBalancer IP
  -> Traefik Ingress
  -> otp-relay Kubernetes Service
  -> FastAPI app pods
  -> Redis HAProxy
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data
```

Current expected test-cluster access model:

```text
Portal host:   srvotptest26.init-db.lan
Grafana host:  grafana-srvotptest26.init-db.lan
Traefik IP:    172.31.11.121
```

Both portal and Grafana should use internal DNS records that point to the same Traefik/MetalLB IP. Traefik routes each request by hostname.

Bare-IP access to the Traefik IP may route to the default portal ingress. That is expected and should not be used to validate Grafana access.

---

## Layer 3: Monitor model

The monitor is required. It is not optional helper code.

The monitor remains internal only:

```text
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
capabilities: NET_RAW
Service: none
Ingress: none
```

The monitor is responsible for:

| Responsibility | Description |
|---|---|
| Phone presence | Checks phone/network presence using ARP-capable networking |
| Audit-log checks | Reads shared audit log for operational state |
| Metrics | Exports monitor metrics for Prometheus |
| Alerts | Sends Telegram operational alerts |

The monitor should run only on a node that has visibility to the phone network.

---

## Layer 4: Shared state and resilience

SCH's initial Kubernetes baseline deliberately starts with one app replica until shared state is introduced.

This repo has already crossed that boundary. Redis is required for the current multi-replica design.

Redis-backed state includes:

```text
OTP claim queue
pending OTP display state
OTP TTL behavior
admin sessions
admin login-attempt / lockout state
```

Current Redis path:

```text
app pods
  -> otp-redis-haproxy:6379
  -> Redis HAProxy
  -> Sentinel-selected Redis master
  -> Redis replicas
```

Why this matters:

```text
Without Redis:
  app pod 1 can own the browser session
  app pod 2 can receive the OTP post
  OTP state can split across pods
  multi-replica app is unsafe

With Redis:
  all app pods share OTP/session state
  multiple app replicas can serve the same business flow
```

Redis StatefulSet and PVC resources must not be silently deleted or recreated during normal updates. Any Redis topology or storage change is a maintenance operation.

---

## Layer 5: Storage model

Application runtime files use NFS/RWX storage.

```text
/app/data
  -> Kubernetes PVC
  -> NFS-backed PV
  -> external NFS server
```

This improves on a simple local-path `ReadWriteOnce` model because the app and monitor do not need to be pinned to the same node just to share files.

Redis storage is separate from app runtime storage. Redis backup and restore expectations require explicit production sign-off before being treated as final.

The architecture document should not hardcode a specific NFS server IP. Runtime truth comes from `.env`, rendered manifests, and the live Kubernetes PV/PVC objects.

---

## Layer 6: Network and access model

The intended access model is Kubernetes-native:

```text
LAN client
  -> internal DNS
  -> MetalLB IP
  -> Traefik
  -> Kubernetes Ingress
  -> Service
  -> Pod
```

Preferred test/prod-style model:

| Function | Recommended access |
|---|---|
| Portal | `srvotptest26.init-db.lan` via Traefik |
| Grafana | `grafana-srvotptest26.init-db.lan` via Traefik |
| Monitor | No external access |
| Redis | Internal cluster access only |
| Prometheus/Loki | Internal or controlled admin access only |

Required DNS records for the current test cluster:

```text
srvotptest26.init-db.lan           A   172.31.11.121
grafana-srvotptest26.init-db.lan   A   172.31.11.121
```

Grafana direct-IP access is not the primary design. The clean model is internal DNS plus Traefik hostname routing.

---

## Layer 7: Observability model

Observability assets live under:

```text
k8s/observability/
```

Observability flow:

```text
Portal /metrics
Monitor /metrics
  -> ServiceMonitor resources
  -> Prometheus
  -> Grafana dashboard

Pod and application logs
  -> Alloy
  -> Loki
  -> Grafana log views
```

Grafana access path:

```text
Browser
  -> http://grafana-srvotptest26.init-db.lan
  -> DNS resolves to 172.31.11.121
  -> Traefik standard Kubernetes Ingress
  -> kube-prometheus-stack-grafana service
  -> Grafana pod
```

Grafana dashboard source model:

```text
Source JSON:  k8s/observability/dashboards/otp-relay-live.json
Generator:    scripts/build_grafana_dashboard_configmap.py
Generated:    k8s/observability/grafana-dashboard-otp-relay-live.yaml
Dashboard UID: otp-relay-live
```

Generated dashboard ConfigMaps should not become the human source of truth. Edit the JSON source and regenerate.

---

## Layer 8: Automation and repo-sync model

SCH's branch uses GitHub Actions as the deployment entry point.

This repo intentionally separates repository synchronization from deployment:

```text
GitHub main
  -> scripts/sync-repo.sh
  -> hard reset local checkout to origin/main
  -> preserve local runtime/generated artifacts
  -> no deployment side effects
  -> operator explicitly runs setup/deploy path when intended
```

The repo-sync script must remain sync-only. It must not:

```text
install K3s
run Helm
run kubectl apply
import images
restart workloads
run Ansible mutation tasks
perform validation that changes the live cluster
```

This is a deliberate safety difference from a push-to-deploy workflow.

---

## Current live-cluster reference

The latest validated fresh-install reference shape is:

```text
Control plane: debian       172.31.11.111
Worker 1:      otp-worker1  172.31.11.154
Worker 2:      otp-worker2  172.31.11.155
Traefik IP:    172.31.11.121
Portal host:   srvotptest26.init-db.lan
Grafana host:  grafana-srvotptest26.init-db.lan
```

Workload position:

```text
otp-relay app:         2 replicas on workers
otp-monitor:           running on control-plane/server node
Redis:                 3 pods across nodes
Redis Sentinel:        3 pods across nodes
Redis HAProxy:         2 replicas
Grafana:               running in observability namespace
Traefik:               LoadBalancer through MetalLB
```

This section is a reference snapshot, not a hardcoded requirement. Runtime truth should always be verified with `kubectl`, `.env`, and rendered manifests.

---

## SCH alignment table

| Area | SCH baseline | Current repo position | Alignment |
|---|---|---|---|
| Application behavior | Preserve working OTP portal behavior | Preserved | Aligned |
| iPhone OTP post | iPhone Shortcut posts received OTP to portal | Preserved | Aligned |
| App replica count | Start with one replica until shared state exists | Multi-replica with Redis shared state | Intentional extension |
| Runtime files | PVC-backed app data | NFS/RWX PVC-backed app data | Improved extension |
| Monitor | Internal host-network monitor | Internal host-network monitor | Aligned |
| Monitor exposure | No Service / no Ingress | No Service / no Ingress | Aligned |
| Redis | Later phase after proving in-memory limitation | Required for validated multi-replica design | Intentional extension |
| Redis HA | Future/production design item | Sentinel + HAProxy implemented | Intentional extension |
| Observability | Prometheus/Grafana/Loki/Alloy direction | Integrated observability automation | Extended |
| Ingress | Kubernetes ingress through internal access path | Traefik + MetalLB ingress | Aligned with extension |
| Workflow | GitHub Actions deploy model | Repo-sync first, explicit deploy second | Intentional divergence |
| Documentation | Phased and simple | Reorganized into layered docs | Aligned in style |

---

## Known gaps and cleanup items

These are the current architecture/documentation gaps to track:

1. Keep `grafana-srvotptest26.init-db.lan` as the current test-cluster Grafana host unless `.env` says otherwise.
2. Get internal DNS records created for both portal and Grafana test hostnames.
3. Keep Grafana documented as standard Kubernetes Ingress through Traefik.
4. Keep destructive resilience-validation detail in operations docs, not the root README.
5. Keep Redis backup/restore expectations explicit and pending until production sign-off.
6. Keep TLS trust status explicit: self-signed, internal trust, or approved certificate.
7. Avoid describing repo-sync as deployment; repo-sync only updates the local checkout.
8. Keep generated files documented as generated, not hand-edited source files.

---

## Sign-off checklist

| Item | Status |
|---|---|
| `.env` is the operator-owned runtime source of truth | Implemented |
| Portal uses Kubernetes Service and Traefik Ingress | Implemented |
| Portal hostname is documented | Implemented |
| Grafana hostname is documented consistently | Implemented |
| App supports multiple replicas through Redis shared state | Implemented |
| Redis Sentinel/HAProxy topology exists | Implemented |
| Redis destructive changes are blocked from normal updates | Required rule |
| App data uses shared RWX/NFS storage | Implemented |
| Monitor remains internal only | Implemented |
| Observability stack is source-driven | Implemented |
| Repo-sync is separated from deployment | Implemented |
| Internal DNS for Grafana test hostname | Pending IT DNS |
| Redis backup/restore is documented | Pending production sign-off |
| Production TLS trust is finalized | Pending |
| Final production LB/VIP/DNS model is approved | Pending |

---

## Architecture rule

Do not remove useful resilience work just to look closer to the SCH starting branch.

Do not add more access modes, automation paths, or validation flows without documenting which layer they belong to.

The project should remain understandable as:

```text
SCH baseline application model
  + clear Kubernetes runtime
  + explicit resilience layer
  + explicit observability layer
  + explicit operator automation layer
```
