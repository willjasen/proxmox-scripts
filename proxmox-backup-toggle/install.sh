#!/bin/bash
set -euo pipefail

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    BRIGHT_RED=$'\033[91m'
    BRIGHT_GREEN=$'\033[92m'
    BRIGHT_YELLOW=$'\033[93m'
    BRIGHT_BLUE=$'\033[94m'
    BRIGHT_MAGENTA=$'\033[95m'
    BRIGHT_CYAN=$'\033[96m'
    RESET=$'\033[0m'
else
    RED=''
    GREEN=''
    BRIGHT_RED=''
    BRIGHT_GREEN=''
    BRIGHT_YELLOW=''
    BRIGHT_BLUE=''
    BRIGHT_MAGENTA=''
    BRIGHT_CYAN=''
    RESET=''
fi

error() {
    printf '%s\n' "${RED}Error: $*${RESET}" >&2
}

if [[ "$(id -u)" -ne 0 ]]; then
    error "Run this installer as root: sudo ./install.sh"
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

printf '%s\n' "${GREEN}Installed. Timers are enabled and running.${RESET}"
if [[ -n "$GREEN" ]]; then
    SYSTEMD_COLORS=0 LC_ALL=C systemctl list-timers --all 'proxmox-backup-toggle-*' --no-pager |
        awk \
            -v next_color="$BRIGHT_CYAN" \
            -v left_color="$BRIGHT_YELLOW" \
            -v last_color="$BRIGHT_MAGENTA" \
            -v passed_color="$BRIGHT_BLUE" \
            -v unit_color="$BRIGHT_GREEN" \
            -v activates_color="$BRIGHT_RED" \
            -v column_separator="  |  " \
            -v reset="$RESET" '
            NR == 1 {
                next_pos = index($0, "NEXT")
                left_pos = index($0, "LEFT")
                last_pos = index($0, "LAST")
                passed_pos = index($0, "PASSED")
                unit_pos = index($0, "UNIT")
                activates_pos = index($0, "ACTIVATES")
            }
            NF == 0 || /timers? listed\.$/ { print; next }
            next_pos > 0 {
                printf "%s%s%s", next_color, substr($0, next_pos, left_pos - next_pos), reset
                printf "%s%s%s", left_color, substr($0, left_pos, last_pos - left_pos), reset
                printf "%s%s%s", last_color, substr($0, last_pos, passed_pos - last_pos), reset
                printf "%s", column_separator
                printf "%s%s%s", passed_color, substr($0, passed_pos, unit_pos - passed_pos), reset
                printf "%s%s%s", unit_color, substr($0, unit_pos, activates_pos - unit_pos), reset
                printf "%s%s%s\n", activates_color, substr($0, activates_pos), reset
                next
            }
            { print }
        '
else
    systemctl list-timers --all 'proxmox-backup-toggle-*' --no-pager
fi
