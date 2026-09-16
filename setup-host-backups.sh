#!/usr/bin/env bash
set -euo pipefail

PBS_STORAGE="${PBS_STORAGE:-PBS1}"
INSTALL_DIR="${INSTALL_DIR:-/etc/proxmox-host-backup}"
RUNNER="${RUNNER:-/usr/local/sbin/proxmox-host-backup}"
SERVICE="${SERVICE:-/etc/systemd/system/proxmox-host-backup.service}"
TIMER="${TIMER:-/etc/systemd/system/proxmox-host-backup.timer}"
ENV_FILE="${ENV_FILE:-${INSTALL_DIR}/env}"
PBS_CREDENTIALS_FILE="${PBS_CREDENTIALS_FILE:-${INSTALL_DIR}/pbs-credentials}"
EXCLUDE_FILE="${EXCLUDE_FILE:-${INSTALL_DIR}/exclude}"
INCLUDE_FILE="${INCLUDE_FILE:-${INSTALL_DIR}/include}"
ON_CALENDAR="${ON_CALENDAR:-03:15}"
BACKUP_ID="${BACKUP_ID:-$(hostname -s)}"
NAMESPACE="${NAMESPACE:-}"
NAMESPACE_SET=0
PBS_FINGERPRINT_INPUT="${PBS_FINGERPRINT:-}"
PBS_HOST_INPUT="${PBS_HOST:-}"
PBS_DATASTORE_INPUT="${PBS_DATASTORE:-}"
PBS_API_TOKEN_INPUT="${PBS_API_TOKEN:-}"
DRY_RUN=0
FORCE=0
ENABLE_TIMER=1
SCHEDULE_SET=0

RESET=$'\033[0m'
BOLD=$'\033[1m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Sets up automated Proxmox host backups to the existing PBS storage "$PBS_STORAGE".

Options:
  --storage NAME          Proxmox PBS storage name (default: PBS1)
  --schedule SPEC        systemd OnCalendar value (default: ask, prefilled with 03:15)
  --backup-id NAME       PBS backup-id (default: short hostname)
  --namespace NAME       PBS namespace (default: ask, prefilled from storage when available)
  --pbs-host HOST        PBS host or host:port (Tailscale names are okay)
  --datastore NAME       PBS datastore
  --api-token NAME       PBS API token name, such as backups@pbs!pve-cluster
  --credentials PATH     Credential file with PBS_REPOSITORY and PBS_PASSWORD or PBS_PASSWORD_FILE
  --fingerprint VALUE    PBS certificate fingerprint when needed
  --no-enable            Install files but do not enable/start the timer
  --force                Overwrite existing installed config files
  --dry-run              Print planned actions without writing files
  -h, --help             Show this help

Examples:
  sudo $0
  sudo $0 --schedule 'Mon..Sat 03:15'
  sudo PBS_STORAGE=PBS1 NAMESPACE=hosts $0
EOF
}

die() {
    printf '%s\n' "${RED}${BOLD}ERROR:${RESET} $*" >&2
    exit 1
}

warn() {
    printf '%s\n' "${YELLOW}${BOLD}WARNING:${RESET} $*" >&2
}

plain_warn() {
    printf '%s\n' "WARNING: $*" >&2
}

info() {
    printf '%s\n' "${GREEN}${BOLD}==>${RESET} $*"
}

quote_env() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY RUN: %s\n' "$*"
    else
        "$@"
    fi
}

write_file() {
    local path="$1"
    local mode="$2"
    local content="$3"
    local overwrite="${4:-$FORCE}"

    if [[ -e "$path" && "$overwrite" -ne 1 ]]; then
        warn "$path already exists; leaving it unchanged. Use --force to overwrite it."
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY RUN: write %s (%s)\n' "$path" "$mode"
        return 0
    fi

    install -d -m 0750 "$(dirname "$path")"
    umask 077
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
}

storage_value() {
    local key="$1"

    [[ -r /etc/pve/storage.cfg ]] || return 0

    awk -v storage="$PBS_STORAGE" -v key="$key" '
        $1 == "pbs:" && $2 == storage {
            in_storage=1
            next
        }
        /^[^[:space:]]/ {
            in_storage=0
        }
        in_storage && $1 == key {
            print $2
            exit
        }
    ' /etc/pve/storage.cfg
}

list_pbs_storages() {
    [[ -r /etc/pve/storage.cfg ]] || return 0

    awk '$1 == "pbs:" { print $2 }' /etc/pve/storage.cfg
}

storage_exists() {
    local storage="$1"

    list_pbs_storages | awk -v storage="$storage" '$1 == storage { found=1 } END { exit !found }'
}

resolve_pbs_storage() {
    local requested="$1"
    local matches=()
    local selected=""

    if storage_exists "$requested"; then
        PBS_STORAGE="$requested"
        return 0
    fi

    mapfile -t matches < <(
        list_pbs_storages |
            awk -v requested="$requested" '
                BEGIN {
                    requested_lc = tolower(requested)
                }
                {
                    storage_lc = tolower($1)
                    if (storage_lc == requested_lc || storage_lc ~ "^" requested_lc "[-_].*") {
                        print $1
                    }
                }
            '
    )

    if [[ "${#matches[@]}" -eq 1 ]]; then
        PBS_STORAGE="${matches[0]}"
        info "Using PBS storage '$PBS_STORAGE' for requested storage '$requested'"
        return 0
    fi

    if [[ "${#matches[@]}" -gt 1 ]]; then
        warn "Multiple PBS storages match '$requested': ${matches[*]}"
    else
        warn "PBS storage '$requested' was not found."
    fi

    selected="$(prompt_value "PBS storage name" "${matches[0]:-$requested}")"
    PBS_STORAGE="$selected"
}

prompt_value() {
    local prompt="$1"
    local default_value="${2:-}"
    local value=""

    [[ -t 0 ]] || die "$prompt is required, but this is not an interactive terminal."

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " value
        printf '%s\n' "${value:-$default_value}"
    else
        while [[ -z "$value" ]]; do
            read -r -p "$prompt: " value
        done
        printf '%s\n' "$value"
    fi
}

prompt_optional_value() {
    local prompt="$1"
    local default_value="${2:-}"
    local value=""

    [[ -t 0 ]] || die "$prompt is required, but this is not an interactive terminal."

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " value
        printf '%s\n' "${value:-$default_value}"
    else
        read -r -p "$prompt: " value
        printf '%s\n' "$value"
    fi
}

prompt_secret() {
    local prompt="$1"
    local value=""

    [[ -t 0 ]] || die "$prompt is required, but this is not an interactive terminal."

    while [[ -z "$value" ]]; do
        read -r -s -p "$prompt: " value
        printf '\n' >&2
    done

    printf '%s\n' "$value"
}

write_pbs_credentials() {
    local credentials_file="$1"
    local repository="$2"
    local token_secret="$3"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY RUN: write %s (0600)\n' "$credentials_file"
        return 0
    fi

    install -d -m 0750 "$(dirname "$credentials_file")"
    umask 077
    {
        printf '%s\n' "# Created by setup-host-backups.sh"
        printf 'PBS_REPOSITORY=%s\n' "$(quote_env "$repository")"
        printf 'PBS_PASSWORD=%s\n' "$(quote_env "$token_secret")"
    } > "$credentials_file"
    chmod 0600 "$credentials_file"
}

repository_token() {
    local repository="$1"

    [[ "$repository" == *@* ]] || return 0
    printf '%s\n' "${repository%@*}"
}

repository_host() {
    local repository="$1"
    local host_datastore=""

    [[ "$repository" == *@* ]] || return 0
    host_datastore="${repository##*@}"
    [[ "$host_datastore" == *:* ]] || return 0
    printf '%s\n' "${host_datastore%:*}"
}

repository_datastore() {
    local repository="$1"
    local host_datastore=""

    [[ "$repository" == *@* ]] || return 0
    host_datastore="${repository##*@}"
    [[ "$host_datastore" == *:* ]] || return 0
    printf '%s\n' "${host_datastore##*:}"
}

prompt_and_write_pbs_credentials() {
    local credentials_file="$1"
    local default_repository="$2"
    local pbs_host="${PBS_HOST_INPUT:-}"
    local datastore="${PBS_DATASTORE_INPUT:-}"
    local api_token="${PBS_API_TOKEN_INPUT:-}"
    local repository=""
    local token_secret=""

    pbs_host="${pbs_host:-$(repository_host "$default_repository")}"
    datastore="${datastore:-$(repository_datastore "$default_repository")}"
    api_token="${api_token:-$(repository_token "$default_repository")}"

    pbs_host="$(prompt_value "PBS host or host:port" "$pbs_host")"
    datastore="$(prompt_value "PBS datastore" "$datastore")"
    api_token="$(prompt_value "PBS API token name" "$api_token")"
    repository="${api_token}@${pbs_host}:${datastore}"

    token_secret="$(prompt_secret "PBS API token secret")"
    write_pbs_credentials "$credentials_file" "$repository" "$token_secret"
}

prompt_schedule_settings() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    if [[ -e "$TIMER" && "$FORCE" -ne 1 && "$SCHEDULE_SET" -ne 1 ]]; then
        return 0
    fi

    if [[ "$SCHEDULE_SET" -ne 1 ]]; then
        ON_CALENDAR="$(prompt_value "Backup schedule (systemd OnCalendar)" "$ON_CALENDAR")"
    fi
}

prompt_namespace() {
    if [[ "$DRY_RUN" -eq 1 || "$NAMESPACE_SET" -eq 1 ]]; then
        return 0
    fi

    NAMESPACE="$(prompt_optional_value "PBS namespace (blank for datastore root)" "$NAMESPACE")"
}

host_backup_namespace() {
    local storage_namespace="$1"

    if [[ -z "$storage_namespace" ]]; then
        printf '%s\n' "hosts"
    elif [[ "$storage_namespace" == */* ]]; then
        printf '%s\n' "${storage_namespace%/*}/hosts"
    else
        printf '%s\n' "hosts"
    fi
}

validate_pbs_credentials() {
    local credentials_file="$1"
    local fingerprint="$2"
    local output=""
    local rc=0

    if [[ -z "$credentials_file" ]]; then
        plain_warn "No PBS credential file was configured."
        return 1
    fi

    if [[ ! -r "$credentials_file" ]]; then
        plain_warn "Cannot read PBS credential file: $credentials_file"
        return 1
    fi

    output="$(
        # The credential file is administrator-controlled and contains shell assignments.
        # shellcheck disable=SC1090
        source "$credentials_file"
        : "${PBS_REPOSITORY:?PBS_REPOSITORY is required in $credentials_file}"
        export PBS_REPOSITORY
        export PBS_FINGERPRINT="${PBS_FINGERPRINT:-$fingerprint}"

        if [[ -n "${PBS_PASSWORD_FILE:-}" ]]; then
            export PBS_PASSWORD_FILE
        elif [[ -n "${PBS_PASSWORD:-}" ]]; then
            export PBS_PASSWORD
        else
            echo "PBS_PASSWORD or PBS_PASSWORD_FILE is required in $credentials_file" >&2
            exit 1
        fi

        proxmox-backup-client status
    )" 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output" >&2
        fi
        return "$rc"
    fi

    return 0
}

resolve_pbs_settings() {
    local detected_repository="$1"
    local detected_secret_file="$2"
    local detected_fingerprint="$3"
    local credentials_file="$PBS_CREDENTIALS_FILE"
    local fingerprint="$PBS_FINGERPRINT_INPUT"

    if [[ -r "$ENV_FILE" ]]; then
        # The existing env file is administrator-controlled and contains shell assignments.
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        credentials_file="${PBS_CREDENTIALS_FILE:-$credentials_file}"
        fingerprint="${fingerprint:-${PBS_FINGERPRINT:-}}"
    fi

    fingerprint="${fingerprint:-$detected_fingerprint}"

    if [[ ! -e "$credentials_file" && -n "$detected_repository" && -r "$detected_secret_file" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            printf 'DRY RUN: write %s (0600)\n' "$credentials_file"
        else
            install -d -m 0750 "$(dirname "$credentials_file")"
            umask 077
            {
                printf '%s\n' "# Created by setup-host-backups.sh"
                printf 'PBS_REPOSITORY=%s\n' "$(quote_env "$detected_repository")"
                printf 'PBS_PASSWORD_FILE=%s\n' "$(quote_env "$detected_secret_file")"
            } > "$credentials_file"
            chmod 0600 "$credentials_file"
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        PBS_CREDENTIALS_FILE_RESOLVED="$credentials_file"
        PBS_FINGERPRINT_RESOLVED="$fingerprint"
        return 0
    fi

    while ! validate_pbs_credentials "$credentials_file" "$fingerprint"; do
        plain_warn "The PBS credential file is missing or failed validation."
        credentials_file="$(prompt_value "Where should the PBS credentials be saved" "$credentials_file")"
        fingerprint="$(prompt_value "PBS_FINGERPRINT (blank if not needed)" "$fingerprint")"
        prompt_and_write_pbs_credentials "$credentials_file" "$detected_repository"
    done

    PBS_CREDENTIALS_FILE_RESOLVED="$credentials_file"
    PBS_FINGERPRINT_RESOLVED="$fingerprint"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage)
            [[ $# -ge 2 ]] || die "--storage requires a value"
            PBS_STORAGE="$2"
            shift 2
            ;;
        --schedule)
            [[ $# -ge 2 ]] || die "--schedule requires a value"
            ON_CALENDAR="$2"
            SCHEDULE_SET=1
            shift 2
            ;;
        --backup-id)
            [[ $# -ge 2 ]] || die "--backup-id requires a value"
            BACKUP_ID="$2"
            shift 2
            ;;
        --namespace)
            [[ $# -ge 2 ]] || die "--namespace requires a value"
            NAMESPACE="$2"
            NAMESPACE_SET=1
            shift 2
            ;;
        --pbs-host)
            [[ $# -ge 2 ]] || die "--pbs-host requires a value"
            PBS_HOST_INPUT="$2"
            shift 2
            ;;
        --datastore)
            [[ $# -ge 2 ]] || die "--datastore requires a value"
            PBS_DATASTORE_INPUT="$2"
            shift 2
            ;;
        --api-token)
            [[ $# -ge 2 ]] || die "--api-token requires a value"
            PBS_API_TOKEN_INPUT="$2"
            shift 2
            ;;
        --credentials)
            [[ $# -ge 2 ]] || die "--credentials requires a value"
            PBS_CREDENTIALS_FILE="$2"
            shift 2
            ;;
        --fingerprint)
            [[ $# -ge 2 ]] || die "--fingerprint requires a value"
            PBS_FINGERPRINT_INPUT="$2"
            shift 2
            ;;
        --no-enable)
            ENABLE_TIMER=0
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root on a Proxmox node."
[[ -d /etc/pve ]] || die "/etc/pve was not found. Run this on a Proxmox cluster node."
command -v proxmox-backup-client >/dev/null || die "proxmox-backup-client is not installed."
command -v systemctl >/dev/null || die "systemctl is not available."

resolve_pbs_storage "$PBS_STORAGE"

server="$(storage_value server)"
datastore="$(storage_value datastore)"
username="$(storage_value username)"
fingerprint="$(storage_value fingerprint)"
port="$(storage_value port)"
storage_namespace="$(storage_value namespace)"

NAMESPACE="${NAMESPACE:-$(host_backup_namespace "$storage_namespace")}"

password_file="/etc/pve/priv/storage/${PBS_STORAGE}.pw"

repository=""
if [[ -n "$server" && -n "$datastore" && -n "$username" ]]; then
    repository_host="${PBS_HOST_INPUT:-$server}"
    if [[ -n "$port" && "$repository_host" != *:* ]]; then
        repository_host="${repository_host}:${port}"
    fi
    repository="${username}@${repository_host}:${datastore}"
fi

resolve_pbs_settings "$repository" "$password_file" "$fingerprint"
credentials_file="$PBS_CREDENTIALS_FILE_RESOLVED"
fingerprint="$PBS_FINGERPRINT_RESOLVED"

prompt_schedule_settings
prompt_namespace

runner_content='#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/proxmox-host-backup/env}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/etc/proxmox-host-backup/exclude}"
INCLUDE_FILE="${INCLUDE_FILE:-/etc/proxmox-host-backup/include}"

[[ -r "$ENV_FILE" ]] || {
    echo "Environment file not found: $ENV_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${PBS_CREDENTIALS_FILE:?PBS_CREDENTIALS_FILE is required}"
: "${BACKUP_ID:?BACKUP_ID is required}"

export PBS_FINGERPRINT="${PBS_FINGERPRINT:-}"

[[ -r "$PBS_CREDENTIALS_FILE" ]] || {
    echo "PBS credential file not found: $PBS_CREDENTIALS_FILE" >&2
    exit 1
}

if grep -Eq "^[[:space:]]*PBS_" "$PBS_CREDENTIALS_FILE"; then
    # The credential file is administrator-controlled and contains shell assignments.
    # shellcheck disable=SC1090
    source "$PBS_CREDENTIALS_FILE"
else
    echo "PBS credential file must contain PBS_REPOSITORY and PBS_PASSWORD or PBS_PASSWORD_FILE: $PBS_CREDENTIALS_FILE" >&2
    exit 1
fi

: "${PBS_REPOSITORY:?PBS_REPOSITORY is required in $PBS_CREDENTIALS_FILE}"
export PBS_REPOSITORY

if [[ -n "${PBS_PASSWORD_FILE:-}" ]]; then
    export PBS_PASSWORD_FILE
elif [[ -n "${PBS_PASSWORD:-}" ]]; then
    export PBS_PASSWORD
else
    echo "PBS_PASSWORD or PBS_PASSWORD_FILE is required in $PBS_CREDENTIALS_FILE" >&2
    exit 1
fi

args=(backup "--backup-id" "$BACKUP_ID")

if [[ -n "${PBS_NAMESPACE:-}" ]]; then
    args+=("--ns" "$PBS_NAMESPACE")
fi

if [[ -r "$EXCLUDE_FILE" ]]; then
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        [[ -n "$pattern" && "${pattern:0:1}" != "#" ]] || continue
        args+=("--exclude" "$pattern")
    done < "$EXCLUDE_FILE"
fi

if [[ -r "$INCLUDE_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
        archive="${line%%:*}"
        path="${line#*:}"
        [[ -n "$archive" && -n "$path" && "$archive" != "$path" ]] || {
            echo "Invalid include entry: $line" >&2
            exit 1
        }
        args+=("${archive}.pxar:${path}")
    done < "$INCLUDE_FILE"
else
    args+=("root.pxar:/")
fi

exec proxmox-backup-client "${args[@]}"
'

env_content="# Created by setup-host-backups.sh
PBS_CREDENTIALS_FILE=$(quote_env "$credentials_file")
PBS_FINGERPRINT=$(quote_env "$fingerprint")
PBS_NAMESPACE=$(quote_env "$NAMESPACE")
BACKUP_ID=$(quote_env "$BACKUP_ID")"

exclude_content='# Exclude volatile or generated host paths from root.pxar.
/dev
/proc
/sys
/run
/tmp
/var/tmp
/mnt
/media
/lost+found
/var/lib/vz/dump
/var/lib/vz/images
/var/lib/vz/template/cache
/var/log/journal'

include_content='# archive:path entries passed to proxmox-backup-client.
# Keep this focused on host configuration, not VM/CT data or the full root filesystem.
etc:/etc
pve-cluster:/etc/pve
root:/root
usr-local:/usr/local
opt-proxmox-scripts:/opt/proxmox-scripts
var-spool-cron:/var/spool/cron'

service_content="[Unit]
Description=Proxmox host backup to ${PBS_STORAGE}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${RUNNER}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7"

timer_content="[Unit]
Description=Run Proxmox host backup to ${PBS_STORAGE}

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target"

timer_overwrite="$FORCE"
if [[ "$SCHEDULE_SET" -eq 1 ]]; then
    timer_overwrite=1
fi

info "Using Proxmox PBS storage '$PBS_STORAGE'"
[[ -n "$NAMESPACE" ]] && info "Backups will use PBS namespace '$NAMESPACE'"
info "Installing host backup runner"

run install -d -m 0750 "$INSTALL_DIR"
write_file "$RUNNER" 0755 "$runner_content"
write_file "$ENV_FILE" 0600 "$env_content"
write_file "$EXCLUDE_FILE" 0640 "$exclude_content"
write_file "$INCLUDE_FILE" 0640 "$include_content"
write_file "$SERVICE" 0644 "$service_content"
write_file "$TIMER" 0644 "$timer_content" "$timer_overwrite"

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry run complete"
    exit 0
fi

systemctl daemon-reload

if [[ "$ENABLE_TIMER" -eq 1 ]]; then
    systemctl enable --now "$(basename "$TIMER")"
    info "Timer enabled: $(basename "$TIMER")"
else
    info "Timer installed but not enabled"
fi

cat <<EOF

Installed host backups to ${PBS_STORAGE}.

Useful commands:
  systemctl list-timers proxmox-host-backup.timer
  systemctl start proxmox-host-backup.service
  journalctl -u proxmox-host-backup.service

Config files:
  ${ENV_FILE}
  ${INCLUDE_FILE}
  ${EXCLUDE_FILE}
EOF
