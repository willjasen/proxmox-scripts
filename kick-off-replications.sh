#!/bin/bash

set -e

# Configuration
LOG_FILE="/var/log/proxmox_replication.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting replication trigger script on the current node."

# Get current node name
current_node=$(hostname)
log "Current node identified as: $current_node"

# Fetch replication tasks
replications=$(pvesh get /nodes/$current_node/replication --output-format json 2>/dev/null) || {
    log "Failed to retrieve replication tasks. Please verify the API endpoint and node name."
    exit 1
}

log "Replication tasks retrieved: $replications"

# Check if replication tasks exist
if [ -z "$replications" ] || [ "$replications" == "[]" ]; then
    log "No replication tasks found on node $current_node."
    exit 0
fi

# Extract replication IDs
replication_ids=$(echo "$replications" | jq -r '.[].id')

if [ -z "$replication_ids" ]; then
    log "No replication IDs found in the replication tasks."
    exit 0
fi

log "Found replication task IDs: $replication_ids"

# Trigger each replication in the background
for repl_id in $replication_ids; do
    log "Starting replication task ID: $repl_id on node: $current_node"

    api_endpoint="/nodes/$current_node/replication/$repl_id/schedule_now"

    # Run pvesh create in the background
    pvesh create "$api_endpoint" >> "$LOG_FILE" 2>&1 &

    # Optionally, limit the number of concurrent jobs
    # Uncomment the following lines to limit to 5 concurrent jobs
    # while (( $(jobs -r | wc -l) >= 5 )); do
    #     wait -n
    # done
done

# Wait for all background jobs to finish
wait

log "Replication trigger script completed on node $current_node."
