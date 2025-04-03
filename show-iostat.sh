#!/bin/bash
command -v iostat >/dev/null || { echo "iostat not found. Please install the sysstat package." >&2; exit 1; }

iostat -d -m | (
	head -3;
	tail -n +4 | awk '$3 != "0.00"' | sort -k 3 -nr
)
