#!/usr/bin/env bash
set -euo pipefail

SOURCE="${SOURCE:-tank}"
TARGET="${TARGET:-local-zfs}"
NODE="$(hostname -s)"

# ANSI colors
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"

#
# Tracks a VM that was running before we stopped it.
# If the script exits unexpectedly, the EXIT trap attempts to restart it.
#
RESTART_VM=""
RESTART_VM_NAME=""

die() {
    echo -e "${RED}${BOLD}ERROR:${RESET} $*" >&2
    exit 1
}

restart_pending_vm() {
    if [[ -z "${RESTART_VM:-}" ]]; then
        return 0
    fi

    local status="unknown"

    status="$(qm status "$RESTART_VM" 2>/dev/null | awk '{print $2}' || true)"

    if [[ "$status" == "running" ]]; then
        RESTART_VM=""
        RESTART_VM_NAME=""
        return 0
    fi

    echo
    echo -e "${YELLOW}${BOLD}Recovery:${RESET} VM $RESTART_VM (${RESTART_VM_NAME:-unknown}) was running before migration."
    echo -e "${YELLOW}Attempting to start it before exiting...${RESET}"

    if qm start "$RESTART_VM"; then
        sleep 3

        status="$(qm status "$RESTART_VM" 2>/dev/null | awk '{print $2}' || true)"

        if [[ "$status" == "running" ]]; then
            echo -e "${GREEN}${BOLD}VM $RESTART_VM (${RESTART_VM_NAME:-unknown}) is running again.${RESET}"
            RESTART_VM=""
            RESTART_VM_NAME=""
        else
            echo -e "${RED}${BOLD}WARNING:${RESET} VM $RESTART_VM did not report running after start."
        fi
    else
        echo -e "${RED}${BOLD}WARNING:${RESET} Failed to restart VM $RESTART_VM."
    fi
}

cleanup() {
    local rc=$?

    restart_pending_vm || true

    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_node() {
    [[ -n "$NODE" ]] || \
        die "Unable to determine the local hostname."

    [[ -d "/etc/pve/nodes/${NODE}" ]] || {
        echo -e "${RED}${BOLD}ERROR:${RESET} Detected hostname '$NODE', but it does not appear"
        echo "       to match a Proxmox cluster node."
        echo
        echo "Expected path:"
        echo "  /etc/pve/nodes/${NODE}"
        echo
        echo "Known Proxmox nodes:"
        ls -1 /etc/pve/nodes 2>/dev/null | sed 's/^/  /' || true
        exit 1
    }
}

check_storage() {
    local storage="$1"

    if ! pvesm status --storage "$storage" 2>/dev/null |
        awk -v storage="$storage" '
            NR > 1 && $1 == storage && $3 == "active" {
                found=1
            }
            END {
                exit !found
            }
        '
    then
        die "Storage '$storage' is not active on node '$NODE'."
    fi
}

get_vm_node() {
    local vmid="$1"

    pvesh get /cluster/resources --type vm --output-format json |
        python3 -c "
import json, sys

vmid = int('$vmid')

for r in json.load(sys.stdin):
    if r.get('type') == 'qemu' and r.get('vmid') == vmid:
        print(r.get('node', ''))
        break
"
}

get_vm_name() {
    local vmid="$1"
    local config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"
    local name=""

    if [[ -f "$config" ]]; then
        name="$(
            awk -F': ' '
                $1 == "name" {
                    print $2
                    exit
                }
            ' "$config"
        )"
    fi

    if [[ -z "$name" ]]; then
        name="$(
            pvesh get /cluster/resources --type vm --output-format json |
                python3 -c "
import json, sys

vmid = int('$vmid')

for r in json.load(sys.stdin):
    if r.get('type') == 'qemu' and r.get('vmid') == vmid:
        print(r.get('name', '') or '')
        break
"
        )"
    fi

    [[ -n "$name" ]] || name="unknown"

    echo "$name"
}

get_node_vms() {
    pvesh get /cluster/resources --type vm --output-format json |
        python3 -c "
import json, sys

for r in json.load(sys.stdin):
    if r.get('type') == 'qemu' and r.get('node') == '$NODE':
        print(r['vmid'])
"
}

#
# Return movable disk keys on SOURCE.
#
# Includes:
#   scsiN
#   sataN
#   ideN
#   virtioN
#   efidiskN
#   tpmstateN
#   unusedN
#
# Excludes entries such as:
#   cdrom media
#   cloud-init disks
#   host devices
#   passthrough devices
#
get_source_disks() {
    local vmid="$1"
    local config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"

    [[ -f "$config" ]] || return 0

    awk -F': ' -v src="$SOURCE:" '
        $1 ~ /^(scsi[0-9]+|sata[0-9]+|ide[0-9]+|virtio[0-9]+|efidisk[0-9]+|tpmstate[0-9]+|unused[0-9]+)$/ &&
        index($2, src) == 1 &&
        $2 !~ /media=cdrom/ &&
        $2 !~ /cloudinit/ {
            print $1
        }
    ' "$config"
}

get_candidate_vms() {
    local vmid
    local config

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue

        config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"

        [[ -f "$config" ]] || continue

        if awk -F': ' -v src="$SOURCE:" '
            $1 ~ /^(scsi[0-9]+|sata[0-9]+|ide[0-9]+|virtio[0-9]+|efidisk[0-9]+|tpmstate[0-9]+|unused[0-9]+)$/ &&
            index($2, src) == 1 &&
            $2 !~ /media=cdrom/ &&
            $2 !~ /cloudinit/ {
                found=1
            }
            END {
                exit !found
            }
        ' "$config"
        then
            echo "$vmid"
        fi
    done < <(get_node_vms)
}

verify_vm_ownership() {
    local vmid="$1"
    local reported_node
    local config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"

    reported_node="$(get_vm_node "$vmid")"

    [[ "$reported_node" == "$NODE" ]] || \
        die "VM $vmid belongs to '${reported_node:-UNKNOWN}', not '$NODE'."

    [[ -f "$config" ]] || \
        die "VM $vmid config does not exist at $config."
}

human_sum_sizes() {
    python3 -c '
import sys
import re

total = 0

units = {
    "B": 1,
    "K": 1024,
    "M": 1024**2,
    "G": 1024**3,
    "T": 1024**4,
    "P": 1024**5,
}

for line in sys.stdin:
    line = line.strip()

    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([BKMGTPE]?)", line, re.I)
    if not m:
        continue

    value = float(m.group(1))
    unit = m.group(2).upper() or "B"

    if unit in units:
        total += int(value * units[unit])

def human(n):
    for unit in ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]:
        if n < 1024 or unit == "PiB":
            if unit == "B":
                return f"{n:.0f} {unit}"
            return f"{n:.2f} {unit}"
        n /= 1024

print(human(total))
'
}

print_separator() {
    echo -e "${BLUE}============================================================${RESET}"
}

print_vm_header() {
    local vmid="$1"
    local status="$2"
    local name
    local node

    name="$(get_vm_name "$vmid")"
    node="$(get_vm_node "$vmid")"

    print_separator
    echo -e "${BOLD}${CYAN}VM $vmid${RESET} ${DIM}(${name})${RESET}"

    if [[ "$status" == "running" ]]; then
        echo -e "Status: ${GREEN}${BOLD}${status}${RESET}"
    elif [[ "$status" == "stopped" ]]; then
        echo -e "Status: ${YELLOW}${BOLD}${status}${RESET}"
    else
        echo -e "Status: ${MAGENTA}${BOLD}${status}${RESET}"
    fi

    echo -e "Node:   ${CYAN}${node}${RESET}"
    echo
}

list_node_vms() {
    check_node

    echo -e "${BOLD}Node:${RESET} ${CYAN}$NODE${RESET}"
    echo
    echo -e "${BOLD}QEMU VMs currently assigned to this node:${RESET}"
    echo

    local found=0
    local vmid
    local status
    local name

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue

        status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}')"
        name="$(get_vm_name "$vmid")"

        if [[ "$status" == "running" ]]; then
            printf "VM %-8s %-25s ${GREEN}%-10s${RESET}\n" \
                "$vmid" "$name" "${status:-unknown}"
        elif [[ "$status" == "stopped" ]]; then
            printf "VM %-8s %-25s ${YELLOW}%-10s${RESET}\n" \
                "$vmid" "$name" "${status:-unknown}"
        else
            printf "VM %-8s %-25s ${MAGENTA}%-10s${RESET}\n" \
                "$vmid" "$name" "${status:-unknown}"
        fi

        found=1
    done < <(get_node_vms)

    if [[ "$found" -eq 0 ]]; then
        echo "No QEMU VMs assigned to $NODE."
    fi
}

preview() {
    check_node
    check_storage "$SOURCE"
    check_storage "$TARGET"

    echo -e "${BOLD}Node:${RESET}           ${CYAN}$NODE${RESET}"
    echo -e "${BOLD}Source storage:${RESET} ${YELLOW}$SOURCE${RESET}"
    echo -e "${BOLD}Target storage:${RESET} ${GREEN}$TARGET${RESET}"
    echo
    echo -e "${BOLD}VMs and disks that would be migrated:${RESET}"
    echo

    local found=0
    local vmid
    local status
    local config
    local line
    local size
    local -a all_sizes=()
    local disk_count=0
    local vm_count=0

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue

        verify_vm_ownership "$vmid"

        config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"
        status="$(qm status "$vmid" | awk '{print $2}')"

        print_vm_header "$vmid" "$status"

        while IFS= read -r disk; do
            [[ -n "$disk" ]] || continue

            line="$(grep -E "^${disk}: " "$config" || true)"
            [[ -n "$line" ]] || continue

            echo -e "${YELLOW}  ${line}${RESET}"

            ((disk_count += 1))

            size="$(
                sed -nE 's/.*(^|,)size=([^,]+).*/\2/p' <<< "$line"
            )"

            if [[ -n "$size" ]]; then
                all_sizes+=("$size")
            fi
        done < <(get_source_disks "$vmid")

        echo
        ((vm_count += 1))
        found=1
    done < <(get_candidate_vms)

    if [[ "$found" -eq 0 ]]; then
        echo -e "${GREEN}No VMs on '$NODE' have disks on '$SOURCE'.${RESET}"
        return 0
    fi

    local total_size
    total_size="$(
        printf '%s\n' "${all_sizes[@]}" | human_sum_sizes
    )"

    print_separator
    echo -e "${BOLD}Preview summary:${RESET}"
    echo -e "  VMs:                  ${CYAN}${vm_count}${RESET}"
    echo -e "  Disks:                ${CYAN}${disk_count}${RESET}"
    echo -e "  Estimated total size: ${MAGENTA}${BOLD}${total_size}${RESET}"
    echo
    echo -e "${GREEN}${BOLD}Preview complete.${RESET} No changes were made."
}

migrate_vm() {
    local vmid="$1"

    check_node
    check_storage "$SOURCE"
    check_storage "$TARGET"

    verify_vm_ownership "$vmid"

    local config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"
    local status
    local was_running=0
    local reported_node
    local name
    local line
    local -a disks

    name="$(get_vm_name "$vmid")"

    mapfile -t disks < <(get_source_disks "$vmid")

    if (( ${#disks[@]} == 0 )); then
        echo -e "${YELLOW}VM $vmid ($name) has no disks on '$SOURCE'. Skipping.${RESET}"
        return 0
    fi

    status="$(qm status "$vmid" | awk '{print $2}')"
    print_vm_header "$vmid" "$status"

    if [[ "$status" == "running" ]]; then
        was_running=1

        RESTART_VM="$vmid"
        RESTART_VM_NAME="$name"

        echo -e "${YELLOW}VM $vmid ($name) is running.${RESET}"
        echo "Requesting graceful shutdown..."

        if ! qm shutdown "$vmid" --timeout 120; then
            echo -e "${YELLOW}Graceful shutdown timed out.${RESET}"
            echo "Stopping VM $vmid..."
            qm stop "$vmid"
        fi

        status="$(qm status "$vmid" | awk '{print $2}')"

        [[ "$status" == "stopped" ]] || \
            die "VM $vmid did not stop."

        echo -e "${GREEN}VM $vmid is stopped.${RESET}"
    else
        echo -e "${DIM}VM $vmid is already stopped.${RESET}"
    fi

    echo

    #
    # Re-read disk list after shutdown.
    #
    mapfile -t disks < <(get_source_disks "$vmid")

    #
    # IMPORTANT:
    # Disks are intentionally moved strictly one at a time.
    #
    # There are no background jobs or parallel operations here.
    # qm move-disk must finish completely before the next disk starts.
    #
    for disk in "${disks[@]}"; do
        verify_vm_ownership "$vmid"

        reported_node="$(get_vm_node "$vmid")"

        [[ "$reported_node" == "$NODE" ]] || \
            die "VM $vmid moved to '$reported_node' before moving $disk."

        line="$(grep -E "^${disk}: " "$config" || true)"

        [[ -n "$line" ]] || \
            die "VM $vmid disk $disk no longer exists in its configuration."

        if [[ "$line" != *"${SOURCE}:"* ]]; then
            die "VM $vmid $disk no longer references '$SOURCE'."
        fi

        echo -e "${BOLD}Moving VM $vmid ($name) disk $disk:${RESET}"
        echo -e "  ${YELLOW}${line}${RESET}"
        echo
        echo -e "Destination storage: ${GREEN}${TARGET}${RESET}"
        echo

        qm move-disk "$vmid" "$disk" "$TARGET" --delete 1

        echo
        echo -e "${GREEN}${BOLD}Completed:${RESET} VM $vmid ($name) $disk"
        echo
    done

    echo -e "${BOLD}Current VM disk configuration:${RESET}"

    grep -E \
        '^(scsi[0-9]+|sata[0-9]+|ide[0-9]+|virtio[0-9]+|efidisk[0-9]+|tpmstate[0-9]+|unused[0-9]+):' \
        "$config" |
        sed 's/^/  /' || true

    if [[ "$was_running" -eq 1 ]]; then
        echo
        echo -e "${YELLOW}VM $vmid ($name) was running before migration.${RESET}"
        echo "Starting VM $vmid..."

        qm start "$vmid"

        sleep 3

        status="$(qm status "$vmid" | awk '{print $2}')"

        if [[ "$status" == "running" ]]; then
            echo -e "${GREEN}${BOLD}VM $vmid ($name) is running.${RESET}"

            RESTART_VM=""
            RESTART_VM_NAME=""
        else
            die "VM $vmid failed to return to running state."
        fi
    fi

    echo
}

migrate() {
    check_node
    check_storage "$SOURCE"
    check_storage "$TARGET"

    local -a candidates
    local vmid

    mapfile -t candidates < <(get_candidate_vms)

    if (( ${#candidates[@]} == 0 )); then
        echo -e "${GREEN}No VMs on '$NODE' have disks on '$SOURCE'.${RESET}"
        exit 0
    fi

    echo -e "${BOLD}Node:${RESET}           ${CYAN}$NODE${RESET}"
    echo -e "${BOLD}Source storage:${RESET} ${YELLOW}$SOURCE${RESET}"
    echo -e "${BOLD}Target storage:${RESET} ${GREEN}$TARGET${RESET}"
    echo
    echo -e "${BOLD}Migration candidates:${RESET}"

    for vmid in "${candidates[@]}"; do
        echo -e "  VM ${CYAN}${vmid}${RESET} ($(get_vm_name "$vmid"))"
    done

    echo

    #
    # VMs are also processed strictly one at a time.
    #
    for vmid in "${candidates[@]}"; do
        migrate_vm "$vmid"
    done

    print_separator
    echo -e "${GREEN}${BOLD}Migration pass complete.${RESET}"
    print_separator
}

verify() {
    check_node

    echo -e "${BOLD}Node:${RESET}           ${CYAN}$NODE${RESET}"
    echo -e "${BOLD}Source storage:${RESET} ${YELLOW}$SOURCE${RESET}"
    echo
    echo -e "${BOLD}Checking for remaining source-storage VM disks...${RESET}"
    echo

    local found=0
    local vmid
    local config
    local disk
    local line
    local name

    while read -r vmid; do
        [[ -n "$vmid" ]] || continue

        verify_vm_ownership "$vmid"

        config="/etc/pve/nodes/${NODE}/qemu-server/${vmid}.conf"
        name="$(get_vm_name "$vmid")"

        while read -r disk; do
            [[ -n "$disk" ]] || continue

            line="$(grep -E "^${disk}: " "$config" || true)"

            if [[ -n "$line" ]]; then
                if [[ "$found" -eq 0 ]]; then
                    found=1
                fi

                echo -e "${YELLOW}${BOLD}VM $vmid ($name) still has a disk on '$SOURCE':${RESET}"
                echo "  $line"
                echo
            fi
        done < <(get_source_disks "$vmid")

    done < <(get_node_vms)

    if [[ "$found" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}SUCCESS:${RESET} No VM disks belonging to $NODE remain on '$SOURCE'."
    else
        echo -e "${YELLOW}${BOLD}WARNING:${RESET} Some VM disks on $NODE still remain on '$SOURCE'."
        return 2
    fi
}

show_config() {
    check_node

    echo -e "${BOLD}Detected configuration:${RESET}"
    echo
    echo -e "  Node:   ${CYAN}$NODE${RESET}"
    echo -e "  Source: ${YELLOW}$SOURCE${RESET}"
    echo -e "  Target: ${GREEN}$TARGET${RESET}"
}

usage() {
    cat <<USAGE
Usage:

  $0 config
      Show detected node and storage configuration.

  $0 list
      List all QEMU VMs currently assigned to this node.

  $0 preview
      Show every VM and disk that would be moved.
      Includes estimated total provisioned disk size.
      Makes no changes.

  $0 migrate-vm <VMID>
      Migrate only one VM.

  $0 migrate
      Stop running candidate VMs, move all matching disks,
      and restart only VMs that were running beforehand.

  $0 verify
      Check this node for remaining VM disks on the source storage.

  $0 help
      Show this help.

Defaults:

  SOURCE=$SOURCE
  TARGET=$TARGET
  NODE=$NODE

Override storage names:

  SOURCE=old-zfs TARGET=new-zfs $0 preview

  SOURCE=old-zfs TARGET=new-zfs $0 migrate

The node is automatically detected from the host on which the
script is executed.

VMs and disks are migrated strictly sequentially:
one VM at a time and one disk at a time.

Running VMs are tracked before shutdown and restarted after
migration. If migration fails or the script is interrupted after
stopping a previously running VM, the cleanup handler attempts
to start that VM again.
USAGE
}

case "${1:-help}" in
    config)
        show_config
        ;;

    list)
        list_node_vms
        ;;

    preview)
        preview
        ;;

    migrate)
        migrate
        ;;

    migrate-vm)
        [[ -n "${2:-}" ]] || die "Usage: $0 migrate-vm <VMID>"
        migrate_vm "$2"
        ;;

    verify)
        verify
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        echo "Unknown command: ${1:-}"
        echo
        usage
        exit 1
        ;;
esac