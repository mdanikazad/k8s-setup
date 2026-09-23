#!/bin/bash
# Install containerd.io via the Docker apt repository (the only source for
# the package in question).  Runs as root; meant to be invoked via
# `sudo bash ...` from a vagrant ssh session.
set -e
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
gpg --dearmor < /etc/apt/keyrings/docker.asc > /etc/apt/keyrings/docker.gpg
chmod 644 /etc/apt/keyrings/docker.gpg
arch=$(dpkg --print-architecture)
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
apt-get update
apt-get install -y containerd.io
