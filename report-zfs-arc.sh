#!/bin/bash

# Function to convert value+unit to bytes
to_bytes() {
    local value unit
    value=$(echo "$1" | awk '{print $1}')
    unit=$(echo "$1" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        b|bytes|"") echo "$value" ;;
        kib) echo "$value * 1024" | bc ;;
        mib) echo "$value * 1024 * 1024" | bc ;;
        gib) echo "$value * 1024 * 1024 * 1024" | bc ;;
        tib) echo "$value * 1024 * 1024 * 1024 * 1024" | bc ;;
        kb) echo "$value * 1000" | bc ;;
        mb) echo "$value * 1000 * 1000" | bc ;;
        gb) echo "$value * 1000 * 1000 * 1000" | bc ;;
        tb) echo "$value * 1000 * 1000 * 1000 * 1000" | bc ;;
        *) echo "$value" ;; # fallback
    esac
}

# Capture arc_summary output once
arc_data=$(arc_summary)

# Display arc_summary output in a better tabular format
# echo "$arc_data" | sed '/^$/d' | column -t -s ':' | sed 's/^/ /'

# Extract ARC size (current)
arc_size_raw=$(echo "$arc_data" | grep -i "ARC size (current)" | head -n1 | awk -F':' '{print $2}' | awk '{$1=$1;print}' | awk '{print $(NF-1) " " $NF}')

# Extract MRU data size and MFU data size, sum them for ARC used
mru_data_raw=$(echo "$arc_data" | grep -i "MRU data size" | head -n1 | awk -F':' '{print $2}' | awk '{$1=$1;print}' | awk '{print $(NF-1) " " $NF}')
mfu_data_raw=$(echo "$arc_data" | grep -i "MFU data size" | head -n1 | awk -F':' '{print $2}' | awk '{$1=$1;print}' | awk '{print $(NF-1) " " $NF}')

# Check for empty values and warn, print arc_summary for troubleshooting
if [[ -z "$arc_size_raw" || -z "$mru_data_raw" || -z "$mfu_data_raw" ]]; then
    echo "Could not extract ARC Size or MRU/MFU data size from arc_summary output."
    echo "arc_summary output:"
    echo "$arc_data"
    exit 1
fi

# Convert to bytes
arc_size=$(to_bytes "$arc_size_raw")
mru_data=$(to_bytes "$mru_data_raw")
mfu_data=$(to_bytes "$mfu_data_raw")

# Sum MRU and MFU data for ARC used
arc_used=$(echo "$mru_data + $mfu_data" | bc)

# Calculate percentage used (using bc for floating point division)
if [[ "$arc_size" != "" && "$arc_used" != "" && "$arc_size" != "0" ]]; then
    percentage=$(echo "scale=2; $arc_used * 100 / $arc_size" | bc)
else
    percentage="N/A"
fi

echo ""
echo "ZFS ARC used: ${percentage}%"
