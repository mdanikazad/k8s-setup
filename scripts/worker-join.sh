#!/usr/bin/env bash
# Runs README Step 9 on each worker node by replaying the kubeadm join
# command captured by the master.  Idempotent: a node that has already
# joined (and just needs to refresh) will exit 0.

set -euo pipefail

JOIN_CMD_PATH="${JOIN_CMD_PATH:-/vagrant/join-command.sh}"

if [[ ! -f "${JOIN_CMD_PATH}" ]]; then
  echo "FATAL: ${JOIN_CMD_PATH} not found.  Bring the master up first." >&2
  exit 1
fi

# If this node is already part of the cluster, nothing to do.
if [[ -f /etc/kubernetes/kubelet.conf ]] && [[ -f /var/lib/kubelet/pki/kubelet-client-current.pem ]]; then
  echo "Worker already joined; skipping kubeadm join."
  exit 0
fi

printf '\n=== Worker joining the cluster ===\n'
bash "${JOIN_CMD_PATH}"
printf '\n=== Worker joined ===\n'
