#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# -------------------------------
# Configuration Variables
# -------------------------------

# Log File
LOG_FILE="/var/log/proxmox_replication.log"   # Ensure this file is writable

# -------------------------------
# Logging Function
# -------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# -------------------------------
# Script Execution Starts Here
# -------------------------------

log "Starting replication trigger script on the current node."

# Determine the current node's name using hostname
current_node=$(hostname)
log "Current node identified as: $current_node"

# Fetch all replication tasks for the current node in JSON format
replications=$(pvesh get /nodes/$current_node/replication --output-format json 2>/dev/null) || {
    log "Failed to retrieve replication tasks. Please verify the API endpoint and node name."
    exit 1
}

log "Replication tasks retrieved: $replications"

# Check if there are any replication tasks
if [ -z "$replications" ] || [ "$replications" == "[]" ]; then
    log "No replication tasks found on node $current_node."
    exit 0
fi

# Extract replication IDs using jq
replication_ids=$(echo "$replications" | jq -r '.[].id')

if [ -z "$replication_ids" ]; then
    log "No replication IDs found in the replication tasks."
    exit 0
fi

log "Found replication task IDs: $replication_ids"

# Iterate over each replication task and trigger it
for repl_id in $replication_ids; do
    log "Starting replication task ID: $repl_id on node: $current_node"

    # Construct the API endpoint for schedule_now
    api_endpoint="/nodes/$current_node/replication/$repl_id/schedule_now"

    # Trigger the replication task using 'create' with the 'schedule_now' endpoint
    response=$(pvesh create "$api_endpoint" 2>&1) || {
        log "Failed to start replication task ID: $repl_id on node: $current_node. Error: $response"
        continue
    }

    log "Successfully started replication task ID: $repl_id on node: $current_node."
done

log "Replication trigger script completed on node $current_node."
