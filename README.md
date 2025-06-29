# k8s-setup
This document tells step by step to install k8s cluster

# How to Install Kubernetes on Ubuntu 24.04

Kubernetes plays an integral role in modern-day software deployment. It’s the keystone in DevOps, offering a stable and robust platform for automating the deployment and management of containerized applications.

Also popularly known as K8s, Kubernetes offers numerous benefits for your microservices infrastructure. These include high availability (automatic restart or self-healing of failed containers), auto-scaling containers, and efficient resource management.

This tutorial will demonstrate how to install Kubernetes on Ubuntu 24.04 using a master node and two worker nodes. After that, we will initialize a cluster and test its functionality by deploying a simple Nginx application across all nodes.

---

## Prerequisites

Here are the salient requirements for the installation of Kubernetes:

- Minimum of 2 instances of Ubuntu 24.04. One will act as the master node and the remaining as the worker node. For this guide, we will work with two worker nodes.
- SSH access to all the instances with sudo users configured.
- Minimum of 2GB RAM and 2 vCPUs.
- Minimum 20GB of free hard drive space.

---

## Kubernetes Lab Setup

To demonstrate the installation of Kubernetes, we have a three-cluster setup comprising a master node and two worker nodes. You can have multiple worker nodes (Kubernetes can support up to 5000 nodes). Below is our cluster setup.

| Node Name           | IP Address     |
|---------------------|----------------|
| Node 1              | k8s-master-node | 10.168.253.4   |
| Node 2              | k8s-worker-node-1 | 10.168.253.29  |
| Node 3              | k8s-worker-node-2 | 10.168.253.10  |

---

## Step 1: Configure Hostnames (All Nodes)

Start by updating the `/etc/hosts` files and specifying the IP addresses and hostnames for each node in the cluster. This will allow seamless communication between the master and worker nodes.

1. Edit the `/etc/hosts` file:

    ```bash
    sudo nano /etc/hosts
    ```

    Add the following entries:

    ```
    10.168.253.4 k8s-master-node
    10.168.253.29 k8s-worker-node-1
    10.168.253.10 k8s-worker-node-2
    ```

    Save the changes and exit.

2. Modify the hostnames for each node:

    ```bash
    sudo hostnamectl set-hostname "k8s-master-node"  # For the master node
    sudo hostnamectl set-hostname "k8s-worker-node-1"  # For worker node 1
    sudo hostnamectl set-hostname "k8s-worker-node-2"  # For worker node 2
    ```

3. To effect the hostname changes, run:

    ```bash
    sudo exec bash
    ```

4. To verify the hostname on each node:

    ```bash
    hostname
    ```

5. Ensure you can ping all the nodes from each other:

    ```bash
    ping -c 3 k8s-worker-node-1
    ping -c 3 k8s-worker-node-2
    ```

## Step 2: Disable Swap Space (All Nodes)

Disabling swap space is a standard requirement for Kubernetes. Swap degrades performance, and disabling it ensures consistent application performance without unpredictability.

1. To disable swap:

    ```bash
    sudo swapoff -a
    ```

2. To make this change permanent, comment out the swap entry in `/etc/fstab`.

3. To verify swap is disabled:

    ```bash
    swapon --show
    ```

## Step 3: Load Containerd Modules (All Nodes)

Kubernetes uses Containerd as the container runtime. Enable and load the necessary kernel modules.

1. Run the following commands to load the necessary modules:

    ```bash
    sudo modprobe overlay
    sudo modprobe br_netfilter
    ```

2. Create a configuration file to load these modules permanently:

    ```bash
    sudo tee /etc/modules-load.d/k8s.conf <<EOF
    overlay
    br_netfilter
    EOF
    ```

## Step 4: Configure Kubernetes IPv4 Networking (All Nodes)

Configure Kubernetes networking to ensure seamless communication between pods and external environments.

1. Create a Kubernetes configuration file:

    ```bash
    sudo nano /etc/sysctl.d/k8s.conf
    ```

    Add the following lines:

    ```
    net.bridge.bridge-nf-call-iptables = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward = 1
    ```

2. Apply the settings:

    ```bash
    sudo sysctl --system
    ```

## Step 5: Install Docker (All Nodes)

Install Docker, which manages containers in Kubernetes.

1. Update and install Docker:

    ```bash
    sudo apt update
    sudo apt install docker.io -y
    ```

2. Verify Docker is running:

    ```bash
    sudo systemctl status docker
    ```

3. Enable Docker to start on boot:

    ```bash
    sudo systemctl enable docker
    ```

4. To configure containerd, create the directory and configuration:

    ```bash
    sudo mkdir /etc/containerd
    sudo sh -c "containerd config default > /etc/containerd/config.toml"
    sudo sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd.service
    sudo systemctl status containerd.service
    ```

## Step 6: Install Kubernetes Components (All Nodes)

Install the Kubernetes packages:

1. Install prerequisites:

    ```bash
    sudo apt-get install curl ca-certificates apt-transport-https -y
    ```

2. Add the official Kubernetes repository:

    ```bash
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update
    ```

3. Install Kubernetes components:

    ```bash
    sudo apt install kubelet kubeadm kubectl -y
    ```

## Step 7: Initialize Kubernetes Cluster (Master Node)

Initialize the Kubernetes cluster on the master node:

```bash
sudo kubeadm init --pod-network-cidr=10.10.0.0/16
```

```bash
To configure your system to use the cluster:
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Step 8: Install Calico Network Add-on Plugin
Install the Calico network plugin for Kubernetes:

1. Apply the Tigera operator manifest:
```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
```

2.Download the custom resources manifest and update the CIDR:
```bash
curl https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml -O
sed -i 's/cidr: 192\.168\.0\.0\/16/cidr: 10.10.0.0\/16/g' custom-resources.yaml
kubectl create -f custom-resources.yaml
```

Step 9: Add Worker Nodes to the Cluster
Join each worker node to the cluster by running the join command displayed during the initialization on the master node.

```bash
kubeadm join 10.168.253.4:6443 --token <token> --discovery-token-ca-cert-hash <hash>
```

Step 10: Testing Kubernetes Cluster

To test the functionality of the cluster, deploy a simple Nginx application.

1. Create a namespace:
```bash
kubectl create namespace demo-namespace
```

2. Deploy Nginx:
```bash
kubectl create deployment my-app --image nginx --replicas 2 --namespace demo-namespace
```


3. Expose the deployment using NodePort:
```bash
kubectl expose deployment my-app -n demo-namespace --type NodePort --port 80
```

4. To verify the service:
```bash
kubectl get svc -n demo-namespace
```


5. Access the Nginx app from a worker node:
```bash
curl http://<any-worker-IP>:<node-port>
```