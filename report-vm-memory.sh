# Define color variables
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"

total_memory=0
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    name=$(qm config "$vmid" | grep '^name:' | awk '{print $2}')  # extract VM name
    mem=$(qm config "$vmid" | grep '^memory:' | awk '{print $2}')
    echo "${name}: ${mem} MB"  # new echo for each VM's RAM with name
    total_memory=$((total_memory + mem))
done
# Convert total memory from MB to GB with 2 decimal places
total_memory_gb=$(echo "scale=2; ${total_memory}/1024" | bc)
echo -e "${GREEN}Total Configured RAM for all VMs: ${total_memory_gb} GB${RESET}"

# Retrieve and display the physical host's total RAM
host_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
host_memory_gb=$(echo "scale=2; ${host_memory_kb}/1024/1024" | bc)
echo -e "${GREEN}Total Physical Host RAM: ${host_memory_gb} GB${RESET}"

# Convert total VM memory from MB to KB for percentage calculation
total_memory_kb=$((total_memory * 1024))

# Calculate percentage of VM RAM usage vs. host RAM
vm_ram_percentage=$(echo "scale=2; (${total_memory_kb}/${host_memory_kb})*100" | bc)
echo -e "${YELLOW}Percentage of VM RAM usage vs. Host RAM: ${vm_ram_percentage}%${RESET}"
