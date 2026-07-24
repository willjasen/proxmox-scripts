#!/usr/bin/env bash

# Gracefully shut down running Proxmox guests with attached volumes on
# tank-vms or tank-containers. Run once from any healthy cluster node.

set -u

readonly SHUTDOWN_TIMEOUT=180
readonly POLL_INTERVAL=3
readonly POLL_TIMEOUT=$((SHUTDOWN_TIMEOUT + 30))
readonly BATCH_SIZE=2

declare -a GUESTS=()

for command in pvesh perl grep; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command '$command' was not found." >&2
        exit 1
    fi
done

config_has_target_volume() {
    local guest_type=$1
    local node=$2
    local vmid=$3
    local endpoint

    if [[ "$guest_type" == "qemu" ]]; then
        endpoint="/nodes/$node/qemu/$vmid/config"
    else
        endpoint="/nodes/$node/lxc/$vmid/config"
    fi

    pvesh get "$endpoint" --output-format json 2>/dev/null |
        perl -MJSON::PP -0777 -e '
            my $guest_type = shift;
            my $config = decode_json(<STDIN>);
            my $key_pattern = $guest_type eq "qemu"
                ? qr/^(?:(?:ide|sata|scsi|virtio)\d+|efidisk0|tpmstate0)$/
                : qr/^(?:rootfs|mp\d+)$/;

            for my $key (keys %{$config}) {
                next unless $key =~ $key_pattern;
                my $value = $config->{$key};
                if ($value =~ /^(?:tank-vms|tank-containers):/) {
                    exit 0;
                }
            }
            exit 1;
        ' "$guest_type"
}

guest_is_running() {
    local guest_type=$1
    local node=$2
    local vmid=$3
    local endpoint="/nodes/$node/$guest_type/$vmid/status/current"

    pvesh get "$endpoint" --output-format json 2>/dev/null |
        perl -MJSON::PP -0777 -e '
            my $status = decode_json(<STDIN>);
            exit(($status->{status} // "") eq "running" ? 0 : 1);
        '
}

echo "Scanning running guests across the Proxmox cluster..."

if ! cluster_resources=$(
    pvesh get /cluster/resources --type vm --output-format json
); then
    echo "Error: unable to read cluster guest resources." >&2
    exit 1
fi

while IFS=$'\t' read -r guest_type vmid node name; do
    [[ -n "$guest_type" && -n "$vmid" && -n "$node" ]] || continue

    if config_has_target_volume "$guest_type" "$node" "$vmid"; then
        GUESTS+=("$guest_type|$vmid|$node|$name")
    fi
done < <(
    printf '%s' "$cluster_resources" |
        perl -MJSON::PP -0777 -e '
            my $resources = decode_json(<STDIN>);
            for my $guest (@{$resources}) {
                next unless ($guest->{status} // "") eq "running";
                next unless ($guest->{type} // "") =~ /^(?:qemu|lxc)$/;
                my $name = $guest->{name} // "";
                $name =~ s/[\t\r\n]+/ /g;
                print join(
                    "\t",
                    $guest->{type},
                    $guest->{vmid},
                    $guest->{node},
                    $name
                ), "\n";
            }
        '
)

if (( ${#GUESTS[@]} == 0 )); then
    echo "No running guests have attached volumes on tank-vms or tank-containers."
    exit 0
fi

echo
echo "Running guests selected for shutdown:"

for guest in "${GUESTS[@]}"; do
    IFS='|' read -r guest_type vmid node name <<< "$guest"
    if [[ "$guest_type" == "qemu" ]]; then
        label="VM"
    else
        label="CT"
    fi
    printf '  %s %s on %s%s\n' "$label" "$vmid" "$node" "${name:+ ($name)}"
done

echo
if command -v ha-manager >/dev/null 2>&1 &&
    ha-manager status 2>/dev/null | grep -qE 'service (vm|ct):[0-9]+'; then
    echo "Warning: HA-managed guests may restart if their requested state is 'started'."
    echo "Review 'ha-manager status' before continuing."
    echo
fi

read -r -p "Type YES to gracefully shut down all guests listed above: " confirmation

if [[ "$confirmation" != "YES" ]]; then
    echo "Cancelled."
    exit 1
fi

total_batches=$(((${#GUESTS[@]} + BATCH_SIZE - 1) / BATCH_SIZE))

for ((batch_start = 0, batch_number = 1;
      batch_start < ${#GUESTS[@]};
      batch_start += BATCH_SIZE, batch_number += 1)); do
    BATCH=("${GUESTS[@]:batch_start:BATCH_SIZE}")
    PIDS=()
    dispatch_failed=0

    echo
    echo "Starting shutdown batch $batch_number of $total_batches..."

    for guest in "${BATCH[@]}"; do
        IFS='|' read -r guest_type vmid node name <<< "$guest"
        if [[ "$guest_type" == "qemu" ]]; then
            label="VM"
        else
            label="CT"
        fi

        echo "Requesting shutdown of $label $vmid on $node..."
        pvesh create "/nodes/$node/$guest_type/$vmid/status/shutdown" \
            --timeout "$SHUTDOWN_TIMEOUT" >/dev/null &
        PIDS+=("$!")
    done

    for pid in "${PIDS[@]}"; do
        if ! wait "$pid"; then
            dispatch_failed=1
        fi
    done

    if (( dispatch_failed != 0 )); then
        echo "A shutdown request in batch $batch_number failed." >&2
        echo "No additional batches will be started." >&2
        exit 1
    fi

    echo "Waiting for batch $batch_number to stop..."
    deadline=$((SECONDS + POLL_TIMEOUT))

    while (( SECONDS < deadline )); do
        running_count=0

        for guest in "${BATCH[@]}"; do
            IFS='|' read -r guest_type vmid node name <<< "$guest"
            if guest_is_running "$guest_type" "$node" "$vmid"; then
                ((running_count += 1))
            fi
        done

        (( running_count == 0 )) && break
        sleep "$POLL_INTERVAL"
    done

    STILL_RUNNING=()

    for guest in "${BATCH[@]}"; do
        IFS='|' read -r guest_type vmid node name <<< "$guest"
        if guest_is_running "$guest_type" "$node" "$vmid"; then
            if [[ "$guest_type" == "qemu" ]]; then
                label="VM"
            else
                label="CT"
            fi
            STILL_RUNNING+=("$label $vmid on $node")
        fi
    done

    if (( ${#STILL_RUNNING[@]} > 0 )); then
        echo
        echo "The following guests in batch $batch_number are still running:"
        printf '  %s\n' "${STILL_RUNNING[@]}"
        echo "No additional batches will be started."
        echo "Review them before using a force-stop command."
        exit 1
    fi

    echo "Batch $batch_number stopped successfully."
done

echo "All selected guests shut down successfully."
