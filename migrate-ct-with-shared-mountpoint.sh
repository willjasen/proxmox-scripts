#!/bin/sh

###
### This script will migrate an LXC container that has a shared mount point from one host to another
###

# Check if $1 is supplied
if [ -z "$1" ]; then
    echo "Error: No argument supplied. Please provide a hostname."
    exit 1
fi

HOST_TO_MIGRATE_FROM=$(hostname);
HOST_TO_MIGRATE_TO=$1;
LXC_ID=517;

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

# The script is finished
echo "Migration script completed."
