#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer as root: sudo ./install.sh" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR=/usr/local/sbin
UNIT_DIR=/etc/systemd/system

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "No .env file found. Let's create one."

    while :; do
        read -r -p "VM ID: " VMID
        [[ "$VMID" =~ ^[0-9]+$ ]] && break
        echo "VM ID must be a number." >&2
    done

    while :; do
        read -r -p "Storage (for example, local-zfs): " STORAGE
        [[ -n "$STORAGE" && ! "$STORAGE" =~ [[:space:]] ]] && break
        echo "Storage must be non-empty and contain no whitespace." >&2
    done

    while :; do
        read -r -p "Disk number (for example, 0): " DISK_NUMBER
        [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] && break
        echo "Disk number must be a number." >&2
    done

    umask 077
    printf 'VMID=%s\nSTORAGE=%s\nDISK_NUMBER=%s\n' \
        "$VMID" "$STORAGE" "$DISK_NUMBER" > "$SCRIPT_DIR/.env"
    echo "Created $SCRIPT_DIR/.env"
fi

# Load and validate the administrator-provided configuration before installing.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

: "${VMID:?VMID is missing or empty in $SCRIPT_DIR/.env}"
: "${STORAGE:?STORAGE is missing or empty in $SCRIPT_DIR/.env}"
: "${DISK_NUMBER:?DISK_NUMBER is missing or empty in $SCRIPT_DIR/.env}"

if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "VMID must be a number in $SCRIPT_DIR/.env" >&2
    exit 1
fi

if [[ ! "$DISK_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "DISK_NUMBER must be a number in $SCRIPT_DIR/.env" >&2
    exit 1
fi

if [[ "$STORAGE" =~ [[:space:]] ]]; then
    echo "STORAGE must not contain whitespace in $SCRIPT_DIR/.env" >&2
    exit 1
fi

install -m 0755 "$SCRIPT_DIR/proxmox-backup-toggle" "$INSTALL_DIR/proxmox-backup-toggle"
install -m 0600 "$SCRIPT_DIR/.env" "$INSTALL_DIR/.env"
install -m 0644 \
    "$SCRIPT_DIR/proxmox-backup-toggle-exclude.service" \
    "$SCRIPT_DIR/proxmox-backup-toggle-exclude.timer" \
    "$SCRIPT_DIR/proxmox-backup-toggle-include.service" \
    "$SCRIPT_DIR/proxmox-backup-toggle-include.timer" \
    "$UNIT_DIR/"

systemctl daemon-reload
systemctl enable --now proxmox-backup-toggle-exclude.timer
systemctl enable --now proxmox-backup-toggle-include.timer

echo "Installed. Timers are enabled and running."
systemctl list-timers --all 'proxmox-backup-toggle-*' --no-pager
