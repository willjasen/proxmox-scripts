#!/bin/bash

# Display arc_summary output in a better tabular format
arc_summary | sed '/^$/d' | column -t -s ':' | sed 's/^/ /'
