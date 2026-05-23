[README.md](https://github.com/user-attachments/files/28172968/README.md)
# OTP Relay headless automation

This automation supports the SCH phase map without changing application behavior.

For the current proof-of-concept/module test, use three K3s VMs on the lab host and run NFS externally on the laptop:

- VM1: `master` - K3s control plane - max 3 GB RAM
- VM2: `worker1` - K3s worker - max 3 GB RAM
- VM3: `worker2` - K3s worker - max 3 GB RAM
- Laptop: external NFS storage on the same LAN

The laptop/NFS host is not joined to Kubernetes. It backs the Kubernetes PVC used by the app data path. This is acceptable for cluster validation; production should use a dedicated always-on NFS server or storage service.

## Cluster order with laptop-managed NFS

Prepare the laptop NFS export manually first, then run:

```bash
ansible-playbook -i inventory.example.ini playbooks/00-os-baseline.yml
ansible-playbook -i inventory.example.ini playbooks/10-k3s-control-plane.yml
ansible-playbook -i inventory.example.ini playbooks/20-k3s-workers.yml
ansible-playbook -i inventory.example.ini playbooks/30-node-labels.yml
ansible-playbook -i inventory.example.ini playbooks/40-storage-validate.yml
ansible-playbook -i inventory.example.ini playbooks/50-deploy-otp-relay.yml
ansible-playbook -i inventory.example.ini playbooks/70-validate-production.yml
```

Copy `inventory.example.ini` to `inventory.ini` and edit IPs before running.

## Dedicated NFS server order

If the NFS host is a managed Debian/Ubuntu VM/server, use the production-style inventory and include the NFS server playbook:

```bash
ansible-playbook -i inventory.prod.ini playbooks/00-os-baseline.yml
ansible-playbook -i inventory.prod.ini playbooks/05-nfs-server.yml
ansible-playbook -i inventory.prod.ini playbooks/10-k3s-control-plane.yml
ansible-playbook -i inventory.prod.ini playbooks/20-k3s-workers.yml
ansible-playbook -i inventory.prod.ini playbooks/30-node-labels.yml
ansible-playbook -i inventory.prod.ini playbooks/40-storage-validate.yml
ansible-playbook -i inventory.prod.ini playbooks/50-deploy-otp-relay.yml
ansible-playbook -i inventory.prod.ini playbooks/70-validate-production.yml
```

Use `inventory.prod.example.ini` as a template and save the real file as `inventory.prod.ini`.

## Cluster sizing

For the lab host, cap the three K3s VMs at 3 GB RAM each:

```text
cp       3 GB RAM, 2 vCPU
worker1 3 GB RAM, 2 vCPU
worker2 3 GB RAM, 2 vCPU
```

Keep the laptop awake and give it a static IP or DHCP reservation for NFS.
