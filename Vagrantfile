# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Vagrant lab that materialises the Kubernetes setup documented in README.md.
#
# Topology (one control-plane + two workers), Ubuntu 24.04:
#   k8s-master-node    10.168.253.4
#   k8s-worker-node-1  10.168.253.29
#   k8s-worker-node-2  10.168.253.10
#
# Usage:
#   vagrant up                            # bring the lab up
#   vagrant ssh k8s-master-node           # SSH into a node
#   vagrant destroy -f                   # tear it all down
#
# The provisioning script runs the same command sequence documented in
# README.md ("Step 1" through "Step 6") so a fresh `vagrant up` ends with
# three ready-to-use nodes that only need `kubeadm init` / `kubeadm join`
# to join a cluster (driven from `k8s-setup.sh`).

NETWORK_PREFIX = "10.168.253"

NODES = {
  "k8s-master-node"   => { ip: "#{NETWORK_PREFIX}.4",  cpus: 2, memory: 2048, role: "control-plane" },
  "k8s-worker-node-1" => { ip: "#{NETWORK_PREFIX}.29", cpus: 2, memory: 2048, role: "worker" },
  "k8s-worker-node-2" => { ip: "#{NETWORK_PREFIX}.10", cpus: 2, memory: 2048, role: "worker" },
}

K8S_POD_CIDR   = "10.10.0.0/16"
K8S_VERSION    = "v1.34"
CALICO_VERSION = "v3.30.0"

Vagrant.configure("2") do |config|
  config.vm.box       = "bento/ubuntu-24.04"
  config.vm.box_check_update = false

  # Mount the repo at /vagrant so the master can drop the kubeadm join
  # command on disk and the workers can pick it up.  Anything else the
  # kubelet / CNI touches is on /var/lib, so this is safe.
  config.vm.synced_folder ".", "/vagrant"

  # Common baseline for every node (Steps 1-6 from README.md).
  config.vm.provision "shell",
    path: "scripts/common-node.sh",
    env: {
      "K8S_VERSION"    => K8S_VERSION,
      "CALICO_VERSION" => CALICO_VERSION,
    },
    run: "once"

  NODES.each do |name, attrs|
    config.vm.define name, primary: (name == "k8s-master-node") do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: attrs[:ip], virtualbox__intnet: "k8s-net"

      node.vm.provider "virtualbox" do |vb|
        vb.name   = name
        vb.cpus   = attrs[:cpus]
        vb.memory = attrs[:memory]
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      end

      # Render the node's static /etc/hosts block (Step 1).
      node.vm.provision "shell",
        path: "scripts/render-hosts.sh",
        args: NODES.map { |n, a| "#{a[:ip]} #{n}" },
        run: "once"

      # Master only: run kubeadm init + Calico + create join command.
      if attrs[:role] == "control-plane"
        node.vm.provision "shell",
          path: "scripts/master-bootstrap.sh",
          env: {
            "K8S_POD_CIDR"          => K8S_POD_CIDR,
            "K8S_VERSION"           => K8S_VERSION,
            "CALICO_VERSION"        => CALICO_VERSION,
            "API_ENDPOINT"          => "#{name}:6443",
            "APISERVER_ADVERTISE"   => attrs[:ip],
            "JOIN_CMD_PATH"         => "/vagrant/join-command.sh",
          },
          run: "once"
      end

      # Workers: run the join command produced by the master.
      if attrs[:role] == "worker"
        node.vm.provision "shell",
          path: "scripts/worker-join.sh",
          env: { "JOIN_CMD_PATH" => "/vagrant/join-command.sh" },
          run: "once"
      end
    end
  end
end