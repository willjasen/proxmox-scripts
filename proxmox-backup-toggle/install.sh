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
    echo "Missing $SCRIPT_DIR/.env" >&2
    echo "Copy .env.example to .env and edit it first." >&2
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
