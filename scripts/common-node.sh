#!/usr/bin/env bash
# Runs README.md Steps 1-6 on every node.
#   Step 1 - hostname + /etc/hosts (the hosts block is rendered separately)
#   Step 2 - disable swap
#   Step 3 - load kernel modules
#   Step 4 - sysctl networking
#   Step 5 - install + configure containerd
#   Step 6 - install kubeadm/kubelet/kubectl
#
# The hostname is set by Vagrant (config.vm.hostname) so Step 1 is implicit
# here; the hosts file is rendered by render-hosts.sh.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_VERSION="${K8S_VERSION:-v1.34}"

log() { printf '\n=== %s ===\n' "$*"; }

# ---------- Step 2: disable swap ----------
log "Step 2: disable swap"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
swapon --show || true

# ---------- Step 3: kernel modules ----------
log "Step 3: load kernel modules"
modprobe overlay
modprobe br_netfilter
tee /etc/modules-load.d/k8s.conf >/dev/null <<EOF
overlay
br_netfilter
EOF

# ---------- Step 4: sysctl networking ----------
log "Step 4: sysctl networking"
tee /etc/sysctl.d/k8s.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# ---------- Step 5: install + configure containerd ----------
log "Step 5: install + configure containerd"
# containerd.io lives in Docker's apt repository, NOT in the default Ubuntu
# archives.  This block is the "install Docker apt source" prerequisite that
# Step 5 of the README forgot to mention before.  Without it, `apt install
# containerd.io` fails with "Unable to locate package".
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y containerd.io conntrack

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# Set the sandbox_image to a known tag (Calico ships its own pause, but this
# keeps the kubelet logs clean for future workloads).
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.9"|' \
  /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ---------- Step 6: install kubeadm/kubelet/kubectl ----------
log "Step 6: install kubeadm/kubelet/kubectl (${K8S_VERSION})"
apt-get install -y curl ca-certificates apt-transport-https gnupg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet
log "Common baseline ready"
