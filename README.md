# 🚀 Kubernetes v1.34 — Hands-On Lab Setup Guide

> **Audience:** DevOps students who are new to Kubernetes and want a **working**
> multi-node cluster they can build, break, and fix on their own machines.
> **OS:** Ubuntu 24.04 LTS on every node.

---

## 📚 Table of Contents

1. [What you will build](#-what-you-will-build)
2. [Lab topology](#-lab-topology)
3. [Pre-flight checklist](#-pre-flight-checklist)
4. [Step-by-step installation](#-step-by-step-installation)
   - [Step 1 — Hostnames & `/etc/hosts`](#step-1--hostnames--etchosts-all-nodes)
   - [Step 2 — Disable swap](#step-2--disable-swap-all-nodes)
   - [Step 3 — Load kernel modules](#step-3--load-required-kernel-modules-all-nodes)
   - [Step 4 — Sysctl networking](#step-4--configure-sysctl-networking-all-nodes)
   - [Step 5 — Install containerd](#step-5--install-and-configure-containerd-all-nodes)
   - [Step 6 — Install Kubernetes v1.34](#step-6--install-kubernetes-v134-all-nodes)
   - [Step 7 — Initialize the control plane](#step-7--initialize-the-control-plane-master-node-only)
   - [Step 8 — Install Calico CNI](#step-8--install-calico-cni-master-node-only)
   - [Step 9 — Join worker nodes](#step-9--join-worker-nodes-on-each-worker)
   - [Step 10 — Smoke test](#step-10--smoke-test-the-cluster)
5. [🆕 ETCD Backup & Restore (Demo)](#-etcd-backup--restore-demo)
6. [Troubleshooting quick-fixes](#-troubleshooting-quick-fixes)
7. [Useful kubectl shortcuts](#-useful-kubectl-shortcuts)
8. [Cleanup](#-cleanup-start-fresh)

---

## 🎯 What you will build

By the end of this guide you will have:

- A **Kubernetes v1.34** cluster running on **three Ubuntu 24.04 VMs**.
- One **control-plane node** + two **worker nodes** (production-grade pattern).
- The **Calico** CNI for pod networking.
- An end-to-end smoke test (Nginx deployment + NodePort service).
- A repeatable **ETCD backup & restore** workflow you can demonstrate live.

---

## 🗺️ Lab topology

```
                ┌──────────────────────────┐
                │   k8s-master-node        │
                │   IP: 10.168.253.4       │
                │   - API server           │
                │   - etcd                 │
                │   - scheduler / cm       │
                └────────────┬─────────────┘
                             │ Calico VXLAN
            ┌────────────────┼────────────────┐
            │                                 │
┌──────────────────────────┐      ┌──────────────────────────┐
│  k8s-worker-node-1       │      │  k8s-worker-node-2       │
│  IP: 10.168.253.29      │      │  IP: 10.168.253.10       │
│  - kubelet              │      │  - kubelet               │
│  - containerd           │      │  - containerd            │
│  - kube-proxy           │      │  - kube-proxy            │
└──────────────────────────┘      └──────────────────────────┘
```

| Node                  | Role          | IP              |
|-----------------------|---------------|-----------------|
| `k8s-master-node`     | control-plane | `10.168.253.4`  |
| `k8s-worker-node-1`   | worker        | `10.168.253.29` |
| `k8s-worker-node-2`   | worker        | `10.168.253.10` |

> 💡 **Tip:** You can use VirtualBox, VMware Fusion, Multipass (`multipass launch`), or cloud VMs — anything that gives you three Ubuntu 24.04 instances with bridged or host-only networking.

---

## ✅ Pre-flight checklist

Run this on **every node** before you start:

- [ ] Ubuntu 24.04 LTS installed.
- [ ] At least **2 vCPU / 2 GB RAM / 20 GB disk** per node.
- [ ] You have a `sudo` user (we will use it throughout).
- [ ] SSH access between nodes (or just use the console).
- [ ] Internet access on every node (we pull packages from `pkgs.k8s.io`).

### Cluster readiness flow

```
[Ubuntu 24.04 ready?]
        │
        ▼
[Hostname + /etc/hosts]  ──►  [Swap OFF]  ──►  [Kernel modules]
        │
        ▼
[Sysctl net.ipv4.ip_forward=1]
        │
        ▼
[containerd with systemd cgroup]
        │
        ▼
[kubeadm/kubelet/kubectl v1.34]
        │
        ▼
[master] kubeadm init ──► Calico ──► workers join
        │
        ▼
[✔ Cluster ready]
```

---

## 🛠️ Step-by-step installation

> 🔁 **Every step marked "all nodes" must be run on the master AND both workers** before moving on.

### Step 1 — Hostnames & `/etc/hosts` (all nodes)

Pick a **unique** hostname per node, then make sure every node can resolve every other.

```bash
# Pick the right command for the box you are on:
sudo hostnamectl set-hostname k8s-master-node      # on master
sudo hostnamectl set-hostname k8s-worker-node-1    # on worker-1
sudo hostnamectl set-hostname k8s-worker-node-2    # on worker-2
```

Open `/etc/hosts` on **every** node and add the same block at the bottom:

```bash
sudo nano /etc/hosts
```

```
10.168.253.4   k8s-master-node
10.168.253.29  k8s-worker-node-1
10.168.253.10  k8s-worker-node-2
```

Verify:

```bash
hostname
ping -c 3 k8s-worker-node-1
```

---

### Step 2 — Disable swap (all nodes)

Kubernetes **requires** swap to be off — the kubelet refuses to start otherwise.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab   # comment it out persistently
swapon --show                                       # should print nothing
```

---

### Step 3 — Load required kernel modules (all nodes)

```bash
sudo modprobe overlay
sudo modprobe br_netfilter
```

Persist them across reboots:

```bash
sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
```

---

### Step 4 — Configure sysctl networking (all nodes)

```bash
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

`ip_forward=1` is mandatory — without it your pods cannot reach the outside world.

---

### Step 5 — Install and configure containerd (all nodes)

```bash
sudo apt update
sudo apt install -y containerd.io
```

Generate the default config and **switch cgroup driver to systemd** (this is the
#1 cause of `kubelet` start failures on Ubuntu):

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd --no-pager
```

You should see `active (running)`. If you see a sandbox image warning, that's
fine for v1.34 — we don't need to override it.

---

### Step 6 — Install Kubernetes v1.34 (all nodes)

```bash
sudo apt-get install -y curl ca-certificates apt-transport-https gnupg

# Add the Kubernetes v1.34 apt repo
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl   # prevent accidental upgrades
```

> 🔒 `apt-mark hold` is a **best practice**: kubeadm-managed clusters should
> only be upgraded with `kubeadm upgrade`, never via `apt upgrade`.

Confirm versions:

```bash
kubeadm version
kubectl version --client
```

---

### Step 7 — Initialize the control plane (master node only)

```bash
sudo kubeadm init \
  --pod-network-cidr=10.10.0.0/16 \
  --kubernetes-version=v1.34.0 \
  --control-plane-endpoint=k8s-master-node:6443
```

When `kubeadm init` finishes, it prints a **`kubeadm join ...`** line — **copy
that**, you will need it for the workers.

Let your user use `kubectl`:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes   # master should be "NotReady" until we install a CNI
```

---

### Step 8 — Install Calico CNI (master node only)

Calico v3.30 is the version compatible with Kubernetes v1.34.

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml

curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/custom-resources.yaml -O
sed -i 's|cidr: 192\.168\.0\.0/16|cidr: 10.10.0.0/16|g' custom-resources.yaml
kubectl create -f custom-resources.yaml
```

Wait ~30 s, then verify:

```bash
kubectl get nodes                     # master should now be Ready
kubectl get pods -n calico-system      # all Running
```

---

### Step 9 — Join worker nodes (on each worker)

Paste the `kubeadm join` line you saved earlier, for example:

```bash
sudo kubeadm join 10.168.253.4:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If you lost the token:

```bash
# On the master:
kubeadm token create --print-join-command
```

Confirm both workers are `Ready`:

```bash
kubectl get nodes -o wide
```

---

### Step 10 — Smoke test the cluster

```bash
kubectl create namespace demo
kubectl create deployment hello-web --image=nginx --replicas=3 -n demo
kubectl expose deployment hello-web -n demo --type=NodePort --port=80
kubectl get svc -n demo
```

Hit it from your laptop (use any worker IP from the table above):

```bash
curl http://10.168.253.29:<NodePort>
```

You should see the **"Welcome to nginx!"** page. 🎉

---

## 🆕 ETCD Backup & Restore (Demo)

> This section is written for a **live classroom demo**: it is short, scripted,
> and reproducible.

### Why ETCD?

ETCD is the **single source of truth** for your cluster — every object
(`Deployment`, `Service`, `Secret`, …) lives there. Backup it = backup your
cluster.

```
          ┌──────────────┐
          │   kubectl    │
          └──────┬───────┘
                 │ HTTPS
                 ▼
        ┌────────────────┐         ┌──────────────┐
        │   API server   │ ──────► │    ETCD      │ ◄── backup target
        └────────────────┘         └──────────────┘
```

### Where is ETCD on a kubeadm cluster?

| Item                | Location on the control-plane node        |
|---------------------|-------------------------------------------|
| Data dir            | `/var/lib/etcd`                           |
| CA cert             | `/etc/kubernetes/pki/etcd/ca.crt`         |
| Server cert         | `/etc/kubernetes/pki/etcd/server.crt`     |
| Server key          | `/etc/kubernetes/pki/etcd/server.key`     |
| Manifest            | `/etc/kubernetes/manifests/etcd.yaml`     |

### Install `etcdctl` (master only)

`etcdctl` is shipped inside the `etcd-client` apt package, or you can fetch the
binary that matches your `kubeadm`-bundled etcd:

```bash
ETCD_VER=$(kubeadm version -o short | sed 's/v//')      # e.g. 1.34.x
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-amd64.tar.gz" \
  -o /tmp/etcd.tgz
tar -xzf /tmp/etcd.tgz -C /tmp
sudo install -m 0755 /tmp/etcd-v${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
etcdctl version
```

### 1) Take a snapshot (backup)

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-snapshot.db
```

Sanity-check the snapshot:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-snapshot.db -w table
```

### 2) Schedule automatic backups (cron)

```bash
sudo tee /etc/cron.d/etcd-backup <<'EOF'
# m h dom mon dow user  command
0 * * * *   root  /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
EOF

sudo tee /usr/local/bin/etcd-backup.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TS=$(date +%Y%m%d-%H%M%S)
DEST=/var/backups/etcd
mkdir -p "$DEST"
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "$DEST/etcd-$TS.db"
# keep only last 24 hourly backups
find "$DEST" -name 'etcd-*.db' -mmin +1440 -delete
EOF

sudo chmod +x /usr/local/bin/etcd-backup.sh
```

### 3) Disaster!  Restore the snapshot

This is the part you demo to the students.

```bash
# 1. Stop the API server & etcd (they run as static pods)
sudo mv /etc/kubernetes/manifests/etcd.yaml     /etc/kubernetes/manifests/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak

# 2. Wipe the broken data dir
sudo mv /var/lib/etcd /var/lib/etcd.broken

# 3. Restore from snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-snapshot.db \
  --data-dir=/var/lib/etcd

# 4. Restart the static pods
sudo mv /etc/kubernetes/manifests/etcd.yaml.bak           /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# 5. Verify
kubectl get nodes
kubectl get ns
```

> ⚠️ The restore must happen **only on the control-plane node**, and only when
> the API server is stopped. Otherwise ETCD will reject concurrent writes.

---

## 🩹 Troubleshooting quick-fixes

| Symptom                                              | Likely cause                        | Fix                                              |
|------------------------------------------------------|-------------------------------------|--------------------------------------------------|
| `kubelet` fails with `connection refused`            | containerd cgroup driver mismatch   | Set `SystemdCgroup = true` in containerd config  |
| `NotReady` node after `kubeadm init`                 | CNI not installed                   | Install Calico (Step 8)                          |
| `kubeadm join` says token expired                    | Tokens live 24 h                    | `kubeadm token create --print-join-command`      |
| `conntrack` errors in kubelet                        | conntrack not installed             | `sudo apt install -y conntrack`                  |
| Pod stuck in `ContainerCreating`                     | Calico pod not ready                | `kubectl -n calico-system get pods` and wait     |
| `curl http://worker-ip:nodeport` fails               | Firewall on worker blocking 30000+  | `sudo ufw allow 30000:32767/tcp`                 |

---

## ⚡ Useful kubectl shortcuts

```bash
kubectl get pods -A                         # everything in every namespace
kubectl describe node <node>                # node conditions & events
kubectl get events --sort-by=.lastTimestamp # timeline of cluster events
kubectl top node                            # needs metrics-server
kubectl rollout status deploy/<name>        # watch a rollout
kubectl run nginx --image=nginx --rm -it -- /bin/bash  # one-shot debug pod
```

Add these to your `~/.bashrc` or `~/.zshrc`:

```bash
source <(kubectl completion bash)   # bash
source <(kubectl completion zsh)    # zsh (also enable: kubectl completion zsh > "${fpath[1]}/_kubectl")
alias k=kubectl
alias kg='kubectl get'
alias kd='kubectl describe'
alias kl='kubectl logs'
```

---

## 🧹 Cleanup (start fresh)

```bash
# On each node:
sudo kubeadm reset -f
sudo rm -rf $HOME/.kube
sudo rm -rf /var/lib/etcd
```

Then re-run from Step 7.

---

### 🙌 Happy clustering!

If something breaks, read the error message end-to-end, then run
`kubectl describe` and `kubectl logs` before asking — the answer is almost
always in the events.
