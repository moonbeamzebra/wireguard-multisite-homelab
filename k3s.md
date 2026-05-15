# k3s Two-Site Cluster — Multi-Site Home Lab

## Overview

A lightweight Kubernetes cluster (k3s) distributed across two sites via the
existing WireGuard tunnel. One control plane at site A, workers at both sites.

### Architecture

```
Site A (maison) — LAN10 (10.0.10.x)       Site B (chalet) — LAN10 (10.1.10.x)
────────────────────────────────           ────────────────────────────────────
m-k3s-server   10.0.10.110  control-plane  c-k3s-agent-1  10.1.10.111  worker
m-k3s-agent-1  10.0.10.111  worker         c-k3s-agent-2  10.1.10.112  worker
m-k3s-agent-2  10.0.10.112  worker
```

**Technology choices:**
- **k3s** — lightweight Kubernetes, installs as a single binary
- **Flannel** (VXLAN) — pod overlay network, works transparently over WireGuard
- **Traefik** — ingress controller (built-in to k3s)
- **local-path** — default storage provisioner (node-local)
- **ServiceLB disabled** — NodePort used instead; no cloud LoadBalancer needed
- **cert-manager + Rancher** — cluster management UI

---

## Node Sizing

| VM | Site | vCPU | RAM | Role |
|---|---|---|---|---|
| `m-k3s-server` | maison | 2 | 4 GB | control plane (API, etcd, scheduler) |
| `m-k3s-agent-1` | maison | 4 | 8 GB | worker |
| `m-k3s-agent-2` | maison | 4 | 8 GB | worker |
| `c-k3s-agent-1` | chalet | 4 | 8 GB | worker |
| `c-k3s-agent-2` | chalet | 4 | 8 GB | worker |

All nodes: Debian 13 (trixie), 32 GB disk, KVM with `host-passthrough` CPU.

---

## Installation

### Prerequisites

- VMs created with `16-create-debian-13-vms.sh` (see below)
- DNS/DHCP reservations in `site-X.env` + `09-create-router00.sh` re-run on both sites
- `INTRA_LAB_PRIVATE_KEY` / `INTRA_LAB_PUBLIC_KEY` in secrets env files
- All VM names resolve: `ping m-k3s-server`, `ping c-k3s-agent-1`

### Step 1 — Create VMs

**Site A (run on m-server00):**
```bash
source site-A.env && source site-A-secrets.env
sudo -E bash 16-create-debian-13-vms.sh \
  --extra-pubkey "${INTRA_LAB_PUBLIC_KEY}" \
  "m-k3s-server:dhcp:2:4096,m-k3s-agent-1:dhcp:4:8192,m-k3s-agent-2:dhcp:4:8192"
```

**Site B (run on c-server00):**
```bash
source site-B.env && source site-B-secrets.env
sudo -E bash 16-create-debian-13-vms.sh \
  --extra-pubkey "${INTRA_LAB_PUBLIC_KEY}" \
  "c-k3s-agent-1:dhcp:4:8192,c-k3s-agent-2:dhcp:4:8192"
```

Add DHCP/DNS entries to `site-X.env` (script prints the exact lines at the end),
then re-run `09-create-router00.sh` on each site.

Wait ~2 minutes for cloud-init to complete on all VMs.

### Step 2 — Install k3s

**Run once from m-server00 (site A only):**
```bash
source site-A.env && source site-A-secrets.env
bash 17-install-k3s.sh
```

This script:
- Installs k3s server on `m-k3s-server`
- Retrieves the join token
- Installs k3s agent on all agents (both sites) — agents join via WireGuard tunnel
- Auto-detects the primary interface (`enp1s0`) for Flannel
- Fetches and patches the kubeconfig

### Step 3 — Configure kubectl on your Mac

```bash
scp lab@m-server00:scripts/k3s-homelab.yaml ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes -o wide
```

Add to your `~/.zshrc` or `~/.bashrc` to make it permanent:
```bash
export KUBECONFIG=~/.kube/homelab.yaml
```

### Step 4 — Verify cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

Expected output:
```
NAME            STATUS   ROLES           AGE   VERSION
c-k3s-agent-1   Ready    <none>          ...   v1.35.x+k3s1
c-k3s-agent-2   Ready    <none>          ...   v1.35.x+k3s1
m-k3s-agent-1   Ready    <none>          ...   v1.35.x+k3s1
m-k3s-agent-2   Ready    <none>          ...   v1.35.x+k3s1
m-k3s-server    Ready    control-plane   ...   v1.35.x+k3s1
```

---

## Adding Workers Later

Add the new VM name to `K3S_AGENTS` in `17-install-k3s.sh` and re-run.
Existing nodes are not touched.

---

## First Cross-Site Deployment Test

```bash
# Deploy nginx across all 5 nodes
kubectl create deployment nginx --image=nginx --replicas=5
kubectl get pods -o wide          # one pod per node

# Expose via NodePort
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get svc nginx             # note the NodePort

# Test from your Mac
curl http://10.0.10.110:<nodeport>
```

---

## Tools

### kubectl

```bash
# Node status
kubectl get nodes -o wide

# All pods across all namespaces
kubectl get pods -A

# Watch pods
kubectl get pods -w

# Pod logs
kubectl logs -n <namespace> <pod-name> -f

# Shell into a pod
kubectl exec -it <pod-name> -- /bin/bash

# Describe a resource
kubectl describe pod <pod-name>
```

### k9s — Terminal UI

```bash
brew install k9s
export KUBECONFIG=~/.kube/homelab.yaml
k9s
```

k9s key bindings:
- `:pods` — list all pods
- `:nodes` — list nodes
- `l` — logs
- `s` — shell into container
- `d` — describe
- `Ctrl-D` — delete
- `?` — help

---

## Rancher — Cluster Management UI

### Installation

```bash
# Prerequisites (on your Mac)
brew install helm
helm version

# Install cert-manager + Rancher
export KUBECONFIG=~/.kube/homelab.yaml
bash 18-install-rancher.sh
```

Monitor progress:
```bash
kubectl get pods -n cattle-system -w
```

### Access

```
URL      : https://10.0.10.110:<nodeport>
           (works on any node IP with the same port)
Username : admin
Password : admin  (forced change on first login)
```

Optional — nicer URL via `/etc/hosts` on your Mac:
```bash
echo '10.0.10.110 rancher.homelab' | sudo tee -a /etc/hosts
# Then: https://rancher.homelab:<nodeport>
```

### Useful commands

```bash
kubectl get pods -n cattle-system
kubectl get pods -n cert-manager
kubectl logs -n cattle-system -l app=rancher -f
```

### Notes

- Rancher requires the `latest` Helm channel (not `stable`) for k8s 1.35+
- Deploys ~20 pods in `cattle-system` — allow 5-10 min for full startup
- cert-manager handles TLS certificate lifecycle

---

## Network Architecture

```
Pod CIDR   : 10.42.0.0/16  (Flannel default)
Service CIDR: 10.43.0.0/16

Flannel backend: VXLAN over existing WireGuard tunnel (10.0.0.x)
Cross-site pod traffic path:
  Pod (10.42.4.x on c-k3s-agent-1)
    → Flannel VXLAN
    → c-bastion WireGuard (10.0.0.2)
    → m-bastion WireGuard (10.0.0.1)
    → Flannel VXLAN
    → Pod (10.42.1.x on m-k3s-agent-1)
```

---

## Site-X.env Additions

Add to both `site-A.env` and `site-B.env`:

```bash
# k3s SSH keypair (shared across sites)
export INTRA_LAB_PUBLIC_KEY="ssh-ed25519 AAAA... intra-lab"
```

Add to both `site-A-secrets.env` and `site-B-secrets.env`:

```bash
export INTRA_LAB_PRIVATE_KEY="<base64-encoded-private-key>"
```

Generate the keypair once on your Mac:
```bash
ssh-keygen -t ed25519 -N "" -C "intra-lab" -f ~/.ssh/id_ed25519_intra_lab
echo "INTRA_LAB_PUBLIC_KEY=\"$(cat ~/.ssh/id_ed25519_intra_lab.pub)\""
echo "INTRA_LAB_PRIVATE_KEY=\"$(cat ~/.ssh/id_ed25519_intra_lab | base64 | tr -d '\n')\""
```
