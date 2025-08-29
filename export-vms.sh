#!/bin/bash

# Color variables
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# array of VM IDs you want to copy
VMIDS=(702 703 703 705 706 707 709 710)

for id in "${VMIDS[@]}"; do
  echo -e "${GREEN}Exporting VM $id ...${NC}"
  qemu-img convert -p -O qcow2 -c -o compression_type=zstd \
    /dev/lvm-417/vm-${id}-disk-0 \
    /mnt/to-pve2/vm-${id}-disk-0.qcow2
done
