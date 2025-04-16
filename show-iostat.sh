#!/bin/bash
command -v iostat >/dev/null || {
    echo "iostat not found. Installing sysstat package..." >&2;
    if command -v apt-get >/dev/null; then
        sudo apt-get update && sudo apt-get install -y sysstat || { echo "Failed to install sysstat." >&2; exit 1; }
    elif command -v yum >/dev/null; then
        sudo yum install -y sysstat || { echo "Failed to install sysstat." >&2; exit 1; }
    else
        echo "Unsupported package manager. Please install sysstat manually." >&2;
        exit 1;
    fi
}

iostat -d -m | (
    head -3;
    tail -n +4 | awk '$3 != "0.00"' | sort -k 3 -nr
)
