#!/usr/bin/env bash
# Runs README Steps 7-8 on the control-plane node:
#   Step 7 - kubeadm init
#   Step 8 - install Calico CNI
# Writes the kubeadm join command to $JOIN_CMD_PATH so workers can run it.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_POD_CIDR="${K8S_POD_CIDR:-10.10.0.0/16}"
K8S_VERSION="${K8S_VERSION:-v1.34}"
CALICO_VERSION="${CALICO_VERSION:-v3.30.0}"
API_ENDPOINT="${API_ENDPOINT:-k8s-master-node:6443}"
APISERVER_ADVERTISE="${APISERVER_ADVERTISE:-10.168.253.4}"
JOIN_CMD_PATH="${JOIN_CMD_PATH:-/vagrant/join-command.sh}"

log() { printf '\n=== %s ===\n' "$*"; }

log "Step 7a: detect latest patch in ${K8S_VERSION} stream"
KUBE_LATEST=$(curl -fsSL "https://dl.k8s.io/release/stable-1.34.txt")
echo "Will initialise Kubernetes ${KUBE_LATEST}"

log "Step 7b: kubeadm init"
kubeadm init \
  --pod-network-cidr="${K8S_POD_CIDR}" \
  --kubernetes-version="${KUBE_LATEST}" \
  --control-plane-endpoint="${API_ENDPOINT}" \
  --apiserver-advertise-address="${APISERVER_ADVERTISE}"

log "Step 7c: configure kubectl for vagrant user"
mkdir -p /home/vagrant/.kube
cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

log "Step 7d: capture join command"
kubeadm token create --print-join-command > "${JOIN_CMD_PATH}.tmp"
chmod +x "${JOIN_CMD_PATH}.tmp"
mv "${JOIN_CMD_PATH}.tmp" "${JOIN_CMD_PATH}"

log "Step 7e: sanity-check endpoints point at the private network IP"
ENDPOINT_IP=$(kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}')
if [[ "${ENDPOINT_IP}" != "${APISERVER_ADVERTISE}" ]]; then
  echo "FATAL: kubernetes endpoint IP is ${ENDPOINT_IP}, expected ${APISERVER_ADVERTISE}." >&2
  echo "       Worker nodes will not be able to reach the API server." >&2
  exit 1
fi
echo "Endpoints OK (${ENDPOINT_IP})."

log "Step 8a: install tigera-operator ${CALICO_VERSION}"
kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

log "Step 8b: wait for the operator to install its CRDs"
# The deployment reaches Available as soon as the operator's main container
# starts, but its CRDs (Installation, APIServer, ...) are registered by the
# operator's *init container*, which the deployment-condition check does
# not cover.  Wait for the actual CRDs to be observable.
for i in $(seq 1 60); do
  if kubectl --kubeconfig=/etc/kubernetes/admin.conf get crd \
        installations.operator.tigera.io >/dev/null 2>&1; then
    echo "Operator CRDs registered after ${i}s."
    break
  fi
  sleep 1
done
if ! kubectl --kubeconfig=/etc/kubernetes/admin.conf get crd \
     installations.operator.tigera.io >/dev/null 2>&1; then
  echo "FATAL: Operator CRDs were not installed in time." >&2
  exit 1
fi

log "Step 8c: download + patch custom-resources.yaml"
curl -fsSL \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
  -o /tmp/custom-resources.yaml

# Patch the default IPPool CIDR (192.168.0.0/16) to the one kubeadm was
# told to use.  This matches README Step 8 verbatim.
sed -i 's|cidr: 192\.168\.0\.0/16|cidr: 10.10.0.0/16|g' /tmp/custom-resources.yaml

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/custom-resources.yaml

log "Master bootstrap complete.  Calico will take ~60s to come up on the master."
