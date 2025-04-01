#!/bin/bash
# filepath: proxmox-scripts/migrate-vms-with-shutdown.sh

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
MIGRATE_TAG="migrate-around"

start_time=$(date +%s)

# Get VM IDs from config files that include the tag "migrate-around"
echo -e "${GREEN}Finding VM IDs with the tag '${MIGRATE_TAG}'..."
VM_IDS=($(grep -l "tags:.*${MIGRATE_TAG}" /etc/pve/qemu-server/*.conf | sed 's#.*/\([0-9]\+\)\.conf#\1#'))

if [ ${#VM_IDS[@]} -eq 0 ]; then
    echo -e "${RED}No VMs with the tag '${MIGRATE_TAG}' were found."
    exit 1
fi

# Retrieve replication jobs for each VM tagged with '${MIGRATE_TAG}'
echo -e "${BLUE}Retrieving replication jobs for VMs tagged '${MIGRATE_TAG}'..."
for VM_ID in "${VM_IDS[@]}"; do
    replication_jobs=$(pvesh get /nodes/$(hostname)/replication --output-format json | jq -r --arg vmid "$VM_ID" --arg target "$TARGET_HOST" 'map(select((.guest|tostring)==$vmid and .target==$target)) | .[]')
    echo -e "${BLUE}VM $VM_ID replication jobs: ${replication_jobs}"
    # Kick off replication
    replication_info=$(pvesh get /nodes/$(hostname)/replication --output-format json | jq -r --arg target "$TARGET_HOST" --arg vmid "$VM_ID" 'map(select(.target == $target and (.guest|tostring) == $vmid)) | .[0].id')
    if [ -n "$replication_info" ] && [ "$replication_info" != "null" ]; then
        echo -e "${GREEN}Kicking off replication for VM $VM_ID..."
        api_endpoint="/nodes/$(hostname)/replication/$replication_info/schedule_now"
        pvesh create "$api_endpoint"
    else
        echo -e "${RED}No replication info found for VM $VM_ID to kick off replication."
    fi
done
sleep 60

# Replicate all replication jobs to target host before the main loop
# echo -e "${YELLOW}Scheduling replication jobs for all VMs going to ${TARGET_HOST}..."
# for VM_ID in "${VM_IDS[@]}"; do
#     echo -e "${YELLOW}Retrieving replication info for VM $VM_ID..."
#     replication_info=$(pvesh get /nodes/$(hostname)/replication --output-format json | jq -r --arg target "$TARGET_HOST" --arg vmid "$VM_ID" 'map(select(.target == $target and (.guest|tostring) == $vmid)) | .[0].id')
    
#     if [ -n "$replication_info" ] && [ "$replication_info" != "null" ]; then
#         echo -e "${GREEN}Scheduling replication for VM $VM_ID..."
#         api_endpoint="/nodes/$(hostname)/replication/$replication_info/schedule_now"
#         pvesh create "$api_endpoint"
#     else
#         echo -e "${RED}No replication info found for target $TARGET_HOST for VM $VM_ID."
#     fi
# done
# Optionally wait for all replication jobs to complete ...

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
end_time=$(date +%s)
elapsed=$(( end_time - start_time ))
echo "Script runtime: ${elapsed} seconds."