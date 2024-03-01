#!/bin/bash

# Define variables
Y=$(date +"%Y")  # Store the current year in the Y variable
M=$(date +"%m")  # Store the current month in the M variable
D=$(date +"%d")  # Store the current day in the D variable
LOG="/opscripts/convert-logs-$Y$M$D.log"  # Store the log file path in the LOG variable
DE="gs://high-priv-vdorecord/guacamole-record"
P="gs://high-priv-vdorecord/$Y/$M/$D/"  # Store the Google Cloud Storage bucket path in the P variable

# Directory to check
local_directory="/screen-records-raw"

# Iterate over files in the local directory
find "$local_directory" -type f | while read -r local_file; do
    # Extract filename from local path
    filename=$(basename "$local_file")

						FY=$(echo $FILENAME | sed 's/.*-\([0-9]\{8\}\)-.*/\1/' | cut -c1-4)
						FM=$(echo $FILENAME | sed 's/.*-\([0-9]\{8\}\)-.*/\1/' | cut -c5-6)
						FD=$(echo $FILENAME | sed 's/.*-\([0-9]\{8\}\)-.*/\1/' | cut -c7-8)
						#echo "$FY/$FM/$FD"
            
    # Check if the file exists in any subfolder of the GCS bucket
    if ! gsutil -q stat "gs://high-priv-vdorecord/guacamole-record/**/$filename"; then
        # If file does not exist in GCS bucket, upload
        #gsutil cp "/screen-records-raw/$FILENAME" "$DE/$FY/$FM/$FD/raw/"
        echo "Uploaded $local_file to GCS bucket."
        # Once uploaded, delete the file from the local directory
        #rm "$local_file"
        echo "Deleted $local_file from local directory."
    fi
done