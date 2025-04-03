total_memory=0
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    mem=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}')
    total_memory=$((total_memory + mem))
done
echo "Total Configured RAM for all VMs: ${total_memory} MB"
