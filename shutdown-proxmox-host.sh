#!/bin/bash

# Output that the script has started
echo -e "${GREEN}Shutdown Proxmox host script has started.${RESET}"

# Define color codes
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"
RED="\e[31m"

# Shut down Proxmox VMs
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    if qm status "$vmid" | grep -q "running"; then
        echo -e "${YELLOW}Shutting down VM $vmid...${RESET}"
        qm shutdown "$vmid" &
    fi
done

# Shut down Proxmox containers
for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    if pct status "$ctid" | grep -q "running"; then
        echo -e "${YELLOW}Shutting down container $ctid...${RESET}"
        pct shutdown "$ctid" &
    fi
done

# Wait until all are stopped
while [ "$(qm list | grep -c running)" -gt 0 -o "$(pct list | grep -c running)" -gt 0 ]; do
    echo -e "${YELLOW}Waiting for VMs and CTs to shut down...${RESET}"
    sleep 3
done

# Echo out that the VMs and CTs are shutdown in green
echo -e "${GREEN}All VMs and CTs have shut down.${RESET}"

# Shut down the host now that all VMs and CTs are stopped
echo -e "${RED}Shutting down the Proxmox host in 10 seconds...${RESET}"
sleep 10;
echo -e "${RED}Shutting down now.${RESET}"
shutdown -h now