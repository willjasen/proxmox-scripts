#!/bin/bash

# --- PARAMETERS ---
# - first parameter can be either 'read' or 'update'
#   - update will update the jobs and read will save the current job configuration


# --- CONSTANTS ---
SETTINGS_FILE=replication-job-settings.csv;


# --- FUNCTIONS ---

read_jobs () {
  # Delete the existing settings
  if test -f $SETTINGS_FILE; then
    rm $SETTINGS_FILE;
  fi

  # Create header line in CSV
  echo "jobID,schedule,comment" | tee -a $SETTINGS_FILE;

  # Save all the current job settings into the settings file
  jobIDs=$(pvesr list | awk '{print $1}' | grep -Eo '[1-9][0-9]{2,8}-[0-9]{1,9}');
  for jobID in $jobIDs; do
    curJobSchedule=$(pvesr read $jobID | jq -r '.schedule');
    comment=$(pvesr read $jobID | jq -r '.comment');
    echo "$jobID,$curJobSchedule,$comment" | tee -a $SETTINGS_FILE;
  done;
}

update_jobs () {
  # Read in the CSV file
  while IFS="," read -r jobID schedule comment
  do
    if [ ! -z "$jobID" ]; then

      curJobSchedule=$(pvesr read $jobID | jq -r '.schedule');
      if [[ "$curJobSchedule" != "$schedule" ]]; then
        echo "Updating job ID '$jobID' to schedule of '$schedule'";
        pvesr update $jobID --schedule "$schedule" --comment "$comment";
      else
        echo "Job ID '$jobID' already has the schedule '$schedule'";
      fi

    fi
  done < <(tail -n +2 $SETTINGS_FILE)
}

# -- END FUNCTIONS ---

# Install jq if not detected
if [ -z $(which jq) ]; then
  apt install jq -y;
fi

# Determine how script should run
if [[ "$1" == "read" ]]; then
  read_jobs
elif [[ "$1" == "update" ]]; then
  update_jobs
else
  echo "Script parameter was not valid";
fi
