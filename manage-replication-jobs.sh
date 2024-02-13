#!/bin/bash

# Make sure jq is installed
# apt install jq -y;

# Get all job IDs on the current server
# jobIDs=$(pvesr list | awk '{print $1}' | grep -Eo '[1-9][0-9]{2,8}-[0-9]{1,9}');

# Read in the CSV file
while IFS="," read -r jobID schedule
do
  if [ ! -z "$jobID" ]; then
    echo "Updating job ID '$jobID' to schedule of '$schedule'";
    pvesr update $jobID --schedule "$schedule";
    echo "";
  fi
done < <(tail -n +2 replication-job-settings.csv)
