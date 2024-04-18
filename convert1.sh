#!/bin/bash

# Function to print usage instructions
print_usage() {
    echo "Usage: $0 <delay_proc> <clean_proc> <bitrate> <size> <src_dir> <proc_dir> <raw_dir> <vdo_dir> <gcs_bucket> <run_mode>"
    echo "Parameters:"
    echo "  delay_proc   : Minutes before a file is considered to process"
    echo "  clean_proc   : Minutes before old files are deleted from src_dir"
    echo "  bitrate      : Bitrate for encoding"
    echo "  size         : Size for encoding"
    echo "  src_dir      : Source directory containing video files"
    echo "  proc_dir     : Processing directory for temporary storage"
    echo "  raw_dir      : Directory for raw files after uploading"
    echo "  vdo_dir      : Directory for encoded video files"
    echo "  gcs_bucket   : Google Cloud Storage bucket name"
    echo "  run_mode     : 'dry-run' to simulate without actually encoding and copying"
}

# Check if all required parameters are provided
if [ "$#" -ne 10 ]; then
    echo "Error: Missing required parameters."
    print_usage
    exit 1
fi

# Check if the script is already running
pidfile="/tmp/convert.pid"
if [ -e "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "Error: Script is already running."
    exit 1
fi
echo $$ > "$pidfile"

delay_proc=$1
clean_proc=$2
bitrate=$3
size=$4
src_dir=$5
proc_dir=$6
raw_dir=$7
vdo_dir=$8
gcs_bucket=$9
run_mode=${10}

echo "Proc DIR: $proc_dir"

# Function to get files older than delay_proc minutes
get_old_files() {
    find "$src_dir" -type f -mmin +"$delay_proc"
}

# Function to convert UTC date-time to GMT+7 date-time
convert_to_gmtplus7() {
    utc_date=$1
    utc_time=$2

    # Convert UTC date-time to epoch time
    utc_epoch=$(date -d "$utc_date $utc_time UTC" "+%s")

    # Add 7 hours (GMT+7 offset) to epoch time
    gmtplus7_epoch=$(($utc_epoch + 7*3600))

    # Convert epoch time back to date-time in GMT+7 timezone
    gmtplus7_date=$(date -d "@$gmtplus7_epoch" "+%Y%m%d")
    gmtplus7_time=$(date -d "@$gmtplus7_epoch" "+%H%M%S")

    echo "$gmtplus7_date-$gmtplus7_time"
}

# Function to rename files
rename_files() {
#    for file in *; do
    file=$1
        # Check if file matches the expected pattern
        if [[ $file =~ ^(.*)-([0-9]{8})-([0-9]{6})$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            date_part="${BASH_REMATCH[2]}"
            time_part="${BASH_REMATCH[3]}"
            
            # Split date and time parts
            utc_date="${date_part:0:4}-${date_part:4:2}-${date_part:6}"
            utc_time="${time_part:0:2}:${time_part:2:2}:${time_part:4}"

            # Convert UTC date-time to GMT+7 date-time
            new_date=$(convert_to_gmtplus7 "$utc_date" "$utc_time")

            # Generate new filename
            new_filename="$prefix-$new_date"

            # Rename the file
            mv "$file" "$new_filename"
            echo "Renamed $file to $new_filename"
        fi
#    done
}

# Function to check for duplicate files and copy them if needed
check_and_copy() {
    local src_file="$1"
    local dest_dir="$2"

    local filename=$(basename "$src_file")
    local dest_file="$dest_dir/$filename"

    #echo $dest_file
    if [ "$run_mode" != "dry-run" ]; then
        if [ -e "$dest_file" ]; then
            if ! cmp -s "$src_file" "$dest_file"; then
                # If checksums are different, copy the file
                cp "$src_file" "$dest_dir"
            fi
        else
            cp "$src_file" "$dest_dir"
        fi
    fi
}

# Function to encode and copy files
encode_and_copy() {
    local file="$1"
    local filename=$(basename "$file")
    local file_date

    echo $(basename "$file")
    echo "enc $filename"
    if [[ $filename =~ ([0-9]{8}-[0-9]{6}) ]]; then
        file_date="${BASH_REMATCH[1]}"
    else
        echo "Error: Unable to extract date from filename: $filename"
        cleanup
        exit 1
    fi
    
    local year=${file_date:0:4}
    local month=${file_date:4:2}
    local day=${file_date:6:2}

    if [ "$run_mode" = "dry-run" ]; then
    echo "Skipping encoding and uploading for $file in dry-run mode"
    echo "gs://$gcs_bucket/$year/$month/$day/vdo/$filename.m4v"
    echo "docker run --rm -d -v '$proc_dir':'/record' -v '$vdo_dir':'/converted' --name guacenc guacenc guacenc -s $size -r $bitrate -f "/record/$file""
    else
        echo "Encoding and uploading file: $file"

        # Run encoding command to convert from raw to m4v
        #guaenc "$file" "$bitrate" "$size"
        docker run --rm -v $proc_dir:/record -v $vdo_dir:/converted --name guacenc guacenc guacenc -s $size -r $bitrate -f "/record/$filename" 
        docker wait guacenc
        #docker run --rm -d -v '$proc_dir':'/record' -v '$vdo_dir':'/converted' --name guacenc guacenc guacenc -s $size -r $bitrate -f "/record/$file"
        #docker run --rm -d -v '$proc_dir':'/record' -v '$vdo_dir':'/converted' --name guacenc guacenc mv "/record/$filename.m4v" /converted/
        
        # Move the original file to raw directory
        mv "$file" "$raw_dir/$filename"
        # Move the vdo file to vdo directory
        mv "$file.m4v" "$vdo_dir/$filename.m4v"

        # Copy raw file to GCS bucket
        gsutil cp "$raw_dir/$filename" "gs://$gcs_bucket/$year/$month/$day/raw/$filename"
        echo "Copy $raw_dir/$filename to gs://$gcs_bucket/$year/$month/$day/raw/$filename"

# Copy encoded file to GCS bucket
gsutil cp "$vdo_dir/$filename.m4v" "gs://$gcs_bucket/$year/$month/$day/vdo/$filename.m4v"
echo "Copy $vdo_dir/$filename.m4v to gs://$gcs_bucket/$year/$month/$day/vdo/$filename.m4v"

    fi
}

# Function to perform cleanup
cleanup() {
    # Remove the PID file
    rm -f "$pidfile"
}

# Error handling trap
trap 'cleanup' ERR

# Get old files
old_files=$(get_old_files)

# Check and copy old files to proc_dir
for file in $old_files; do
    check_and_copy "$file" "$proc_dir"
done

for file in "$proc_dir"/*; do
#    echo "Renaming $file"
    rename_files $file
done

# Encode and copy files in proc_dir
for file in "$proc_dir"/*; do
#echo "Convert & Upload $file"
    encode_and_copy "$file"
done

# Clean up old files in src_dir
#find "$src_dir" -type f -mmin +"$clean_proc" -exec rm -f {} +
for file in $old_files; do
    rm -f $file
done

# Perform cleanup
cleanup

echo "Conversion completed."