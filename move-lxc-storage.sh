#!/usr/bin/env bash
set -euo pipefail

SOURCE="${SOURCE:-tank-containers}"
TARGET="${TARGET:-local-zfs}"
NODE="$(hostname -s)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_node() {
    [[ -n "$NODE" ]] || \
        die "Unable to determine the local hostname."

    [[ -d "/etc/pve/nodes/${NODE}" ]] || {
        echo "ERROR: Detected hostname '$NODE', but this does not appear"
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

list_node_cts() {
    check_node

    echo "Node: $NODE"
    echo
    echo "LXC containers currently assigned to this node:"
    echo

    local found=0
    local ctid
    local status

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        status="$(pct status "$ctid" 2>/dev/null | awk '{print $2}')"

        printf "CT %-8s %-10s\n" "$ctid" "${status:-unknown}"
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

    echo "Node:           $NODE"
    echo "Source storage: $SOURCE"
    echo "Target storage: $TARGET"
    echo
    echo "Containers and volumes that would be migrated:"
    echo

    local found=0
    local ctid
    local status
    local config

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        verify_ct_ownership "$ctid"

        config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"
        status="$(pct status "$ctid" | awk '{print $2}')"

        echo "============================================================"
        echo "CT $ctid"
        echo "Status: $status"
        echo "Node:   $(get_ct_node "$ctid")"
        echo

        grep -E \
            "^(rootfs|mp[0-9]+|unused[0-9]+): ${SOURCE}:" \
            "$config" |
            sed 's/^/  /'

        echo
        found=1
    done < <(get_candidate_cts)

    if [[ "$found" -eq 0 ]]; then
        echo "No containers on '$NODE' have volumes on '$SOURCE'."
        return 0
    fi

    echo "============================================================"
    echo "Preview complete. No changes were made."
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
    local -a volumes

    mapfile -t volumes < <(get_source_volumes "$ctid")

    if (( ${#volumes[@]} == 0 )); then
        echo "CT $ctid has no volumes on '$SOURCE'. Skipping."
        return 0
    fi

    echo "============================================================"
    echo "CT $ctid"
    echo "Node: $NODE"
    echo "============================================================"

    status="$(pct status "$ctid" | awk '{print $2}')"

    if [[ "$status" == "running" ]]; then
        was_running=1

        echo "CT $ctid is running."
        echo "Requesting graceful shutdown..."

        if ! pct shutdown "$ctid" --timeout 120; then
            echo "Graceful shutdown timed out."
            echo "Stopping CT $ctid..."
            pct stop "$ctid"
        fi

        status="$(pct status "$ctid" | awk '{print $2}')"

        [[ "$status" == "stopped" ]] || \
            die "CT $ctid did not stop."

        echo "CT $ctid is stopped."
    else
        echo "CT $ctid is already stopped."
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

        echo "Moving CT $ctid volume $vol:"
        grep -E "^${vol}: " "$config" | sed 's/^/  /'
        echo
        echo "Destination storage:"
        echo "  $TARGET"
        echo

        pct move-volume "$ctid" "$vol" "$TARGET" --delete 1

        echo
        echo "Completed CT $ctid $vol."
        echo
    done

    echo "Current CT storage configuration:"
    grep -E \
        '^(rootfs|mp[0-9]+|unused[0-9]+):' \
        "$config" || true

    if [[ "$was_running" -eq 1 ]]; then
        echo
        echo "CT $ctid was running before migration."
        echo "Starting CT $ctid..."

        pct start "$ctid"

        sleep 2

        status="$(pct status "$ctid" | awk '{print $2}')"

        if [[ "$status" == "running" ]]; then
            echo "CT $ctid is running."
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
        echo "No containers on '$NODE' have volumes on '$SOURCE'."
        exit 0
    fi

    echo "Node:           $NODE"
    echo "Source storage: $SOURCE"
    echo "Target storage: $TARGET"
    echo
    echo "Migration candidates:"
    printf '  CT %s\n' "${candidates[@]}"
    echo

    for ctid in "${candidates[@]}"; do
        migrate_ct "$ctid"
    done

    echo "============================================================"
    echo "Migration pass complete."
    echo "============================================================"
}

verify() {
    check_node

    echo "Node:           $NODE"
    echo "Source storage: $SOURCE"
    echo
    echo "Checking for remaining source-storage CT volumes..."
    echo

    local found=0
    local ctid
    local config
    local matches

    while read -r ctid; do
        [[ -n "$ctid" ]] || continue

        verify_ct_ownership "$ctid"

        config="/etc/pve/nodes/${NODE}/lxc/${ctid}.conf"

        matches="$(
            grep -E \
                "^(rootfs|mp[0-9]+|unused[0-9]+): ${SOURCE}:" \
                "$config" || true
        )"

        if [[ -n "$matches" ]]; then
            echo "CT $ctid still has volumes on '$SOURCE':"
            echo "$matches" | sed 's/^/  /'
            echo
            found=1
        fi
    done < <(get_node_cts)

    if [[ "$found" -eq 0 ]]; then
        echo "SUCCESS: No CT volumes belonging to $NODE remain on '$SOURCE'."
    else
        echo "WARNING: Some CT volumes on $NODE still remain on '$SOURCE'."
        return 2
    fi
}

show_config() {
    check_node

    echo "Detected configuration:"
    echo
    echo "  Node:   $NODE"
    echo "  Source: $SOURCE"
    echo "  Target: $TARGET"
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