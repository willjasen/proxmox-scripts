#!/bin/bash

# --- PARAMETERS ---
# - action can be either 'run' or 'read'
#   - run will update the jobs and read will save the current job configuration

# Install jq if not detected
if [ -z $(which jq) ]; then
  apt install jq -y;
fi

# Get all job IDs on the current server
# jobIDs=$(pvesr list | awk '{print $1}' | grep -Eo '[1-9][0-9]{2,8}-[0-9]{1,9}');

# Read in the CSV file
while IFS="," read -r jobID schedule
do
  if [ ! -z "$jobID" ]; then

    curJobSchedule=$(pvesr read $jobID | jq -r '.schedule');
    if [[ "$curJobSchedule" != "$schedule" ]]; then
      echo "Updating job ID '$jobID' to schedule of '$schedule'";
      pvesr update $jobID --schedule "$schedule";
      echo "";
    else
      echo "Job ID '$jobID' already has the schedule '$schedule'";
    fi

  fi
done < <(tail -n +2 replication-job-settings.csv)
