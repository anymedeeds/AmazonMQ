#!/bin/bash

# Script for backing up AmazonMQ configurations and queues.
# Handles schedule-based execution, reads configurations from YAML, and uploads backups to S3.

set -e

CONFIG_FILE=$1   # Path to the YAML file (e.g., qa.yaml, stage.yaml, prod.yaml)
S3_BUCKET=$2     # S3 bucket name for backups
S3_BACKUP_PATH=$3  # S3 folder path within the bucket
REGION=${4:-us-east-1}  # AWS region (default: us-east-1)

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

# Parse YAML file and process each instance
parse_yaml "$CONFIG_FILE" | while IFS='|' read -r name host_param secret_param schedule; do
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

        # Retrieve host and secret from Parameter Store
        host=$host_param  # Host is passed directly from the YAML file
        password=$(get_parameter_value "$secret_param" "$REGION")  # Password (secret) is retrieved from Parameter Store

        if [ -z "$host" ] || [ -z "$password" ]; then
            echo "Failed to retrieve host or secret for $name. Skipping..."
            continue
        fi

        # Simulate backup data (for example, retrieve configuration and queues data)
        config_data="Configuration data for $name ($host)"
        queue_data="Queue data for $name ($host)"

        # Upload the backup data directly to S3 (no local directory)
        echo "$config_data" | aws s3 cp - "s3://$S3_BUCKET/$S3_BACKUP_PATH/$name/config.json" --region "$REGION"
        echo "$queue_data" | aws s3 cp - "s3://$S3_BUCKET/$S3_BACKUP_PATH/$name/queues.json" --region "$REGION"

        echo "Backup for $name completed and uploaded to S3."
    else
        echo "Skipping backup for $name. Schedule does not match today's date."
    fi
done

echo "Backup process completed!"
