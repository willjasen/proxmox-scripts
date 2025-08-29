#!/bin/bash

###
###  This script exports VMs from a Proxmox server to another server using SSHFS.
###

# Color variables
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# array of VM IDs to copy
VMIDS=(701 702 703 706 707 709 710)

# Remote server details
SSH_USER="willjasen"
REMOTE_HOST="nathaniels-mac-mini"
REMOTE_DIR="/Users/willjasen/from-pve417"
LOCAL_MOUNT="/mnt/to-$REMOTE_HOST"

# Install dependencies if not already installed
if ! command -v sshfs &> /dev/null; then
  apt-get update && apt-get install -y sshfs
fi

# Setup SSHFS mount
mkdir -p $LOCAL_MOUNT
sshfs $SSH_USER@$REMOTE_HOST:$REMOTE_DIR $LOCAL_MOUNT
df -Th $LOCAL_MOUNT

# Export the VMs
for id in "${VMIDS[@]}"; do
  echo -e "${GREEN}Exporting VM $id ...${NC}"
  # Export a VM
  qemu-img convert -v -p -O qcow2 -c -o compression_type=zstd \
    /dev/lvm-417/vm-${id}-disk-0 \
    $LOCAL_MOUNT/vm-${id}-disk-0.qcow2
done
