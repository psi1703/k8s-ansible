# OTP Relay headless automation

This automation supports the SCH phase map without changing application behavior.

## Current target design

The server/real host is the Kubernetes control-plane and Ansible runner. The provisioner creates only two worker VMs.

```text
Server / real host:
  - K3s control-plane
  - Ansible runner
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
