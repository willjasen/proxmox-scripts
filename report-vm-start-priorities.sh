#!/bin/bash
# Report Proxmox VM and CT startup order

printf "%-4s %-6s %-6s %-12s %-12s %s\n" "TYPE" "ID" "ONBOOT" "START ORDER" "START DELAY" "NAME"


# Function to get VM info
get_vm_info() {
       for VMID in $(qm list | awk 'NR>1 {print $1}'); do
	       NAME=$(qm config $VMID | awk -F ': ' '/^name: /{print $2}')
	       ORDER=$(qm config $VMID | awk -F ': ' '/^order: /{print $2}')
	       [ -z "$ORDER" ] && ORDER="none"
	       echo -e "$ORDER\t$NAME"
       done
}

# Function to get CT info
get_ct_info() {
       for CTID in $(pct list | awk 'NR>1 {print $1}'); do
	       NAME=$(pct config $CTID | awk -F ': ' '/^hostname: /{print $2}')
	       ORDER=$(pct config $CTID | awk -F ': ' '/^order: /{print $2}')
	       [ -z "$ORDER" ] && ORDER="none"
	       echo -e "$ORDER\t$NAME"
       done
}

# Collect and sort all info by START ORDER (order field, then ID as fallback)
{
	   get_vm_info
	   get_ct_info
} | sort -k1,1n | awk -F '\t' '
BEGIN { last_order = "" }
{
	if ($1 != last_order) {
		if (last_order != "") print "";
		print "Start Order: "$1;
		last_order = $1;
	}
	print "  "$2;
}'
