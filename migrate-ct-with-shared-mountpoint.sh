#!/bin/bash

###
### This script will migrate LXC containers that have shared mount points from one host to another
### This script assumes that the shared mount points of all containers are at "mp8"
###

# Check if $1 (hostname) is supplied
if [ -z "$1" ]; then
    echo "Error: No target hostname was supplied. Please provide a target hostname."
    exit 1
fi

HOST_TO_MIGRATE_FROM=$(hostname)
HOST_TO_MIGRATE_TO=$1

# Define the LXC IDs manually
LXC_IDS=("515" "517" "533")

# Loop through each LXC ID
for LXC_ID in "${LXC_IDS[@]}"
do
    echo "Starting migration of LXC container $LXC_ID..."

    # Comment out the bind mount in the LXC config
    sed -i 's|^mp8|# &|' /etc/pve/nodes/$HOST_TO_MIGRATE_FROM/lxc/$LXC_ID.conf

    # Start the migration process
    pct migrate $LXC_ID $HOST_TO_MIGRATE_TO

    # Wait for the migration to complete
    while pct status $LXC_ID | grep -q 'status:'; do
        sleep 5
    done

    # On the target host, reactivate the shared mount point
    ssh root@$HOST_TO_MIGRATE_TO "sed -i 's/# mp8%3A/mp8:/g' /etc/pve/lxc/$LXC_ID.conf"
    echo "LXC container $LXC_ID has been successfully migrated to $HOST_TO_MIGRATE_TO"
done

# The script is finished
echo "All migrations completed."
