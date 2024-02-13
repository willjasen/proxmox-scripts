#!/bin/bash

# Output may show "trying to acquire cfs lock 'file-replication_cfg' ..." at some point but script should still finish

# EDIT: true to disable jobs, false to enable jobs
DISABLE=true;

# Make sure jq is installed
apt install jq -y;

# Get all job IDs
jobIDs=$(pvesr list | awk '{print $1}' | grep -Eo '[1-9][0-9]{2,8}-[0-9]{1,9}');

# toggle the jobs if they need to be
for jobID in $jobIDs; do
  if $DISABLE; then
    pvesr read $jobID | jq --exit-status '.disable' >/dev/null;
    if test $? -eq 1; then
      echo -e "Disabling replication job $jobID";
      pvesr update $jobID --disable $DISABLE;
    else
      echo -e "Replication job $jobID is already disabled";
    fi
  else
    pvesr read $jobID | jq --exit-status '.disable' >/dev/null;
    if test $? -eq 0; then
      echo -e "Enabling replication job $jobID";
      pvesr update $jobID --disable $DISABLE;
    else
      echo -e "Replication job $jobID is already enabled";
    fi
  fi
done;
