#!/bin/bash
# shutdown-when-no-replication.sh
# Checks every minute for active replications and shuts down Proxmox when none are active.

while true; do
    running_count=$(pvesh get /nodes/$(hostname)/replication --output-format json 2>/dev/null | jq 'map(select(.pid != null)) | length')
    if [ "$running_count" -eq 0 ]; then
        echo "No active replications found. Shutting down Proxmox in 10 seconds."
        sleep 10
        shutdown -h now
        exit 0
    else
        echo "Active replications detected. Checking again in 60 seconds..."
        sleep 60
    fi
done
