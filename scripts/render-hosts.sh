#!/usr/bin/env bash
# Renders the documented /etc/hosts block on every node (README Step 1).
# Args: pairs of "<ip> <hostname>" — one per cluster node.

set -euo pipefail

HOSTS_FILE=/etc/hosts
MARKER="# >>> k8s lab block >>>"
END_MARKER="# <<< k8s lab block <<<"

# Remove any previous block.
if grep -q "$MARKER" "$HOSTS_FILE"; then
  sed -i "/$MARKER/,/$END_MARKER/d" "$HOSTS_FILE"
fi

{
  echo ""
  echo "$MARKER"
  for arg in "$@"; do
    ip=$(echo "$arg" | awk '{print $1}')
    host=$(echo "$arg" | awk '{print $2}')
    printf '%s\t%s\n' "$ip" "$host"
  done
  echo "$END_MARKER"
} >> "$HOSTS_FILE"

cat "$HOSTS_FILE"
