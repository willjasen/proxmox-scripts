#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run the uninstaller as root: sudo ./uninstall.sh" >&2
    exit 1
fi

systemctl disable --now \
    proxmox-backup-toggle-exclude.timer \
    proxmox-backup-toggle-include.timer 2>/dev/null || true

rm -f \
    /etc/systemd/system/proxmox-backup-toggle-exclude.service \
    /etc/systemd/system/proxmox-backup-toggle-exclude.timer \
    /etc/systemd/system/proxmox-backup-toggle-include.service \
    /etc/systemd/system/proxmox-backup-toggle-include.timer \
    /usr/local/sbin/proxmox-backup-toggle \
    /usr/local/sbin/.env

systemctl daemon-reload

echo "Uninstalled the Proxmox backup toggle timers, service files, script, and installed .env."
