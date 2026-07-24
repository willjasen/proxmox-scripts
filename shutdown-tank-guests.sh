#!/usr/bin/env bash

# Gracefully shut down running Proxmox VMs and containers with attached
# volumes on the tank-vms or tank-containers storage.

set -u

readonly STORAGE_PATTERN='(tank-vms|tank-containers)'
readonly VM_VOLUME_PATTERN="^((ide|sata|scsi|virtio)[0-9]+|efidisk0|tpmstate0): ${STORAGE_PATTERN}:"
readonly CT_VOLUME_PATTERN="^(rootfs|mp[0-9]+): ${STORAGE_PATTERN}:"
readonly SHUTDOWN_TIMEOUT=180

declare -a VM_IDS=()
declare -a CT_IDS=()
declare -a SHUTDOWN_PIDS=()

for command in qm pct awk grep; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command '$command' was not found." >&2
        exit 1
    fi
done

if command -v ha-manager >/dev/null 2>&1; then
    if ha-manager status 2>/dev/null | grep -qE 'service (vm|ct):[0-9]+'; then
        echo "Warning: HA-managed guests may restart if their requested state is 'started'."
        echo "Review 'ha-manager status' before continuing."
        echo
    fi
fi

while read -r vmid; do
    if qm config "$vmid" | grep -qE "$VM_VOLUME_PATTERN"; then
        VM_IDS+=("$vmid")
    fi
done < <(qm list | awk 'NR > 1 && $3 == "running" {print $1}')

while read -r ctid; do
    if pct config "$ctid" | grep -qE "$CT_VOLUME_PATTERN"; then
        CT_IDS+=("$ctid")
    fi
done < <(pct list | awk 'NR > 1 && $2 == "running" {print $1}')

if (( ${#VM_IDS[@]} == 0 && ${#CT_IDS[@]} == 0 )); then
    echo "No running guests have attached volumes on tank-vms or tank-containers."
    exit 0
fi

echo "Running guests selected for shutdown:"

for vmid in "${VM_IDS[@]}"; do
    vm_name=$(qm config "$vmid" | awk -F': ' '$1 == "name" {print $2; exit}')
    printf '  VM %s%s\n' "$vmid" "${vm_name:+ ($vm_name)}"
done

for ctid in "${CT_IDS[@]}"; do
    ct_name=$(pct config "$ctid" | awk -F': ' '$1 == "hostname" {print $2; exit}')
    printf '  CT %s%s\n' "$ctid" "${ct_name:+ ($ct_name)}"
done

echo
read -r -p "Type YES to gracefully shut down all guests listed above: " confirmation

if [[ "$confirmation" != "YES" ]]; then
    echo "Cancelled."
    exit 1
fi

for vmid in "${VM_IDS[@]}"; do
    echo "Shutting down VM $vmid..."
    qm shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" &
    SHUTDOWN_PIDS+=("$!")
done

for ctid in "${CT_IDS[@]}"; do
    echo "Shutting down CT $ctid..."
    pct shutdown "$ctid" --timeout "$SHUTDOWN_TIMEOUT" &
    SHUTDOWN_PIDS+=("$!")
done

shutdown_failed=0
for pid in "${SHUTDOWN_PIDS[@]}"; do
    if ! wait "$pid"; then
        shutdown_failed=1
    fi
done

declare -a STILL_RUNNING=()

for vmid in "${VM_IDS[@]}"; do
    if qm status "$vmid" | grep -q 'status: running'; then
        STILL_RUNNING+=("VM $vmid")
    fi
done

for ctid in "${CT_IDS[@]}"; do
    if pct status "$ctid" | grep -q 'status: running'; then
        STILL_RUNNING+=("CT $ctid")
    fi
done

if (( ${#STILL_RUNNING[@]} > 0 )); then
    echo
    echo "The following guests are still running:"
    printf '  %s\n' "${STILL_RUNNING[@]}"
    echo "Review them before using a force-stop command."
    exit 1
fi

if (( shutdown_failed != 0 )); then
    echo "All selected guests are stopped, but one or more shutdown commands reported an error."
    exit 1
fi

echo "All selected guests shut down successfully."
