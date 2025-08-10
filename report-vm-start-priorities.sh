#!/bin/bash
# Report Proxmox VM and CT startup order

printf "%-4s %-6s %-6s %-12s %-12s %s\n" "TYPE" "ID" "ONBOOT" "START ORDER" "START DELAY" "NAME"

# Function to get VM info
get_vm_info() {
	qm list | awk 'NR>1' | while read -r VMID STATUS REST; do
		if [[ "$STATUS" != "running" ]]; then
			continue
		fi
		NAME=$(qm config $VMID | awk -F ': ' '/^name: /{print $2}')
		ONBOOT=$(qm config $VMID | awk -F ': ' '/^onboot: /{print $2}')
		ORDER=$(qm config $VMID | awk -F ': ' '/^order: /{print $2}')
		STARTDELAY=$(qm config $VMID | awk -F ': ' '/^startup: /{print $2}' | awk -F "," '{for(i=1;i<=NF;i++){if($i ~ /^up=/){print substr($i,4)}}}')
		[ -z "$ONBOOT" ] && ONBOOT="no"
		[ -z "$ORDER" ] && ORDER=""
		[ -z "$STARTDELAY" ] && STARTDELAY=""
		printf "%-4s %-6s %-6s %-12s %-12s %s\n" "VM" "$VMID" "$ONBOOT" "${ORDER:-}" "${STARTDELAY:-}" "$NAME"
	done
}

# Function to get CT info
get_ct_info() {
	pct list | awk 'NR>1' | while read -r CTID STATUS REST; do
		if [[ "$STATUS" != "running" ]]; then
			continue
		fi
		NAME=$(pct config $CTID | awk -F ': ' '/^hostname: /{print $2}')
		ONBOOT=$(pct config $CTID | awk -F ': ' '/^onboot: /{print $2}')
		ORDER=$(pct config $CTID | awk -F ': ' '/^order: /{print $2}')
		STARTDELAY=$(pct config $CTID | awk -F ': ' '/^startup: /{print $2}' | awk -F "," '{for(i=1;i<=NF;i++){if($i ~ /^up=/){print substr($i,4)}}}')
		[ -z "$ONBOOT" ] && ONBOOT="no"
		[ -z "$ORDER" ] && ORDER=""
		[ -z "$STARTDELAY" ] && STARTDELAY=""
		printf "%-4s %-6s %-6s %-12s %-12s %s\n" "CT" "$CTID" "$ONBOOT" "${ORDER:-}" "${STARTDELAY:-}" "$NAME"
	done
}

# Collect and sort all info by START ORDER (order field, then ID as fallback)
{
	get_vm_info
	get_ct_info
} | sort -k5,5n -k2,2n
