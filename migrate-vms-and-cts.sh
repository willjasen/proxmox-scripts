#!/bin/bash
# filepath: proxmox-scripts/migrate-vms-with-shutdown.sh

###
### This script will migrate VMs and CTs by shutting them down completely before migration,
### and starting them up once at the target host.
### Only VMs and CTs with the tag "migrate-around" in their configuration will be migrated.
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
MIGRATE_TAG="migrate-around"

start_time=$(date +%s)

# Get VM IDs from config files that include the tag "migrate-around"
echo -e "${GREEN}Finding VM IDs with the tag '${MIGRATE_TAG}'..."
VM_IDS=($(grep -l "tags:.*${MIGRATE_TAG}" /etc/pve/qemu-server/*.conf | sed 's#.*/\([0-9]\+\)\.conf#\1#'))

# Get CT IDs from config files that include the tag "migrate-around"
echo -e "${GREEN}Finding CT IDs with the tag '${MIGRATE_TAG}'..."
CT_IDS=($(grep -l "tags:.*${MIGRATE_TAG}" /etc/pve/lxc/*.conf | sed 's#.*/\([0-9]\+\)\.conf#\1#'))

if [ ${#VM_IDS[@]} -eq 0 ] && [ ${#CT_IDS[@]} -eq 0 ]; then
    echo -e "${RED}No VMs or CTs with the tag '${MIGRATE_TAG}' were found."
    exit 1
fi

# Migrate CTs
for CT_ID in "${CT_IDS[@]}"
do
    (
    echo -e "${YELLOW}Starting migration for CT $CT_ID to ${TARGET_HOST}..."
    pct migrate $CT_ID $TARGET_HOST
    echo -e "${GREEN}Migration complete for CT $CT_ID."
    ) &
done

# Migrate VMs
for VM_ID in "${VM_IDS[@]}"
do
    (
    echo -e "${YELLOW}Starting online migration for VM $VM_ID to ${TARGET_HOST}..."
    qm migrate $VM_ID $TARGET_HOST
    echo -e "${GREEN}Migration complete for VM $VM_ID."
    ) &
done



wait

echo -e "${GREEN}All VM and CT migrations completed."
end_time=$(date +%s)
elapsed=$(( end_time - start_time ))
echo "Script runtime: ${elapsed} seconds."