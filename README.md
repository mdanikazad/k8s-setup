# Kubernetes v1.34 — Hands-On Lab Setup Guide

> **Audience:** DevOps students who are new to Kubernetes and want a **working**
> multi-node cluster they can build, break, and fix on their own machines.
> **OS:** Ubuntu 24.04 LTS on every node.

---

## Table of Contents

1. [What you will build](#what-you-will-build)
2. [Lab topology](#lab-topology)
3. [Pre-flight checklist](#pre-flight-checklist)
4. [Step-by-step installation](#step-by-step-installation)
   - [Step 1 — Hostnames and /etc/hosts](#step-1--hostnames-and-etchosts-all-nodes)
   - [Step 2 — Disable swap](#step-2--disable-swap-all-nodes)
   - [Step 3 — Load kernel modules](#step-3--load-required-kernel-modules-all-nodes)
   - [Step 4 — Sysctl networking](#step-4--configure-sysctl-networking-all-nodes)
   - [Step 5 — Install containerd](#step-5--install-and-configure-containerd-all-nodes)
   - [Step 6 — Install Kubernetes v1.34](#step-6--install-kubernetes-v134-all-nodes)
   - [Step 7 — Initialize the control plane](#step-7--initialize-the-control-plane-master-node-only)
   - [Step 8 — Install Calico CNI](#step-8--install-calico-cni-master-node-only)
   - [Step 9 — Join worker nodes](#step-9--join-worker-nodes-on-each-worker)
   - [Step 10 — Smoke test](#step-10--smoke-test-the-cluster)
4. [Vagrant lab in this repository](#vagrant-lab-in-this-repository)
5. [ETCD Backup and Restore (Demo)](#etcd-backup-and-restore-demo)
6. [Cluster Upgrade (v1.34 -> v1.35)](#cluster-upgrade-v134--v135)
7. [Troubleshooting quick-fixes](#troubleshooting-quick-fixes)
8. [Useful kubectl shortcuts](#useful-kubectl-shortcuts)
9. [Cleanup](#cleanup-start-fresh)
5. [ETCD Backup and Restore (Demo)](#etcd-backup-and-restore-demo)
6. [Cluster Upgrade (v1.34 -> v1.35)](#cluster-upgrade-v134--v135)
7. [Troubleshooting quick-fixes](#troubleshooting-quick-fixes)
8. [Useful kubectl shortcuts](#useful-kubectl-shortcuts)
9. [Cleanup](#cleanup-start-fresh)

---

## What you will build

By the end of this guide you will have:

- A **Kubernetes v1.34** cluster running on **three Ubuntu 24.04 VMs**.
- One **control-plane node** + two **worker nodes** (production-grade pattern).
- The **Calico** CNI for pod networking.
- An end-to-end smoke test (Nginx deployment + NodePort service).
- A repeatable **ETCD backup & restore** workflow you can demonstrate live.

---

## Lab topology

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

> **Tip:** You can use VirtualBox, VMware Fusion, Multipass (`multipass launch`), or cloud VMs — anything that gives you three Ubuntu 24.04 instances with bridged or host-only networking.

---

## Pre-flight checklist

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
[OK] Cluster ready
```

---

## Step-by-step installation

> **Every step marked "all nodes" must be run on the master AND both workers** before moving on.

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

> **Plain-English version:**
> A **container** is just a tiny box that holds your application and everything
> it needs to run. But who *opens* those boxes? That's the job of a
> **container runtime**. `containerd` is the runtime Kubernetes uses.
>
> Think of it like this:
>
> ```
>   kubelet (manager)  --asks-->  containerd (worker)  --opens-->  [box] [box] [box]
> ```
>
> Without a working runtime, the kubelet has nothing to start, so pods never
> appear. We also tell containerd to use the **same cgroup driver as the OS**
> (`systemd`). A *cgroup* is just a way to say "this process is only allowed to
> use this much CPU and RAM". If kubelet and containerd disagree on who's
> measuring, the kubelet fails to start — this is the **#1 cause of install
> failures** on Ubuntu, so we fix it up front.

```bash
# The containerd.io package is published by Docker, so we must add Docker's
# apt repository first.  (containerd.io is NOT in the default Ubuntu archives.)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor \
  -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y containerd.io
```

Generate the default config and **switch the cgroup driver to systemd**:

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd --no-pager
```

You should see `active (running)`. Quick sanity check:

```bash
sudo ctr version            # client & server version printed
sudo ctr info | grep SystemdCgroup   # should print: SystemdCgroup: true
```

> **Vagrant / VirtualBox tip:** if you ever see a warning about
> `sandbox_image`, containerd is just complaining that the `pause` image is
> missing. It is harmless *for Calico* (Calico ships its own pause), but if you
> want a clean log you can run:
>
> ```bash
> sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.9"|' \
>   /etc/containerd/config.toml
> sudo systemctl restart containerd
> ```

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

> **Note:** `apt-mark hold` is a **best practice**: kubeadm-managed clusters should
> only be upgraded with `kubeadm upgrade`, never via `apt upgrade`.

Confirm versions:

```bash
kubeadm version
kubectl version --client
```

---

### Step 7 — Initialize the control plane (master node only)

> **Plain-English version:**
> `kubeadm init` is the command that **turns this empty Ubuntu VM into a
> Kubernetes master**. It does three big things:
> 1. Generates certificates and keys for the cluster.
> 2. Boots up the *control plane* components (API server, scheduler,
>    controller manager, etcd) as static pods.
> 3. Prints a `kubeadm join` line that you will later paste on the workers.
>
> Think of `kubeadm init` as the "switch this VM on, make it the boss" command.

```bash
# Discover the latest patch in the 1.34 stream (e.g. v1.34.11)
KUBE_LATEST=$(curl -fsSL https://dl.k8s.io/release/stable-1.34.txt)
echo "Will initialize Kubernetes ${KUBE_LATEST}"

# IMPORTANT: --apiserver-advertise-address MUST be the **private-network**
# interface of the master (10.168.253.4 in this lab).  If you let kubeadm
# auto-detect it, kubeadm will pick eth0 (the NAT / internet interface,
# 10.0.2.15 in Vagrant), which is unreachable from the worker nodes.  The
# symptom of getting this wrong is that `kubectl get nodes` works on the
# master but pods on workers can't reach the kubernetes service (the
# ClusterIP 10.96.0.1 gets DNAT'd to 10.0.2.15, which is not routed between
# Vagrant VMs) and `calico-node` gets stuck in Init:CrashLoopBackOff with
# "Unable to create token for CNI kubeconfig: dial tcp 10.96.0.1:443:
# connect: connection refused".
sudo kubeadm init \
  --pod-network-cidr=10.10.0.0/16 \
  --kubernetes-version=${KUBE_LATEST} \
  --control-plane-endpoint=k8s-master-node:6443 \
  --apiserver-advertise-address=10.168.253.4
```

Sanity-check that kubeadm picked the right interface:

```bash
sudo kubectl -n default get endpoints kubernetes -o yaml \
  | grep -A1 'addresses:' | head -2
# MUST show: ip: 10.168.253.4 (NOT 10.0.2.15)
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

> **Plain-English version:**
> After `kubeadm init` finishes, the master says *"I have no idea how to talk
> to other nodes"* — your cluster is **NotReady**. A **CNI (Container Network
> Interface)** plugin is the "phone line" that gives every pod an IP address
> and lets pods on different nodes chat with each other.
>
> We use **Calico** because it is the most common CNI in production:
>
> ```
>   Pod A (node-1)  -->  Calico  -->  Pod B (node-2)
>        10.10.0.5                10.10.0.17
> ```
>
> Calico also enforces **network policies** (firewall rules between pods),
> which we won't touch today but is why production teams pick it.
>
> Calico v3.30 is the version compatible with Kubernetes v1.34.

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml

# Wait for the operator to install its CRDs (Installation, APIServer, ...).
# Running the next kubectl create immediately usually fails with
#   "no matches for kind 'Installation' in version 'operator.tigera.io/v1'
#    ensure CRDs are installed first"
kubectl wait --for=condition=Available --timeout=120s \
  deployment/tigera-operator -n tigera-operator

curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/custom-resources.yaml -O
sed -i 's|cidr: 192\.168\.0\.0/16|cidr: 10.10.0.0/16|g' custom-resources.yaml
kubectl create -f custom-resources.yaml
```

> **What did `sed` just do?** Calico's default config tells the CNI to use
> `192.168.0.0/16` for pod IPs. But our `kubeadm init` said *"pods will live in
> `10.10.0.0/16`"*. They have to match, otherwise pods will not get the IPs we
> expect. The `sed` rewrites that one line so both files agree.

Wait ~30 s, then verify. This is the moment of truth:

```bash
kubectl get nodes                     # master should now be Ready
kubectl get pods -n calico-system      # all Running
```

Watch them come up live:

```bash
kubectl -n calico-system get pods -w
# press Ctrl+C when you see everything is Running
```

A second, deeper check — make sure the kube-system pods are also happy:

```bash
kubectl get pods -A
```

> **Vagrant / VirtualBox tip:** the most common reason
> `calico-node` stays in `Init:CrashLoopBackOff` on a worker is **not** a
> Calico IP-detection problem.  It is that the worker cannot reach the
> cluster's kubernetes service (10.96.0.1:443), which kube-proxy DNATs to
> the master's advertised address.  If `kubeadm init` was run **without**
> `--apiserver-advertise-address=<private-IP>`, kubeadm auto-detected the
> master's eth0 (NAT) address (10.0.2.15) which is **not routable between
> Vagrant VMs**.  You can confirm with:
>
> ```bash
> # On the master, after the workers have joined:
> sudo kubectl -n default get endpoints kubernetes -o yaml \
>   | grep -A1 'addresses:'
> # MUST show: ip: 10.168.253.4
> # If it shows 10.0.2.15 instead, kubeadm init was run without
> # --apiserver-advertise-address and the workers will never be Ready.
> ```
>
> The fix is to **re-init the master** (see Step 7) with
> `--apiserver-advertise-address=10.168.253.4`, then re-join the workers.
> You do NOT need to mess with `OperatorConfiguration` /
> `nodeAddressAutodetectionIPv4` for this lab.

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

You should see the **"Welcome to nginx!"** page.

---

## Vagrant lab in this repository

The repository ships a ready-to-go **Vagrant lab** that builds the exact
three-VM topology described above (1 control-plane + 2 workers, Ubuntu
24.04, fixed IPs).  It uses VirtualBox as the provider.

```bash
vagrant up                        # ~5 min on a fast laptop
vagrant ssh k8s-master-node       # SSH into any node
vagrant destroy -f                # tear it down
```

The provisioning script (see `scripts/`) implements every step of this
guide automatically.  If you would rather go through the steps by hand so
you can see exactly what happens, follow the **Step-by-step installation**
section above on each VM.

Files in this lab:

- `Vagrantfile` - declares the three VMs and their fixed IPs.
- `scripts/common-node.sh` - Steps 1-6 (hostnames, swap, kernel modules,
  sysctl, containerd, kubeadm/kubelet/kubectl).
- `scripts/master-bootstrap.sh` - Step 7-8 (kubeadm init + Calico).
- `scripts/worker-join.sh` - Step 9 (`kubeadm join`).
- `scripts/install-containerd.sh` - installs `containerd.io` from the
  Docker apt repository (Step 5 prerequisite).

---

## ETCD Backup and Restore (Demo)

> This section is written for a **live classroom demo**: it is short, scripted,
> and reproducible.

### Why ETCD?

> **Plain-English version:** Imagine your cluster is a spreadsheet. Every
> `Deployment`, `Service`, `Secret`, even the list of nodes themselves — all are
> rows in that spreadsheet. **ETCD is that spreadsheet.** Lose ETCD and the
> cluster "forgets" everything. Take a backup of ETCD and you can rebuild the
> whole cluster even on a fresh VM.
>
> So: **backup ETCD = backup your cluster.**

```
          ┌──────────────┐
          │   kubectl    │     "Hey API server, list my pods"
          └──────┬───────┘
                 │ HTTPS
                 ▼
        ┌────────────────┐         ┌──────────────┐
        │   API server   │ ──────► │    ETCD      │  ◄── this is what we back up
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

> **Plain-English version:** `etcdctl` is the **CLI tool** that lets us talk to
> ETCD directly. Think of it like a MySQL client for a database.

```bash
ETCD_VER=$(kubeadm version -o short | sed 's/v//')      # e.g. 1.34.x
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-amd64.tar.gz" \
  -o /tmp/etcd.tgz
tar -xzf /tmp/etcd.tgz -C /tmp
sudo install -m 0755 /tmp/etcd-v${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
etcdctl version
```

### 1) Take a snapshot (backup)

> **Plain-English version:** A *snapshot* is a frozen copy of the database file
> at one point in time — exactly like Windows System Restore or a Mac Time
> Machine snapshot. If the cluster breaks tomorrow, we will replay this
> snapshot and we'll be back to "now".

```bash
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-snapshot.db
```

Quick explanation of the flags:

| Flag                | What it means                                              |
|---------------------|------------------------------------------------------------|
| `--endpoints=...`   | Where ETCD is listening (master's localhost in our case).  |
| `--cacert / --cert / --key` | ETCD uses TLS; these three prove we are allowed to talk to it. |
| `snapshot save`     | "Copy the whole database to a file and stop, that's it."   |

Sanity-check the snapshot (no risk — it only reads the file):

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-snapshot.db -w table
```

You should see a row showing the **file size, hash and revision** — proof the
snapshot is healthy.

> **Vagrant tip:** after a successful backup, **copy the snapshot out of
> the VM** so it survives even if the VM dies:
>
> ```bash
> sudo cp /opt/etcd-snapshot.db /vagrant/etcd-snapshot-$(date +%F).db
> ls -lh /vagrant/etcd-snapshot-*.db
> ```

### 2) Schedule automatic backups (cron)

> **Plain-English version:** You don't want to remember to take a snapshot
> every day. `cron` is Linux's "do this automatically at a fixed time"
> scheduler. We will tell it to run the snapshot script **every hour** and
> keep only the last 24 backups so the disk doesn't fill up.

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

Verify the cron job is registered:

```bash
cat /etc/cron.d/etcd-backup
systemctl status cron --no-pager
```

> **Vagrant / VirtualBox note:** inside a `vagrant halt` / `vagrant up`
> cycle the system clock can jump. If you see "took a snapshot from the
> future" warnings, just delete the suspicious file:
> `sudo rm /var/backups/etcd/etcd-2099-*`.

### 3) Disaster!  Restore the snapshot

> **Plain-English version:** This is the moment we pretend our cluster crashed.
> We will:
>
> 1. Stop the services that are using ETCD (so nobody else is writing to it).
> 2. Throw away the broken database.
> 3. Replay the snapshot into a fresh, empty database.
> 4. Turn the services back on.
> 5. The cluster is now exactly where the snapshot was taken.
>
> It is the same idea as restoring a corrupt Microsoft Word document from a
> `.docx` backup: stop the app, replace the file, restart the app.

This is the part you demo to the students.

```bash
# 1. Stop the API server & etcd (they run as static pods)
sudo mv /etc/kubernetes/manifests/etcd.yaml     /etc/kubernetes/manifests/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
sleep 5                                       # give kubelet a moment to stop the pods

# 2. Wipe the broken data dir (keep a copy just in case)
sudo mv /var/lib/etcd /var/lib/etcd.broken

# 3. Restore from snapshot into a fresh data dir
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-snapshot.db \
  --data-dir=/var/lib/etcd

# 4. Restart the static pods by moving manifests back
sudo mv /etc/kubernetes/manifests/etcd.yaml.bak           /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# 5. Wait ~30 s and verify
sleep 30
kubectl get nodes
kubectl get ns
```

If everything came back, you should see the same nodes, namespaces, deployments
and services that existed at the time of the snapshot — **including the demo
Nginx we deployed earlier**.

> **Warning:** The restore must happen **only on the control-plane node**, and only when
> the API server is stopped. Otherwise ETCD will reject concurrent writes.
>
> **Warning:** Workers keep running during the restore, but they will temporarily show
> `NotReady` because the API server is down. That is normal — they recover on
> their own.

> **Warning:** The restore must happen **only on the control-plane node**, and only when
> the API server is stopped. Otherwise ETCD will reject concurrent writes.

---

## Cluster Upgrade (v1.34 -> v1.35)

> **Plain-English version:** Kubernetes ships ~3 minor releases per year, and
> each new minor (e.g. v1.34 -> v1.35) brings bug fixes and new features.
> Clusters are upgraded **one minor version at a time**, on the
> **control-plane first**, then on each **worker**, then the CNI. You cannot
> skip a minor (v1.34 -> v1.36 is not supported).
>
> The general order is:
>
> ```
>    1. ETCD snapshot (safety net)
>    2. Upgrade apt repo from v1.34 to v1.35
>    3. apt-mark unhold, install new kubeadm, kubeadm upgrade apply
>    4. Install new kubelet/kubectl, restart kubelet
>    5. Repeat (3)+(4) on every worker
>    6. Upgrade Calico to a v1.35-compatible version
>    7. Verify
> ```

### Pre-flight

Before you touch anything:

- Read the upstream release notes: <https://kubernetes.io/blog/YYYY/MM/release-of-Kubernetes-v1-35/>
  (search for the published v1.35 announcement).
- Read Calico's compatibility matrix for v1.35 (Calico v3.31.x is the
  v1.35-compatible stream at the time of writing).
- **Take a fresh ETCD snapshot right now.** The upgrade is usually safe, but
  the snapshot is your one-click undo:

  ```bash
  sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /opt/etcd-pre-v135.db

  sudo cp /opt/etcd-pre-v135.db /vagrant/etcd-pre-v135-$(date +%F).db
  ```

- Confirm your current version:

  ```bash
  kubectl get version
  ```

### 1) Control-plane upgrade (master only)

Switch the apt repo to the v1.35 stream and install the new components:

```bash
# Discover the latest patch in the 1.35 stream (e.g. v1.35.8)
KUBE_LATEST=$(curl -fsSL https://dl.k8s.io/release/stable-1.35.txt)
echo "Upgrading to Kubernetes ${KUBE_LATEST}"

# Swap the apt source list from v1.34 -> v1.35
sudo sed -i 's|/core:/stable:/v1.34/|/core:/stable:/v1.35/|' \
  /etc/apt/sources.list.d/kubernetes.list

sudo apt update

# Release the hold so apt will install the new packages
sudo apt-mark unhold kubeadm kubelet kubectl

# Install the matching versions (kubeadm first, then kubelet+kubectl)
sudo apt install -y kubeadm=${KUBE_LATEST}-1.1 kubelet=${KUBE_LATEST}-1.1 kubectl=${KUBE_LATEST}-1.1

# Re-hold so we never auto-upgrade again
sudo apt-mark hold kubeadm kubelet kubectl

# Drain workloads running on the control plane (best practice, optional on single CP)
sudo kubectl drain k8s-master-node --ignore-daemonsets --delete-emptydir-data || true

# Plan + apply the upgrade
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply ${KUBE_LATEST} -y

# Restart kubelet to pick up the new binary
sudo systemctl restart kubelet
```

> **Note:** the apt package suffix `-1.1` matches the current
> `pkgs.k8s.io` packaging. If your upgrade complains about version
> `not found`, run `apt-cache madison kubeadm` and use the version string it
> prints (e.g. `1.35.8-1.1`).

### 2) Worker upgrade (each worker, one at a time)

For each worker, repeat:

```bash
# From the master: drain the worker so new pods land elsewhere
kubectl drain k8s-worker-node-1 --ignore-daemonsets --delete-emptydir-data

# On the worker:
KUBE_LATEST=$(curl -fsSL https://dl.k8s.io/release/stable-1.35.txt)
sudo sed -i 's|/core:/stable:/v1.34/|/core:/stable:/v1.35/|' \
  /etc/apt/sources.list.d/kubernetes.list
sudo apt update

sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt install -y kubeadm=${KUBE_LATEST}-1.1 kubelet=${KUBE_LATEST}-1.1 kubectl=${KUBE_LATEST}-1.1
sudo apt-mark hold kubeadm kubelet kubectl

sudo kubeadm upgrade node    # workers do NOT use "apply"
sudo systemctl restart kubelet

# Back on the master: uncordon the worker
kubectl uncordon k8s-worker-node-1
```

Repeat the block for `k8s-worker-node-2`.

### 3) Upgrade Calico CNI

Calico v3.30 (used for v1.34) is **not** compatible with v1.35. Bump to
Calico v3.31:

```bash
# Discover the latest Calico 3.31 patch (e.g. v3.31.2)
CALICO_VER=$(curl -fsSL https://api.github.com/repos/projectcalico/calico/releases/latest \
            | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])")
echo "Upgrading Calico to ${CALICO_VER}"

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml

curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/custom-resources.yaml -O
# Keep the same CIDR we used originally; do NOT re-run the sed that rewrites 192.168 -> 10.10
kubectl apply -f custom-resources.yaml

kubectl -n calico-system rollout restart deployment tigera-operator
kubectl -n calico-system rollout status  daemonset calico-node --timeout=180s
```

> **Why this step matters:** Kubernetes validates the **kube-apiserver
> version** of every component talking to it. If Calico is too old, its
> pods will fail to register with the new API server and you'll see
> `NotReady` nodes with no obvious cause.

### 4) Verify the cluster

```bash
kubectl get nodes -o wide                       # all v1.35.x
kubectl get pods -A                             # all Running
kubectl get hpa,svc,deploy -A                   # workloads still exist
kubectl version                                 # server & client both v1.35.x
```

### 5) Roll back (if anything goes wrong)

The ETCD snapshot you took in **Pre-flight** is your undo button. The
procedure is the same as the one in the **ETCD Backup and Restore (Demo)**
section above:

1. Stop the API server + etcd static pods (`mv` manifests to `.bak`).
2. `sudo mv /var/lib/etcd /var/lib/etcd.broken`
3. `sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-pre-v135.db --data-dir=/var/lib/etcd`
4. Move manifests back, wait, verify.

> **Warning:** Rolling back ETCD restores the *cluster state* to the moment
> of the snapshot, but it does **not** downgrade the kubelet binary on the
> nodes. If the rollback leaves nodes NotReady, re-install the previous
> kubelet:
>
> ```bash
> sudo apt-mark unhold kubelet
> sudo apt install -y kubelet=1.34.11-1.1 kubectl=1.34.11-1.1
> sudo apt-mark hold kubelet
> sudo systemctl restart kubelet
> ```

### Upgrade cheat-sheet

| Step | Where | Command(s) | Notes |
|------|-------|------------|-------|
| Snapshot | master | `etcdctl snapshot save` | Always first |
| Switch repo | all nodes | `sed` + `apt update` | v1.34 -> v1.35 |
| Upgrade kubeadm | all nodes | `apt install kubeadm=...` | unhold first |
| Upgrade control plane | master | `kubeadm upgrade apply` | drains CP, single CP optional |
| Upgrade worker | each worker | `kubeadm upgrade node` | drain -> upgrade -> uncordon |
| Upgrade CNI | master | `kubectl apply -f calico.yaml` | v3.30 -> v3.31 |
| Verify | master | `kubectl get nodes -o wide` | all v1.35.x |

---

## Troubleshooting quick-fixes

| Symptom                                              | Likely cause                        | Fix                                              |
|------------------------------------------------------|-------------------------------------|--------------------------------------------------|
| `apt install containerd.io` says "Unable to locate package" | Docker apt source not added | Step 5 now adds `download.docker.com/linux/ubuntu` first |
| `kubelet` fails with `connection refused`            | containerd cgroup driver mismatch   | Set `SystemdCgroup = true` in containerd config  |
| `NotReady` node after `kubeadm init`                 | CNI not installed                   | Install Calico (Step 8)                          |
| `kubeadm join` says token expired                    | Tokens live 24 h                    | `kubeadm token create --print-join-command`      |
| `conntrack` errors in kubelet                        | conntrack not installed             | `sudo apt install -y conntrack`                  |
| `calico-node` stuck in `Init:CrashLoopBackOff` on workers | Master advertises NAT IP (`10.0.2.15`) instead of private IP | Re-run `kubeadm init` with `--apiserver-advertise-address=<private-IP>` |
| `kubectl create -f custom-resources.yaml` says "no matches for kind Installation" | Operator has not installed its CRDs yet | `kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator` before applying custom-resources |
| Pod stuck in `ContainerCreating`                     | Calico pod not ready                | `kubectl -n calico-system get pods` and wait     |
| `curl http://worker-ip:nodeport` fails               | Firewall on worker blocking 30000+  | `sudo ufw allow 30000:32767/tcp`                 |

---

## Useful kubectl shortcuts

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

## Cleanup (start fresh)

```bash
# On each node:
sudo kubeadm reset -f
sudo rm -rf $HOME/.kube
sudo rm -rf /var/lib/etcd
```

Then re-run from Step 7.

---

### Happy clustering!

If something breaks, read the error message end-to-end, then run
`kubectl describe` and `kubectl logs` before asking — the answer is almost
always in the events.
