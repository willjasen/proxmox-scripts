#!/bin/sh

### This script will migrate an LXC container that has a shared mount point from one host to another

HOST_TO_MIGRATE_FROM=pve2;
HOST_TO_MIGRATE_TO=pve1;
LXC_ID=517;

# Comment out the bind mount in the LXC config
sed -i 's|^mp8: /mnt/pve/cephfs--hdd--lowT/data/syncthing/Media,mp=/mnt/host/Media|# &|' /etc/pve/nodes/$HOST_TO_MIGRATE_FROM/lxc/$LXC_ID.conf

# Start the migration process
pct migrate $LXC_ID $HOST_TO_MIGRATE_TO &

# Wait for the migration to complete
while pct status $LXC_ID | grep -q 'status: running'; do
    sleep 5
done

echo "LXC container $LXC_ID has been successfully migrated to $HOST_TO_MIGRATE_TO"

# (Optional) Re-enable the bind mount on the target host after migration
# Uncomment this if you want to automate the re-enabling of the bind mount on the destination host
# ssh root@$HOST_TO_MIGRATE_TO "sed -i 's|# mp8: /mnt/pve/cephfs--hdd--lowT/data/syncthing/Media,mp=/mnt/host/Media|mp8: /mnt/pve/cephfs--hdd--lowT/data/syncthing/Media,mp=/mnt/host/Media|' /etc/pve/lxc/$LXC_ID.conf"

echo "Migration script completed."
