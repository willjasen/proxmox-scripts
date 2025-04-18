#!/bin/bash

# Capture arc_summary output once
arc_data=$(arc_summary)

# Display arc_summary output in a better tabular format
# echo "$arc_data" | sed '/^$/d' | column -t -s ':' | sed 's/^/ /'

# Extract values and filter out any non-numeric characters (except dot)
arc_size=$(echo "$arc_data" | grep -i "ARC Size" | head -n1 | cut -d':' -f2 | sed 's/[^0-9.]//g')
arc_used=$(echo "$arc_data" | grep -i "ARC Used" | head -n1 | cut -d':' -f2 | sed 's/[^0-9.]//g')

# Calculate percentage used (using bc for floating point division)
percentage=$(echo "scale=2; $arc_used * 100 / $arc_size" | bc)

echo ""
echo "ZFS ARC used: ${percentage}%"
