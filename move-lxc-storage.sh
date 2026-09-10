#!/usr/bin/env bash
set -euo pipefail

SOURCE="${SOURCE:-tank-containers}"
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

die() {
    echo -e "${RED}${BOLD}ERROR:${RESET} $*" >&2
    exit 1
}

check_node() {
    [[ -n "$NODE" ]] || \
        die "Unable to determine the local hostname."

    [[ -d "/etc/pve/nodes/${NODE}" ]] || {
        echo -e "${RED}${BOLD}ERROR:${RESET} Detected hostname '$NODE', but this does not appear"
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

get_ct_node() {
    local ctid="$1"

    pvesh get /cluster/resources --type vm --output-format json |
        python3 -c "
import json, sys

vmid = int('$ctid')

for r in json.load(sys.stdin):
    if r.get('type') == 'lxc' and r.get('vmid') == vmid:
        print(r.get('node', ''))
        break
"
}

get_ct_name() {
    local ctid="$1"
    local config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"
    local name=""

    if [[ -f "$config" ]]; then
        name="$(
            awk -F': ' '
                $1 == "hostname" {
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

vmid = int('$ctid')

for r in json.load(sys.stdin):
    if r.get('type') == 'lxc' and r.get('vmid') == vmid:
        print(r.get('name', '') or '')
        break
"
        )"
    fi

    [[ -n "$name" ]] || name="unknown"

    echo "$name"
}

get_node_cts() {
    pvesh get /cluster/resources --type vm --output-format json |
        python3 -c "
import json, sys

for r in json.load(sys.stdin):
    if r.get('type') == 'lxc' and r.get('node') == '$NODE':
        print(r['vmid'])
"
}

get_source_volumes() {
    local ctid="$1"
    local config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"

    [[ -f "$config" ]] || return 0

    awk -F': ' -v src="$SOURCE:" '
        $1 ~ /^(rootfs|mp[0-9]+|unused[0-9]+)$/ &&
        index($2, src) == 1 {
            print $1
        }
    ' "$config"
}

get_candidate_cts() {
    local ctid
    local config

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"

        [[ -f "$config" ]] || continue

        if grep -Eq \
            "^(rootfs|mp[0-9]+|unused[0-9]+): ${SOURCE}:" \
            "$config"
        then
            echo "$ctid"
        fi
    done < <(get_node_cts)
}

verify_ct_ownership() {
    local ctid="$1"
    local reported_node
    local config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"

    reported_node="$(get_ct_node "$ctid")"

    [[ "$reported_node" == "$NODE" ]] || \
        die "CT $ctid belongs to '${reported_node:-UNKNOWN}', not '$NODE'."

    [[ -f "$config" ]] || \
        die "CT $ctid config does not exist at $config."
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

print_ct_header() {
    local ctid="$1"
    local status="$2"
    local name
    local node

    name="$(get_ct_name "$ctid")"
    node="$(get_ct_node "$ctid")"

    print_separator
    echo -e "${BOLD}${CYAN}CT $ctid${RESET} ${DIM}(${name})${RESET}"

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

list_node_cts() {
    check_node

    echo -e "${BOLD}Node:${RESET} ${CYAN}$NODE${RESET}"
    echo
    echo -e "${BOLD}LXC containers currently assigned to this node:${RESET}"
    echo

    local found=0
    local ctid
    local status
    local name

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        status="$(pct status "$ctid" 2>/dev/null | awk '{print $2}')"
        name="$(get_ct_name "$ctid")"

        if [[ "$status" == "running" ]]; then
            printf "CT %-8s %-25s ${GREEN}%-10s${RESET}\n" \
                "$ctid" "$name" "${status:-unknown}"
        elif [[ "$status" == "stopped" ]]; then
            printf "CT %-8s %-25s ${YELLOW}%-10s${RESET}\n" \
                "$ctid" "$name" "${status:-unknown}"
        else
            printf "CT %-8s %-25s ${MAGENTA}%-10s${RESET}\n" \
                "$ctid" "$name" "${status:-unknown}"
        fi

        found=1
    done < <(get_node_cts)

    if [[ "$found" -eq 0 ]]; then
        echo "No LXC containers assigned to $NODE."
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
    echo -e "${BOLD}Containers and volumes that would be migrated:${RESET}"
    echo

    local found=0
    local ctid
    local status
    local config
    local line
    local size
    local -a all_sizes=()
    local volume_count=0
    local container_count=0

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        verify_ct_ownership "$ctid"

        config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"
        status="$(pct status "$ctid" | awk '{print $2}')"

        print_ct_header "$ctid" "$status"

        while IFS= read -r line; do
            [[ -n "$line" ]] || continue

            echo -e "${YELLOW}  ${line}${RESET}"

            ((volume_count += 1))

            size="$(
                sed -nE 's/.*(^|,)size=([^,]+).*/\2/p' <<< "$line"
            )"

            if [[ -n "$size" ]]; then
                all_sizes+=("$size")
            fi
        done < <(
            grep -E \
                "^(rootfs|mp[0-9]+|unused[0-9]+): ${SOURCE}:" \
                "$config"
        )

        echo
        ((container_count += 1))
        found=1
    done < <(get_candidate_cts)

    if [[ "$found" -eq 0 ]]; then
        echo -e "${GREEN}No containers on '$NODE' have volumes on '$SOURCE'.${RESET}"
        return 0
    fi

    local total_size
    total_size="$(
        printf '%s\n' "${all_sizes[@]}" | human_sum_sizes
    )"

    print_separator
    echo -e "${BOLD}Preview summary:${RESET}"
    echo -e "  Containers:           ${CYAN}${container_count}${RESET}"
    echo -e "  Volumes:              ${CYAN}${volume_count}${RESET}"
    echo -e "  Estimated total size: ${MAGENTA}${BOLD}${total_size}${RESET}"
    echo
    echo -e "${GREEN}${BOLD}Preview complete.${RESET} No changes were made."
}

migrate_ct() {
    local ctid="$1"

    check_node
    check_storage "$SOURCE"
    check_storage "$TARGET"

    verify_ct_ownership "$ctid"

    local config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"
    local status
    local was_running=0
    local reported_node
    local name
    local -a volumes

    name="$(get_ct_name "$ctid")"

    mapfile -t volumes < <(get_source_volumes "$ctid")

    if (( ${#volumes[@]} == 0 )); then
        echo -e "${YELLOW}CT $ctid ($name) has no volumes on '$SOURCE'. Skipping.${RESET}"
        return 0
    fi

    status="$(pct status "$ctid" | awk '{print $2}')"
    print_ct_header "$ctid" "$status"

    if [[ "$status" == "running" ]]; then
        was_running=1

        echo -e "${YELLOW}CT $ctid ($name) is running.${RESET}"
        echo "Requesting graceful shutdown..."

        if ! pct shutdown "$ctid" --timeout 120; then
            echo -e "${YELLOW}Graceful shutdown timed out.${RESET}"
            echo "Stopping CT $ctid..."
            pct stop "$ctid"
        fi

        status="$(pct status "$ctid" | awk '{print $2}')"

        [[ "$status" == "stopped" ]] || \
            die "CT $ctid did not stop."

        echo -e "${GREEN}CT $ctid is stopped.${RESET}"
    else
        echo -e "${DIM}CT $ctid is already stopped.${RESET}"
    fi

    echo

    mapfile -t volumes < <(get_source_volumes "$ctid")

    for vol in "${volumes[@]}"; do
        verify_ct_ownership "$ctid"

        reported_node="$(get_ct_node "$ctid")"

        [[ "$reported_node" == "$NODE" ]] || \
            die "CT $ctid moved to '$reported_node' before moving $vol."

        if ! grep -Eq "^${vol}: ${SOURCE}:" "$config"; then
            die "CT $ctid $vol no longer references '$SOURCE'."
        fi

        echo -e "${BOLD}Moving CT $ctid ($name) volume $vol:${RESET}"

        grep -E "^${vol}: " "$config" |
            while IFS= read -r line; do
                echo -e "  ${YELLOW}${line}${RESET}"
            done

        echo
        echo -e "Destination storage: ${GREEN}${TARGET}${RESET}"
        echo

        pct move-volume "$ctid" "$vol" "$TARGET" --delete 1

        echo
        echo -e "${GREEN}${BOLD}Completed:${RESET} CT $ctid ($name) $vol"
        echo
    done

    echo -e "${BOLD}Current CT storage configuration:${RESET}"

    grep -E \
        '^(rootfs|mp[0-9]+|unused[0-9]+):' \
        "$config" |
        sed 's/^/  /' || true

    if [[ "$was_running" -eq 1 ]]; then
        echo
        echo -e "${YELLOW}CT $ctid ($name) was running before migration.${RESET}"
        echo "Starting CT $ctid..."

        pct start "$ctid"

        sleep 2

        status="$(pct status "$ctid" | awk '{print $2}')"

        if [[ "$status" == "running" ]]; then
            echo -e "${GREEN}${BOLD}CT $ctid ($name) is running.${RESET}"
        else
            die "CT $ctid failed to return to running state."
        fi
    fi

    echo
}

migrate() {
    check_node
    check_storage "$SOURCE"
    check_storage "$TARGET"

    local -a candidates
    local ctid

    mapfile -t candidates < <(get_candidate_cts)

    if (( ${#candidates[@]} == 0 )); then
        echo -e "${GREEN}No containers on '$NODE' have volumes on '$SOURCE'.${RESET}"
        exit 0
    fi

    echo -e "${BOLD}Node:${RESET}           ${CYAN}$NODE${RESET}"
    echo -e "${BOLD}Source storage:${RESET} ${YELLOW}$SOURCE${RESET}"
    echo -e "${BOLD}Target storage:${RESET} ${GREEN}$TARGET${RESET}"
    echo
    echo -e "${BOLD}Migration candidates:${RESET}"

    for ctid in "${candidates[@]}"; do
        echo -e "  CT ${CYAN}${ctid}${RESET} ($(get_ct_name "$ctid"))"
    done

    echo

    for ctid in "${candidates[@]}"; do
        migrate_ct "$ctid"
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
    echo -e "${BOLD}Checking for remaining source-storage CT volumes...${RESET}"
    echo

    local found=0
    local ctid
    local config
    local matches
    local name

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        verify_ct_ownership "$ctid"

        config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"
        name="$(get_ct_name "$ctid")"

        matches="$(
            grep -E \
                "^(rootfs|mp[0-9]+|unused[0-9]+): ${SOURCE}:" \
                "$config" || true
        )"

        if [[ -n "$matches" ]]; then
            echo -e "${YELLOW}${BOLD}CT $ctid ($name) still has volumes on '$SOURCE':${RESET}"
            echo "$matches" | sed 's/^/  /'
            echo
            found=1
        fi
    done < <(get_node_cts)

    if [[ "$found" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}SUCCESS:${RESET} No CT volumes belonging to $NODE remain on '$SOURCE'."
    else
        echo -e "${YELLOW}${BOLD}WARNING:${RESET} Some CT volumes on $NODE still remain on '$SOURCE'."
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
      List all LXC containers currently assigned to this node.

  $0 preview
      Show every CT and volume that would be moved.
      Includes estimated total provisioned volume size.
      Makes no changes.

  $0 migrate-ct <CTID>
      Migrate only one CT.

  $0 migrate
      Stop running candidate CTs, move all matching volumes,
      and restart only CTs that were running beforehand.

  $0 verify
      Check this node for remaining volumes on the source storage.

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
USAGE
}

case "${1:-help}" in
    config)
        show_config
        ;;

    list)
        list_node_cts
        ;;

    preview)
        preview
        ;;

    migrate)
        migrate
        ;;

    migrate-ct)
        [[ -n "${2:-}" ]] || die "Usage: $0 migrate-ct <CTID>"
        migrate_ct "$2"
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