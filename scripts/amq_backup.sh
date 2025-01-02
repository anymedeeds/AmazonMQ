#!/bin/bash

# Arguments: AMQ name, environment, AWS region, backup directory
AMQ_NAME=$1
ENV=$2
REGION=$3
BACKUP_DIR=$4

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

echo "Starting backup for $AMQ_NAME in $ENV environment..."

# Fetch the credentials from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value --secret-id "${AMQ_NAME}-secret" --region "$REGION" --query 'SecretString' --output text)
USERNAME=$(echo "$SECRET" | jq -r '.username')
PASSWORD=$(echo "$SECRET" | jq -r '.password')

# Backup configurations and queues
echo "Backing up configurations for $AMQ_NAME..."
aws mq describe-broker --broker-id "$AMQ_NAME" --region "$REGION" > "$BACKUP_DIR/config_backup.json"

echo "Backing up queues for $AMQ_NAME..."
# Use your RabbitMQ-specific backup logic for queues here
# Example: Using an HTTP API to fetch queue details
curl -u "$USERNAME:$PASSWORD" -X GET "http://${AMQ_NAME}.mq.amazonaws.com/api/queues" > "$BACKUP_DIR/queues_backup.json"

echo "Backup completed for $AMQ_NAME. Files saved to $BACKUP_DIR"
