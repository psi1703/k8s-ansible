# Disabled Legacy Ansible Automation

This directory is intentionally retained only as a compatibility and safety boundary.

## Current DEVtoPROD contract

The `k8s-ansible-DEVtoPROD` branch is now **bundle-only**.

The dev/build host may only:

* prepare source files
* render Kubernetes manifests into a staging directory
* build and export local Docker image archives
* package observability files and metadata
* create a sealed production release tarball
* create a checksum and handoff report

The dev/build host must not:

* install K3s
* configure K3s control-plane nodes
* join K3s worker nodes
* label live Kubernetes nodes
* inspect live Kubernetes storage
* apply Kubernetes manifests
* run Helm install or Helm upgrade
* import images into a live cluster
* restart Kubernetes deployments
* validate a live production cluster
* provision VMs
* install GitHub Actions runners on production

Production receives only the finished sealed release bundle.

## Correct entrypoint

From the repository root, build the release bundle with:

```bash
bash setup.sh
```

or, for non-interactive automation:

```bash
bash setup.sh --noninteractive --mode full
```

The legacy Ansible deployment playbooks are intentionally disabled. They should fail safely if someone tries to run them.

## Disabled legacy behavior

The following old responsibilities are no longer performed by this repository:

* OS baseline preparation
* NFS server provisioning
* libvirt VM provisioning
* K3s installation
* Kubernetes node joining
* Kubernetes node labeling
* Kubernetes storage validation
* direct OTP Relay deployment
* production cluster validation

Do not restore those behaviors in this branch.

## Production handoff model

The expected handoff is:

1. Sync the repository to the dev/build server.
2. Build the sealed release bundle on the dev/build server.
3. Transfer only the finished bundle, checksum, and report to production.
4. Production-side installation or activation is handled outside this release builder.

This repository must remain a release-bundle builder, not a live deployment tool.
