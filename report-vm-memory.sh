total_memory=0
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    name=$(qm config "$vmid" | grep '^name:' | awk '{print $2}')  # extract VM name
    mem=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}')
    echo "${name}: ${mem} MB"  # new echo for each VM's RAM with name
    total_memory=$((total_memory + mem))
done
# Convert total memory from MB to GB with 2 decimal places
total_memory_gb=$(echo "scale=2; ${total_memory}/1024" | bc)
echo "Total Configured RAM for all VMs: ${total_memory_gb} GB"
