#!/bin/bash
# filepath: /Users/willjasen/Application Data/GitHub/proxmox-scripts/migrate-vms-with-shutdown.sh

###
### This script will migrate VMs by shutting them down completely before migration,
### and starting them up once at the target host.
### Only VMs with the tag "migrate-around" in their configuration will be migrated.
###

if [ -z "$1" ]; then
    echo "Error: No target hostname was supplied. Please provide a target hostname."
    exit 1
fi

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"

SOURCE_HOST=$(hostname)
TARGET_HOST=$1

# Get VM IDs from config files that include the tag "migrate-around"
echo -e "${GREEN}Finding VM IDs with the tag 'migrate-around'..."
VM_IDS=($(grep -l "tags:.*migrate-around" /etc/pve/qemu-server/*.conf | sed 's#.*/\([0-9]\+\)\.conf#\1#'))

if [ ${#VM_IDS[@]} -eq 0 ]; then
    echo -e "${RED}No VMs with the tag 'migrate-around' were found."
    exit 1
fi

for VM_ID in "${VM_IDS[@]}"
do
    (
    echo -e "${YELLOW}Starting migration for VM $VM_ID to ${TARGET_HOST}..."

    # Shut down the VM
    echo -e "${GREEN}Shutting down VM $VM_ID..."
    qm shutdown $VM_ID

    # Wait for the VM to shut down completely
    while qm status $VM_ID | grep -q "status: running"; do
        sleep 1
    done
    echo -e "${GREEN}VM $VM_ID is shut down."

    # Start the migration process
    echo -e "${GREEN}Migrating VM $VM_ID..."
    qm migrate $VM_ID $TARGET_HOST

    # Assuming migration completes before proceeding
    echo -e "${GREEN}Migration complete for VM $VM_ID."

    # Start the VM on the target host
    echo -e "${GREEN}Starting VM $VM_ID on target host..."
    ssh root@$TARGET_HOST "qm start $VM_ID"

    echo -e "${YELLOW}VM $VM_ID has been successfully migrated to ${TARGET_HOST}."
    ) &
done
wait

echo -e "${GREEN}All VM migrations completed."