# k8s-ansible Repository File Guide

Repository: `psi1703/k8s-ansible`  
Branch documented: `main`  
Purpose: OTP Relay Kubernetes/K3s automation, application source, manifests, observability configuration, and operator documentation.

This document explains what each visible file or file group does, why it exists, and what can break if it is removed or edited incorrectly.

---

## 1. Repository purpose

`k8s-ansible` is the operational repository for deploying OTP Relay on a K3s Kubernetes cluster. The repo combines several layers:

1. **Application source** for the FastAPI OTP Relay portal.
2. **Monitor source** for iPhone/OTP presence and alerting checks.
3. **Frontend source** for the browser portal UI.
4. **Kubernetes manifests** for app, monitor, Redis HA, storage, ingress, PDBs, and services.
5. **Observability configuration** for Prometheus, Grafana, Loki, Alloy, dashboards, and ServiceMonitors.
6. **Installer/orchestration scripts** under `setup.sh`, `install-otp-relay-k8s.sh`, and `scripts/lib/`.
7. **Ansible and libvirt automation** for VM/K3s/NFS provisioning and validation.
8. **Operator documentation** under `docs/`.

Current README states the stack uses K3s, Traefik ingress, FastAPI, React frontend, Redis StatefulSet with Sentinel and HAProxy, NFS-backed storage, monitor pod, Telegram alerts, and Prometheus/Grafana/Loki/Alloy observability.

---

## 2. High-level execution flow

### Normal server-side flow

```text
operator
  -> bash setup.sh
  -> setup.sh loads scripts/lib/*.sh
  -> preflight and environment validation
  -> optional OS/K3s/MetalLB/TLS/observability setup
  -> frontend/help/dashboard generation
  -> image build/import
  -> Kubernetes manifest rendering/application
  -> rollout and health validation
  -> install-report.txt handover
```

### Kubernetes runtime flow

```text
browser
  -> DNS host from TLS_HOST
  -> Traefik ingress
  -> otp-relay service
  -> otp-relay app pods
  -> Redis HAProxy service
  -> Redis Sentinel-managed Redis master/replicas
  -> NFS-backed /app/data for persistent non-OTP runtime data
```

### SMS/OTP flow

```text
iPhone receives SMS
  -> iOS Shortcut posts to /sms-received
  -> FastAPI validates request/token
  -> transient OTP state goes into Redis with TTL
  -> browser polling displays OTP to active user
  -> audit metadata goes to audit.log
```

---

## 3. Top-level files

### `README.md`

**What it does:** Main operator entry point for the repo. It describes the current architecture, access paths, `.env` behavior, NFS expectations, Redis placement, TLS behavior, GitHub Actions behavior, and recommended documentation order.

**Why it is important:** This is the first document operators and managers read. It explains source-of-truth rules such as `.env` for runtime configuration, `frontend/app.jsx` as frontend source, help docs as Markdown source, and Grafana JSON as dashboard source.

**Risk if broken:** Operators may run the wrong workflow, edit generated files instead of sources, or misunderstand production deployment boundaries.

---

### `setup.sh`

**What it does:** Main orchestration entry point for install/update/doctor flows. It should be run as the operator user, not as `sudo bash setup.sh`; scripts use `sudo` internally where required.

**Why it is important:** It gives the repo one controlled operational command and coordinates the modular helper scripts under `scripts/lib/`.

**Risk if broken:** Full installation, update, doctor checks, and operator report generation can fail.

---

### `install-otp-relay-k8s.sh`

**What it does:** Legacy or compatibility installer entry point for the OTP Relay K8s deployment. It sources/uses the helper logic in `scripts/lib/`.

**Why it is important:** Existing workflows or operators may still know this script name. It is also useful as a compatibility wrapper while moving toward cleaner release-bundle deployment.

**Risk if broken:** Old runbooks or existing automation may fail even if `setup.sh` still works.

---

### `main.py`

**What it does:** Python application entry point for the FastAPI OTP Relay portal container. It wires the app package into a runnable API server.

**Why it is important:** The `otp-relay` image depends on it to start the web application.

**Risk if broken:** App container starts fail, `/readyz` and portal UI go down, Traefik has no healthy backend.

---

### `monitor.py`

**What it does:** Python entry point for the monitor process. It starts the monitor runner that performs phone presence, audit, metrics, and alerting logic.

**Why it is important:** The monitor deployment depends on it for iPhone presence and observability signals.

**Risk if broken:** Monitor metrics and Telegram-style operational alerts may stop working.

---

### `requirements.txt`

**What it does:** Python dependency list for building the app and monitor images.

**Why it is important:** Docker builds install these packages. It pins the runtime Python ecosystem needed by FastAPI, Redis, Prometheus metrics, and supporting logic.

**Risk if broken:** Image builds may fail, or the container may start with missing modules.

---

### `package.json`

**What it does:** Node/npm build metadata for the frontend build pipeline.

**Why it is important:** The frontend source `frontend/app.jsx` must be bundled/generated into browser-consumable output during build.

**Risk if broken:** Frontend build fails or stale UI gets shipped.

---

### `package-lock.json`

**What it does:** Locked npm dependency graph.

**Why it is important:** Makes frontend builds reproducible across runs and machines.

**Risk if broken:** npm dependency drift can cause different generated frontend behavior.

---

### `.env.example`

**What it does:** Template showing required/optional deployment environment variables.

**Why it is important:** Real `.env` is intentionally not committed. This file documents what operators must provide.

**Risk if broken:** New deployments may miss required values such as hosts, NFS settings, Redis settings, or observability settings.

---

### `.gitignore`

**What it does:** Prevents local runtime files, generated artifacts, secrets, logs, and caches from being committed.

**Why it is important:** Protects `.env`, generated inventories, logs, build output, runtime state, and secrets.

**Risk if broken:** Secrets or environment-specific files can leak into Git.

---

### `.dockerignore`

**What it does:** Excludes files from Docker build context.

**Why it is important:** Keeps images small and prevents secrets/dev-only files from being copied into containers.

**Risk if broken:** Builds become slow or sensitive files can enter images.

---

### `LICENSE`

**What it does:** MIT license declaration.

**Why it is important:** Defines legal reuse terms.

**Risk if removed:** License status becomes unclear.

---

## 4. GitHub Actions

### `.github/workflows/sync.yml`

**What it does:** GitHub Actions workflow for repository synchronization to the self-hosted runner/server path.

**Why it is important:** Current README describes GitHub Actions as sync-only: it should sync repository content to `/opt/k8s-ansible`, not deploy, run Helm, apply manifests, import images, or install K3s.

**Risk if broken:** Server repo may not update, or worse, CI could accidentally mutate production if deployment steps are reintroduced.

---

## 5. Application package: `otp_relay/`

### `otp_relay/__init__.py`

**What it does:** Marks `otp_relay` as a Python package.

**Why it is important:** Required for imports such as `otp_relay.routes`, `otp_relay.config`, and related modules.

**Risk if removed:** Python imports can fail.

---

### `otp_relay/config.py`

**What it does:** Reads and normalizes application runtime configuration from environment variables.

**Why it is important:** Centralizes settings such as Redis URL, Redis required mode, file paths, admin/session behavior, SMS token handling, and runtime flags.

**Risk if broken:** App may connect to the wrong Redis service, disable required safety checks, or fail startup.

---

### `otp_relay/routes.py`

**What it does:** Defines FastAPI HTTP routes for portal behavior, SMS receipt, user actions, health endpoints, and API surfaces.

**Why it is important:** This is the main API routing layer used by the browser and the iPhone shortcut.

**Risk if broken:** Portal login, polling, SMS ingestion, OTP claim/delivery, or health endpoints may fail.

---

### `otp_relay/otp_flow.py`

**What it does:** Implements the OTP business flow: queueing, receiving SMS, matching to active user/session/token, and preparing OTP for display.

**Why it is important:** It is the core application logic. OTP values should remain runtime-only and should not be persisted to disk/logs.

**Risk if broken:** OTP delivery workflow fails or leaks sensitive OTP values.

---

### `otp_relay/redis_state.py`

**What it does:** Stores transient state in Redis, typically with TTLs, for active users, queues, claims, and OTP-related runtime status.

**Why it is important:** Enables multi-replica app pods to share runtime state safely.

**Risk if broken:** App replicas may disagree about active user/queue state; `/readyz` may report Redis failure.

---

### `otp_relay/state.py`

**What it does:** Provides state abstraction/fallback logic for runtime state management.

**Why it is important:** Keeps route/business logic from hardcoding persistence details.

**Risk if broken:** Queue/session state may become inconsistent.

---

### `otp_relay/storage.py`

**What it does:** Handles persistent file storage under `/app/data`, such as users/config/progress/audit metadata files.

**Why it is important:** This is the interface to NFS-backed app data PVC.

**Risk if broken:** User imports, admin config, wizard progress, or audit writes can fail, especially if NFS permissions are wrong.

---

### `otp_relay/users.py`

**What it does:** Loads and validates portal users, including XLSX-based token/user input.

**Why it is important:** Portal access depends on the user list being loaded correctly.

**Risk if broken:** Valid users may be rejected, or invalid tokens may be accepted.

---

### `otp_relay/admin.py`

**What it does:** Implements admin authentication/config/control logic.

**Why it is important:** Admin functions depend on this for secure access to management actions and logs.

**Risk if broken:** Admin login/config can fail or become insecure.

---

### `otp_relay/audit.py`

**What it does:** Writes audit metadata events such as claim queued, SMS received, and OTP delivered.

**Why it is important:** Validation and operations depend on audit evidence. It should log event metadata, not secret OTP values.

**Risk if broken:** Automated validation cannot prove SMS/OTP workflow; audit trail becomes unreliable.

---

### `otp_relay/metrics.py`

**What it does:** Exposes Prometheus metrics for portal state such as queue depth, active user, claims, and deliveries.

**Why it is important:** Grafana dashboards and Prometheus validation depend on these metrics.

**Risk if broken:** Observability loses portal visibility.

---

### `otp_relay/health.py`

**What it does:** Provides `/livez` and `/readyz` health logic, including Redis-required readiness.

**Why it is important:** Kubernetes probes and validation rely on it. `/readyz` determines whether the service endpoint should receive traffic.

**Risk if broken:** Kubernetes may restart healthy pods or route traffic to unhealthy pods.

---

### `otp_relay/frontend.py`

**What it does:** Serves static frontend assets and help content from the app container.

**Why it is important:** Browser users need the generated frontend and guide/help pages.

**Risk if broken:** API might work but UI pages fail.

---

### `otp_relay/models.py`

**What it does:** Defines shared application data models/schemas.

**Why it is important:** Keeps route, state, and response structures consistent.

**Risk if broken:** API request/response validation can fail.

---

### `otp_relay/email_diag.py`

**What it does:** Diagnostic support for email-related or notification-related checks if enabled/used.

**Why it is important:** Gives maintainers a place to troubleshoot email/config behavior without mixing it into core routes.

**Risk if broken:** Email diagnostics become unavailable; core OTP flow may be unaffected unless routes import it directly.

---

## 6. Monitor package: `otp_monitor/`

### `otp_monitor/__init__.py`

**What it does:** Marks `otp_monitor` as a Python package.

**Why it is important:** Required for module imports from `monitor.py`.

**Risk if removed:** Monitor startup imports can fail.

---

### `otp_monitor/config.py`

**What it does:** Reads monitor runtime configuration from environment variables.

**Why it is important:** Phone IP/interface, alerting tokens, portal URL, thresholds, and runtime paths are controlled here.

**Risk if broken:** Monitor checks may target the wrong phone, wrong interface, or wrong alert destination.

---

### `otp_monitor/runner.py`

**What it does:** Main monitor loop orchestration.

**Why it is important:** Coordinates phone presence checks, audit tailing, metrics, and alerting.

**Risk if broken:** Monitor pod may run but perform no useful checks.

---

### `otp_monitor/phone.py`

**What it does:** Phone presence/probe logic, typically using network-level checks from a hostNetwork monitor pod.

**Why it is important:** Indicates whether the company iPhone is reachable.

**Risk if broken:** False iPhone-present or iPhone-absent states can occur.

---

### `otp_monitor/audit_tail.py`

**What it does:** Reads/tails audit log metadata to infer recent portal/SMS/OTP behavior.

**Why it is important:** Lets monitor correlate operational events with app behavior.

**Risk if broken:** Audit-derived health signals become stale or missing.

---

### `otp_monitor/alerts.py`

**What it does:** Sends operational alerts, likely Telegram-based from configured tokens/chat IDs.

**Why it is important:** Operators need notification when phone or portal conditions degrade.

**Risk if broken:** Failures occur silently.

---

### `otp_monitor/metrics.py`

**What it does:** Exposes monitor Prometheus metrics such as iPhone presence and last successful ARP/timestamp.

**Why it is important:** Prometheus, Grafana, and validation depend on it.

**Risk if broken:** Dashboard and alerting lose monitor-side visibility.

---

### `otp_monitor/logging_config.py`

**What it does:** Standardizes monitor logging format and verbosity.

**Why it is important:** Makes logs usable during incident diagnosis.

**Risk if broken:** Troubleshooting becomes harder.

---

## 7. Frontend: `frontend/`

### `frontend/app.jsx`

**What it does:** Source React/JSX portal application.

**Why it is important:** README identifies it as the frontend source of truth. Generated browser JavaScript should come from this file.

**Risk if broken:** Portal UI behavior breaks, even if backend APIs are healthy.

---

### `frontend/index.html`

**What it does:** Browser entry HTML for the portal.

**Why it is important:** Loads the generated frontend script and CSS.

**Risk if broken:** Browser may show blank page or fail to load app assets.

---

### `frontend/style.css`

**What it does:** Portal styling.

**Why it is important:** Controls layout, readability, mobile/browser presentation, and user-facing polish.

**Risk if broken:** UI may remain functional but become unreadable or hard to use.

---

### `frontend/guide.html`

**What it does:** Static guide shell/page for user help or onboarding.

**Why it is important:** Supports in-portal guidance for users/operators.

**Risk if broken:** Help/guide links break.

---

## 8. Kubernetes image definitions: `k8s/`

### `k8s/Dockerfile`

**What it does:** Builds the `otp-relay` FastAPI app image.

**Why it is important:** Packages Python app, frontend assets, dependencies, and runtime entrypoint into the deployable application container.

**Risk if broken:** App image build fails or runtime container misses required files.

---

### `k8s/Dockerfile.monitor`

**What it does:** Builds the `otp-monitor` image.

**Why it is important:** Packages monitor code and dependencies separately from the portal app.

**Risk if broken:** Monitor deployment cannot run.

---

## 9. Kubernetes app manifests: `k8s/manifests/`

### `namespace.yaml`

**What it does:** Defines the `otp-relay` namespace.

**Why it is important:** All app resources are scoped under this namespace.

**Risk if broken:** Resource application order and namespace isolation fail.

---

### `configmap.yaml`

**What it does:** Non-secret application configuration for the portal/monitor.

**Why it is important:** Supplies runtime values to pods without baking them into images.

**Risk if broken:** Pods start with wrong config or missing values.

---

### `deployment.yaml`

**What it does:** Defines the `otp-relay` app Deployment.

**Why it is important:** Controls replicas, container image, probes, resources, env, PVC mounts, node placement, and rollout behavior for the portal.

**Risk if broken:** Portal can go down or schedule incorrectly.

---

### `deployment-monitor.yaml`

**What it does:** Defines the monitor Deployment.

**Why it is important:** Runs phone/audit/metrics monitor, commonly with hostNetwork/NET_RAW requirements.

**Risk if broken:** Phone presence and monitor metrics fail.

---

### `service.yaml`

**What it does:** Defines the `otp-relay` ClusterIP service exposing app pods internally to Traefik.

**Why it is important:** Ingress routes to this service.

**Risk if broken:** App pods may be healthy but unreachable through ingress.

---

### `monitor-service.yaml`

**What it does:** Exposes monitor metrics on a ClusterIP service for Prometheus scraping.

**Why it is important:** ServiceMonitor needs a service target.

**Risk if broken:** Prometheus cannot scrape monitor metrics.

---

### `ingress.yaml`

**What it does:** Defines HTTP/HTTPS ingress for the portal host.

**Why it is important:** Provides browser access through Traefik using `TLS_HOST` and TLS secret behavior.

**Risk if broken:** Portal may be healthy internally but inaccessible by URL.

---

### `pvc.yaml`

**What it does:** Defines the app data PVC, usually `otp-relay-data`.

**Why it is important:** Backs `/app/data` for users/config/audit/progress files.

**Risk if broken:** Runtime data is lost or app cannot write persistent files.

---

### `pv-nfs.yaml`

**What it does:** Defines the app NFS PV for the app data PVC.

**Why it is important:** Binds Kubernetes storage to the external NFS export.

**Risk if broken:** PVC remains Pending or points to wrong NFS path/server.

---

### `otp-relay-pdb.yaml`

**What it does:** PodDisruptionBudget for app pods.

**Why it is important:** Prevents voluntary disruption from taking down all app replicas at once.

**Risk if broken:** Drains/restarts can reduce portal availability.

---

### `redis-configmap.yaml`

**What it does:** Redis server configuration.

**Why it is important:** Controls Redis runtime behavior for the StatefulSet.

**Risk if broken:** Redis startup or persistence behavior can fail.

---

### `redis-statefulset.yaml`

**What it does:** Defines three Redis pods with stable identity and per-pod PVCs.

**Why it is important:** Core Redis HA data plane. Current architecture expects one Redis pod per eligible node.

**Risk if broken:** Redis HA can fail; app readiness can fail because Redis is required.

---

### `redis-service.yaml`

**What it does:** Defines Redis service/headless access for Redis pods and/or HAProxy target wiring.

**Why it is important:** Sentinel and HAProxy use stable service DNS to locate Redis pods.

**Risk if broken:** Sentinel/HAProxy cannot reach Redis.

---

### `redis-nfs-pv.yaml`

**What it does:** Defines Redis NFS PVs for `redis-data-otp-redis-0/1/2` PVCs.

**Why it is important:** Provides persistent storage to each Redis StatefulSet pod when `REDIS_STORAGE_CLASS=otp-redis-nfs`.

**Risk if broken:** Redis pods may remain Pending or lose persistent data.

---

### `redis-pdb.yaml`

**What it does:** PDB for Redis StatefulSet pods.

**Why it is important:** Limits voluntary Redis disruption during drains.

**Risk if broken:** Too many Redis pods could be evicted at once.

---

### `redis-sentinel-configmap.yaml`

**What it does:** Sentinel configuration.

**Why it is important:** Sentinel tracks Redis master and supports failover.

**Risk if broken:** HAProxy may point to stale master or failover may not work.

---

### `redis-sentinel-deployment.yaml`

**What it does:** Deploys Redis Sentinel replicas.

**Why it is important:** Provides Redis master discovery and failover quorum.

**Risk if broken:** Redis HA behavior degrades.

---

### `redis-sentinel-service.yaml`

**What it does:** Exposes Sentinel on port 26379.

**Why it is important:** Validation and HAProxy/Sentinel clients need stable access.

**Risk if broken:** Master discovery checks fail.

---

### `redis-sentinel-pdb.yaml`

**What it does:** PDB for Sentinel pods.

**Why it is important:** Maintains Sentinel quorum during voluntary disruption.

**Risk if broken:** Drains may reduce Sentinel availability.

---

### `redis-haproxy-configmap.yaml`

**What it does:** HAProxy configuration for routing Redis clients to the current master.

**Why it is important:** App uses a stable Redis URL while HAProxy/Sentinel handle master routing.

**Risk if broken:** App cannot reliably connect to Redis master.

---

### `redis-haproxy-deployment.yaml`

**What it does:** Deploys Redis HAProxy replicas.

**Why it is important:** App connects to this layer instead of individual Redis pods.

**Risk if broken:** App readiness fails with Redis errors.

---

### `redis-haproxy-pdb.yaml`

**What it does:** PDB for HAProxy pods.

**Why it is important:** Keeps at least one Redis proxy path alive during voluntary disruption.

**Risk if broken:** Drains can remove all HAProxy endpoints.

---

## 10. Observability: `k8s/observability/`

### `prometheus-stack-values.yaml`

**What it does:** Helm values for kube-prometheus-stack.

**Why it is important:** Controls Prometheus, Grafana, Alertmanager, resource limits, placement, ingress/service behavior, and dashboard provisioning settings.

**Risk if broken:** Observability stack may fail to install or dashboards may lose data.

---

### `loki-values.yaml`

**What it does:** Helm values for Loki.

**Why it is important:** Defines Loki storage/mode. Current deployment uses single-binary StatefulSet, so validation must not assume a `loki-gateway` Deployment.

**Risk if broken:** Logs collection/storage can fail.

---

### `alloy-values.yaml`

**What it does:** Helm values for Grafana Alloy log collection.

**Why it is important:** Configures log scraping/forwarding to Loki.

**Risk if broken:** Logs stop appearing in Loki/Grafana.

---

### `servicemonitor-otp-relay.yaml`

**What it does:** Prometheus Operator ServiceMonitor for app metrics.

**Why it is important:** Allows Prometheus to scrape `/metrics` from the portal service.

**Risk if broken:** `up{job="otp-relay"}` and app metrics disappear.

---

### `servicemonitor-otp-monitor.yaml`

**What it does:** ServiceMonitor for monitor metrics.

**Why it is important:** Allows Prometheus to scrape iPhone presence and monitor health metrics.

**Risk if broken:** iPhone presence panels/alerts stop updating.

---

### `grafana-ingress.yaml`

**What it does:** Traefik IngressRoute/ingress configuration for Grafana.

**Why it is important:** Provides browser access to Grafana without port-forwarding.

**Risk if broken:** Grafana may run internally but not load via URL.

---

### `dashboards/otp-relay-live.json`

**What it does:** Source-of-truth Grafana dashboard JSON.

**Why it is important:** README says this JSON is the source that generates the dashboard ConfigMap YAML.

**Risk if broken:** Dashboard panels/queries become wrong or stale.

---

### `grafana-dashboard-otp-relay-live.yaml`

**What it does:** Generated ConfigMap containing the Grafana dashboard JSON.

**Why it is important:** Grafana sidecar discovers this ConfigMap and provisions the dashboard.

**Risk if edited directly:** Changes may be overwritten by `scripts/build_grafana_dashboard_configmap.py`. Edit JSON source instead.

---

## 11. Installer scripts: `scripts/`

### `scripts/cluster-health-check.sh`

**What it does:** Standalone health validation for the live cluster.

**Why it is important:** Operators can use it to verify pods, services, ingress, Redis, and app health after install/update.

**Risk if broken:** Operators lose a fast validation path.

---

### `scripts/build_help_docs.py`

**What it does:** Converts help Markdown/assets under `docs/help/` into frontend help output.

**Why it is important:** Keeps user-facing help generated from maintainable Markdown source.

**Risk if broken:** Help pages may be stale or missing.

---

### `scripts/build_grafana_dashboard_configmap.py`

**What it does:** Converts `k8s/observability/dashboards/otp-relay-live.json` into `k8s/observability/grafana-dashboard-otp-relay-live.yaml`.

**Why it is important:** Keeps Grafana dashboard source and generated ConfigMap consistent.

**Risk if broken:** Dashboard changes do not deploy correctly.

---

## 12. Installer library: `scripts/lib/`

### `scripts/lib/common.sh`

**What it does:** Shared shell helpers such as logging, command checks, path handling, and common guardrails.

**Why it is important:** Keeps installer behavior consistent across modules.

**Risk if broken:** Many scripts can fail because this is shared plumbing.

---

### `scripts/lib/env.sh`

**What it does:** Reads, validates, creates/rejects, and exports `.env` settings.

**Why it is important:** `.env` is the source of operator-provided deployment values.

**Risk if broken:** Wrong hosts, NFS paths, Redis settings, or TLS values may be deployed.

---

### `scripts/lib/os.sh`

**What it does:** Installs/checks host OS prerequisites.

**Why it is important:** Ensures required packages/commands exist before K3s/Docker/Helm/Kubectl operations.

**Risk if broken:** Later installation steps fail unpredictably.

---

### `scripts/lib/preflight.sh`

**What it does:** Non-mutating doctor/preflight validation.

**Why it is important:** `setup.sh --doctor` uses it to detect unsafe or incomplete setup before changing the system.

**Risk if broken:** Operators may begin a bad install without warning.

---

### `scripts/lib/k3s.sh`

**What it does:** K3s installation/configuration/access helper logic.

**Why it is important:** Controls Kubernetes cluster baseline and kubeconfig behavior.

**Risk if broken:** Cluster installation or access fails.

---

### `scripts/lib/docker.sh`

**What it does:** Docker/build-tool setup or checks for container image build path.

**Why it is important:** Images must be built before import/deployment unless using release bundles.

**Risk if broken:** App/monitor image build fails.

---

### `scripts/lib/images.sh`

**What it does:** Builds, tags, imports, or validates container images for K3s/containerd.

**Why it is important:** K3s nodes need local images or registry access for `otp-relay:latest` and `otp-monitor:latest`.

**Risk if broken:** Pods fail with image pull/import errors.

---

### `scripts/lib/build-stage.sh`

**What it does:** Builds/stages generated assets before deployment: frontend bundle, help docs, Grafana dashboard ConfigMap, and related build artifacts.

**Why it is important:** Ensures manifests/images contain current generated outputs.

**Risk if broken:** Deployment may use stale frontend, stale help docs, or stale dashboard.

---

### `scripts/lib/manifests.sh`

**What it does:** Renders and validates Kubernetes manifests from source and `.env` values.

**Why it is important:** Converts operator settings into deployable YAML.

**Risk if broken:** Kubernetes resources may be malformed or point to wrong environment values.

---

### `scripts/lib/apply-deploy.sh`

**What it does:** Applies Kubernetes manifests and performs rollout operations.

**Why it is important:** This is the deployment execution layer.

**Risk if broken:** Manifests may not apply, rollouts may not complete, or ordering may be wrong.

---

### `scripts/lib/deploy-mode.sh`

**What it does:** Defines/validates supported deployment modes such as full/app/monitor if still used.

**Why it is important:** Prevents accidental partial deployment mismatches.

**Risk if broken:** Wrong components may be built/applied.

---

### `scripts/lib/metallb.sh`

**What it does:** Installs/configures MetalLB address pool and L2 advertisement.

**Why it is important:** Traefik LoadBalancer external IP depends on MetalLB in bare-metal/K3s lab topology.

**Risk if broken:** Ingress may exist but external IP will not route.

---

### `scripts/lib/tls.sh`

**What it does:** Creates/validates TLS secrets and self-signed certificate behavior.

**Why it is important:** Portal and Grafana HTTPS depend on correct TLS secret names and hosts.

**Risk if broken:** Browser access fails or cert/host mismatch occurs.

---

### `scripts/lib/observability.sh`

**What it does:** Installs/updates Prometheus, Grafana, Loki, Alloy, ServiceMonitors, and dashboards.

**Why it is important:** Provides operational visibility, validation metrics, and logs.

**Risk if broken:** Monitoring/logging is unavailable or Helm releases drift.

---

### `scripts/lib/repo-sync.sh`

**What it does:** Handles repository sync/update guardrails on the server.

**Why it is important:** Keeps `/opt/k8s-ansible` current while protecting runtime state.

**Risk if broken:** Server may run stale or partially synced code.

---

### `scripts/lib/github-runner.sh`

**What it does:** Supports GitHub self-hosted runner setup/sync behavior.

**Why it is important:** Current GitHub Actions model depends on a runner for repo synchronization.

**Risk if broken:** Sync automation may fail.

---

### `scripts/lib/summary.sh`

**What it does:** Produces install-report/operator handover summaries.

**Why it is important:** Gives operators a compact view of URLs, namespaces, pod/service/PVC/TLS/NFS state, and useful validation commands.

**Risk if broken:** Install may succeed but handover evidence becomes poor.

---

## 13. Ansible automation: `automation/ansible/`

### `automation/ansible/README.md`

**What it does:** Explains the Ansible automation model and recommended POC/production playbook order.

**Why it is important:** Documents sequencing: OS baseline, optional NFS, K3s control-plane, workers, labels, storage validation, deploy, production validation.

**Risk if broken:** Operators may run playbooks in unsafe order.

---

### `automation/ansible/ansible.cfg`

**What it does:** Ansible configuration for this repo.

**Why it is important:** Controls inventory defaults, roles path, host key behavior, logging, or SSH behavior depending on content.

**Risk if broken:** Playbooks may not find roles/inventory or SSH may fail.

---

### `automation/ansible/inventory.poc.example.ini`

**What it does:** Example inventory for the lab/POC topology.

**Why it is important:** Shows expected host groups and variable shape for control-plane/workers/NFS arrangement.

**Risk if broken:** Users create bad generated inventories.

---

### `automation/ansible/inventory.prod.example.ini`

**What it does:** Example production-style inventory.

**Why it is important:** Documents dedicated NFS/K3s node layout.

**Risk if broken:** Production inventory may miss required groups/vars.

---

### `automation/ansible/group_vars/all.yml`

**What it does:** Shared Ansible variables for all hosts/playbooks.

**Why it is important:** Central place for defaults used by roles and playbooks.

**Risk if broken:** Multiple playbooks can inherit wrong package, path, K3s, NFS, or deployment values.

---

### Playbooks

#### `automation/ansible/playbooks/00-os-baseline.yml`

**What it does:** Applies base OS preparation on target hosts.

**Why it is important:** Common packages, users, SSH, networking, and prerequisites must exist before K3s/NFS/deploy steps.

**Risk if broken:** Later playbooks fail on missing OS prerequisites.

#### `automation/ansible/playbooks/05-nfs-server.yml`

**What it does:** Configures a managed NFS server when NFS is part of the Ansible-managed environment.

**Why it is important:** Provides exports for app data and Redis PVs.

**Risk if broken:** PVCs remain Pending or NFS mount/write checks fail.

#### `automation/ansible/playbooks/10-k3s-control-plane.yml`

**What it does:** Installs/configures the K3s server/control-plane.

**Why it is important:** The cluster starts here and workers join this node.

**Risk if broken:** No functional Kubernetes API/control-plane.

#### `automation/ansible/playbooks/20-k3s-workers.yml`

**What it does:** Joins worker nodes to the K3s cluster.

**Why it is important:** Required for HA-ish scheduling and workload spreading.

**Risk if broken:** Workloads cannot spread across workers; topology constraints may block scheduling.

#### `automation/ansible/playbooks/30-node-labels.yml`

**What it does:** Applies Kubernetes node labels for app, Redis, storage, observability, and monitor placement.

**Why it is important:** Redis topology spread and app/monitor placement depend on labels.

**Risk if broken:** Redis pods may be Pending or app pods may schedule on wrong nodes.

#### `automation/ansible/playbooks/40-storage-validate.yml`

**What it does:** Validates NFS/storage availability before deployment.

**Why it is important:** Catches missing exports, DNS issues, or mount failures early.

**Risk if broken:** Install reaches Kubernetes deployment and then fails with PVC/storage issues.

#### `automation/ansible/playbooks/50-deploy-otp-relay.yml`

**What it does:** Deploys OTP Relay resources using the repo manifests/scripts.

**Why it is important:** Main Ansible deployment step for app/Redis/monitor/K8s resources.

**Risk if broken:** Application deployment does not happen.

#### `automation/ansible/playbooks/70-validate-production.yml`

**What it does:** Runs production validation after deployment.

**Why it is important:** Confirms cluster, storage, Redis, app, monitor, and availability criteria.

**Risk if broken:** Bad deployment may be accepted as healthy, or healthy deployment may be falsely rejected.

### Roles

Each role has a `tasks/main.yml` entrypoint. The visible roles are:

- `roles/common/tasks/main.yml`: shared OS/common host preparation.
- `roles/nfs_server/...`: NFS server configuration tasks.
- `roles/k3s_server/tasks/main.yml`: K3s server/control-plane tasks.
- `roles/k3s_agent/tasks/main.yml`: K3s worker/agent tasks.
- `roles/node_labels/tasks/main.yml`: Kubernetes node label tasks.
- `roles/otp_relay_deploy/tasks/main.yml`: app deployment tasks.
- `roles/validation/tasks/main.yml`: validation tasks.

**Why roles are important:** They keep playbooks small and reusable. Each playbook selects a role or role set for a deployment stage.

**Risk if role tasks break:** The corresponding playbook stage fails or silently configures hosts incorrectly.

---

## 14. Libvirt automation: `automation/libvirt/`

### `automation/libvirt/provision-vms.sh`

**What it does:** Provisions lab K3s VMs using libvirt.

**Why it is important:** Enables repeatable POC VM creation for control-plane and worker nodes.

**Risk if broken:** Lab cluster cannot be rebuilt reliably.

---

## 15. Documentation: `docs/`

### `docs/README.md`

**What it does:** Documentation index and reading guide.

**Why it is important:** Directs readers to architecture, deployment, operations, observability, development, and help docs.

**Risk if broken:** New operators do not know where to start.

---

### `docs/architecture/current-architecture-and-sch-gap-analysis.md`

**What it does:** Explains the current architecture and gap analysis against SCH expectations.

**Why it is important:** Used for design alignment and management/technical review.

**Risk if broken:** Design decisions and gap status become unclear.

---

### `docs/architecture/diagrams/`

**What it does:** Stores architecture diagrams.

**Why it is important:** Visualizes system flow, infrastructure, and deployment relationships.

**Risk if broken:** Architecture becomes harder to explain to non-code stakeholders.

---

### `docs/deployment/deployment-and-storage-guide.md`

**What it does:** Deployment and storage runbook.

**Why it is important:** Explains NFS/PVC/Redis/app storage behavior.

**Risk if broken:** Operators may misconfigure NFS or storage classes.

---

### `docs/development/build-and-development-guide.md`

**What it does:** Development/build workflow documentation.

**Why it is important:** Explains how to build frontend, help docs, dashboard config, and images.

**Risk if broken:** Developers may edit generated files or skip required build steps.

---

### `docs/operations/operations-and-validation-runbook.md`

**What it does:** Operational validation/runbook material.

**Why it is important:** Guides checks for pods, Redis, storage, app, ingress, and failures.

**Risk if broken:** Incidents take longer to diagnose.

---

### `docs/operations/observability-and-grafana.md`

**What it does:** Observability/Grafana usage and maintenance guide.

**Why it is important:** Explains dashboard, Prometheus, Loki/Alloy, and Grafana access behavior.

**Risk if broken:** Observability stack becomes difficult to operate.

---

### `docs/help/`

**What it does:** Source Markdown/assets for in-portal help.

**Why it is important:** Generated frontend help output comes from here.

**Risk if broken:** User help in portal is missing or stale.

---

## 16. Collections: `collections/`

**What it does:** Holds Ansible Galaxy collection content or requirements used by the automation.

**Why it is important:** Allows Ansible automation to run with the required modules/collections in a controlled repo-local structure.

**Risk if broken:** Playbooks may fail due to missing Ansible modules.

---

## 17. Current important operational rules

1. **Do not commit secrets.** Runtime secrets belong in `.env` or Kubernetes Secrets.
2. **Do not edit generated outputs as source.** Edit `frontend/app.jsx`, `docs/help/*`, and `k8s/observability/dashboards/otp-relay-live.json`, then regenerate outputs.
3. **Do not assume Loki has a gateway deployment.** This deployment uses single-binary Loki StatefulSet unless values change.
4. **Redis requires all three nodes to be Redis-eligible** in the current 1 control-plane + 2 worker topology.
5. **GitHub Actions must remain sync-only** unless the deployment model is intentionally changed.
6. **Production release-bundle design should separate build host from production runtime.** Build tools belong on dev/build host; prod should receive sealed runtime artifacts.

---

## 18. Files most dangerous to edit casually

- `.env` on server: controls environment-specific deployment behavior.
- `scripts/lib/env.sh`: can corrupt environment handling.
- `scripts/lib/manifests.sh`: can render wrong manifests.
- `scripts/lib/apply-deploy.sh`: can apply resources in wrong order.
- `k8s/manifests/redis-statefulset.yaml`: can break Redis scheduling/storage.
- `k8s/manifests/redis-nfs-pv.yaml`: can point Redis to wrong NFS paths.
- `k8s/manifests/deployment.yaml`: can break portal pods.
- `k8s/manifests/ingress.yaml`: can break browser access.
- `k8s/observability/*values.yaml`: can break Helm-managed observability stack.
- `.github/workflows/sync.yml`: can accidentally turn sync-only workflow into mutating deployment.

---

## 19. Suggested future documentation additions

For the dev-to-prod release-bundle project, add:

```text
docs/operations/dev-to-prod-release-runbook.md
docs/repository-file-guide.md
release/install-prod.sh
release/rollback-prod.sh
scripts/build-release-bundle.sh
```

The new release documentation should explicitly state that production receives only sealed runtime artifacts, not source repo checkout, Git, Node build tooling, Docker build context, or Ansible provisioning code.
