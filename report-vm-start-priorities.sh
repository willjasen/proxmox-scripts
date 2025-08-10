#!/bin/bash
# Report Proxmox VM and CT startup order

echo -e "TYPE\tID\tONBOOT\tSTART ORDER\tSTART DELAY\tNAME"

# Function to get VM info
get_vm_info() {
	for VMID in $(qm list | awk 'NR>1 {print $1}'); do
		NAME=$(qm config $VMID | awk -F ': ' '/^name: /{print $2}')
		ONBOOT=$(qm config $VMID | awk -F ': ' '/^onboot: /{print $2}')
		ORDER=$(qm config $VMID | awk -F ': ' '/^order: /{print $2}')
		STARTDELAY=$(qm config $VMID | awk -F ': ' '/^startup: /{print $2}' | awk -F "," '{for(i=1;i<=NF;i++){if($i ~ /^up=/){print substr($i,4)}}}')
		[ -z "$ONBOOT" ] && ONBOOT="no"
		[ -z "$ORDER" ] && ORDER=""
		[ -z "$STARTDELAY" ] && STARTDELAY=""
	echo -e "VM\t$VMID\t$ONBOOT\t$ORDER\t$STARTDELAY\t$NAME"
	done
}

# Function to get CT info
get_ct_info() {
	for CTID in $(pct list | awk 'NR>1 {print $1}'); do
		NAME=$(pct config $CTID | awk -F ': ' '/^hostname: /{print $2}')
		ONBOOT=$(pct config $CTID | awk -F ': ' '/^onboot: /{print $2}')
		ORDER=$(pct config $CTID | awk -F ': ' '/^order: /{print $2}')
		STARTDELAY=$(pct config $CTID | awk -F ': ' '/^startup: /{print $2}' | awk -F "," '{for(i=1;i<=NF;i++){if($i ~ /^up=/){print substr($i,4)}}}')
		[ -z "$ONBOOT" ] && ONBOOT="no"
		[ -z "$ORDER" ] && ORDER=""
		[ -z "$STARTDELAY" ] && STARTDELAY=""
	echo -e "CT\t$CTID\t$ONBOOT\t$ORDER\t$STARTDELAY\t$NAME"
	done
}

# Collect and sort all info by START ORDER (order field, then ID as fallback)
{
	get_vm_info
	get_ct_info
} | sort -k5,5n -k2,2n
