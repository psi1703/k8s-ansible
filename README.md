# k8s-ansible DEVtoPROD Release Bundle Builder

This branch is the **DEVtoPROD bundle-only path** for OTP Relay Kubernetes release preparation.

It does **not** deploy anything.

The dev/build side creates a sealed production release bundle. The production server receives only that finished bundle, its checksum, and the handoff report.

## Bundle-only contract

This repository path may:

- prepare the release source tree
- validate local source files
- build frontend/app assets
- render Kubernetes manifests into a staging directory
- build local Docker image archives
- package observability YAML/value files
- write release metadata
- create a sealed `.tar.gz` release bundle
- create a `.sha256` checksum
- create a release report

This repository path must not:

- install K3s
- install Helm
- run Helm install/upgrade
- run `kubectl apply`
- run `kubectl rollout`
- import images into a live cluster
- restart Kubernetes deployments
- provision VMs
- configure K3s control-plane nodes
- configure K3s worker nodes
- label live Kubernetes nodes
- inspect live Kubernetes PVCs, pods, services, or ingresses
- install GitHub Actions runners
- validate a live cluster
- deploy directly to production

Production-side installation, image loading, Helm execution, Kubernetes manifest application, rollout validation, secret handling, and operational checks are intentionally outside this build path.

## Correct entrypoints

Use either entrypoint from the repository root:

```bash
bash setup.sh
