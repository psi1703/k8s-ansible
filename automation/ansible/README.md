# Disabled Legacy Ansible Automation

This directory is intentionally retained only as a compatibility/safety boundary.

## Current DEVtoPROD contract

The `k8s-ansible-DEVtoPROD` branch is now **bundle-only**.

The dev/build side may only:

- prepare source files
- render Kubernetes manifests into a staging directory
- build/export local Docker image archives
- package observability files and metadata
- create a sealed production release tarball
- create a checksum and handoff report

The dev/build side must not:

- install K3s
- configure K3s control-plane nodes
- join K3s worker nodes
- label live Kubernetes nodes
- inspect live Kubernetes storage
- apply Kubernetes manifests
- run Helm install/upgrade
- import images into a live cluster
- restart deployments
- validate a live production cluster
- provision VMs
- install GitHub Actions runners

The production server receives only the finished release bundle.

## Correct entrypoint

Use one of these from the repository root:

```bash
bash setup.sh
