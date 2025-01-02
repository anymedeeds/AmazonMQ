#!/bin/bash

# Script for backing up AmazonMQ configurations and queues.
# Handles schedule-based execution, reads configurations from YAML, and uploads backups to S3.

set -e

CONFIG_FILE=$1   # Path to the YAML file (e.g., qa.yaml, stage.yaml, prod.yaml)
BACKUP_DIR=$2    # Directory to store the backup locally
S3_BUCKET=$3     # S3 bucket name for backups
S3_BACKUP_PATH=$4  # S3 folder path within the bucket
REGION=${5:-us-east-1}  # AWS region (default: us-east-1)

# Function to read YAML and extract fields
function parse_yaml() {
    local yaml_file=$1
    python3 -c "
import yaml, sys
with open('$yaml_file', 'r') as f:
    data = yaml.safe_load(f)
    for instance in data['amq_instances']:
        print(f\"{instance['name']}|{instance['host']}|{instance['secret_name']}|{instance['schedule']}\")
" 
}

# Function to retrieve values from AWS Systems Manager Parameter Store
function get_parameter_value() {
    local parameter_name=$1
    local region=$2
    aws ssm get-parameter --name "$parameter_name" --region "$region" --query 'Parameter.Value' --output text
}

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Parse YAML file and process each instance
parse_yaml "$CONFIG_FILE" | while IFS='|' read -r name host_param password_param schedule; do
    echo "Processing $name with schedule: $schedule"

    # Determine if the backup should run based on the schedule
    today=$(date '+%A' | tr '[:upper:]' '[:lower:]')  # e.g., "monday"
    day_of_month=$(date '+%d')  # e.g., "01"
    should_backup=false

    case "$schedule" in
        daily)
            should_backup=true
            ;;
        weekly)
            if [ "$today" = "sunday" ]; then
                should_backup=true
            fi
            ;;
        monthly)
            if [ "$day_of_month" = "01" ]; then
                should_backup=true
            fi
            ;;
    esac

    if [ "$should_backup" = true ]; then
        echo "Initiating backup for $name..."

        # Retrieve host and password from Parameter Store
        host=$(get_parameter_value "$host_param" "$REGION")
        password=$(get_parameter_value "$password_param" "$REGION")

        if [ -z "$host" ] || [ -z "$password" ]; then
            echo "Failed to retrieve host or password for $name. Skipping..."
            continue
        fi

        # Perform backup (dummy example for illustration)
        instance_backup_dir="$BACKUP_DIR/$name"
        mkdir -p "$instance_backup_dir"
        echo "Backing up configuration and queues for $name ($host)..." 
        # Add actual backup logic here (e.g., RabbitMQ commands to export configuration and queues)

        echo "Configuration for $name" > "$instance_backup_dir/config.json"
        echo "Queue data for $name" > "$instance_backup_dir/queues.json"

        # Upload to S3
        echo "Uploading backup for $name to S3..."
        aws s3 cp "$instance_backup_dir/" "s3://$S3_BUCKET/$S3_BACKUP_PATH/$name/" --recursive
    else
        echo "Skipping backup for $name. Schedule does not match today's date."
    fi
done

echo "Backup process completed!"
