# OTP Relay headless automation

This automation supports the SCH phase map without changing application behavior.

## Current target design

The server/real host is the Kubernetes control-plane and Ansible control host. The provisioner creates only two worker VMs.

```text
Server / real host:
  - K3s control-plane
  - Ansible control host
  - Docker/image build host
  - OTP Relay deployment orchestrator
  - Repository path: /opt/k8s-ansible

Worker VM 1:
  - K3s worker

Worker VM 2:
  - K3s worker

External NFS server:
  - Provides persistent storage for OTP Relay app data
  - Not joined to Kubernetes
  - Not provisioned or destroyed by this automation
```

## Repository sync model

Repository sync is handled outside Ansible by the local sync script and optional systemd timer:

```text
scripts/sync-repo.sh
scripts/install-repo-sync-timer.sh
```

The sync path only updates the local checkout from GitHub. It must not install K3s, apply Kubernetes manifests, run Helm changes, restart workloads, import images, or run deployment playbooks.

## Ansible responsibility

Ansible starts after the repository is already present on the control host. It is responsible for the infrastructure and deployment phases that are intentionally invoked by setup:

```text
1. validate generated inventory
2. prepare the control-plane host
3. prepare worker VMs
4. install or validate K3s server
5. install or validate K3s agents
6. deploy OTP Relay using the local installer and .env
```

The local `.env` file remains the source of truth for runtime values and secrets.
