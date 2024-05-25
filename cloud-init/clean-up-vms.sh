#!/bin/bash

# This script can destroy any VMs related to testing prepare-template.sh (4 digit VM IDs that start wtih 9)

for VM_ID in $(qm list | awk '{print $1}' | grep -Eo '[9][0-9]{1,3}'); do 
    qm stop $VM_ID;
    qm destroy $VM_ID;
    echo "Destroyed VM - $VM_ID"
done;
