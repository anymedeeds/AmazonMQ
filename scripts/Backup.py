import os
import json
import requests
import boto3
import yaml
from datetime import datetime
from botocore.exceptions import NoCredentialsError, PartialCredentialsError

# Constants
REGION = "us-east-1"
BACKUP_DIR = "./backups"
S3_BUCKET = "your-s3-bucket-name"
S3_BACKUP_PATH = "amq-backups"


def load_yaml(file_path):
    """Load YAML file."""
    with open(file_path, 'r') as file:
        return yaml.safe_load(file)


def assume_role(role_arn, session_name="BackupSession", region=REGION):
    """Assume an IAM role."""
    sts_client = boto3.client('sts', region_name=region)
    try:
        response = sts_client.assume_role(
            RoleArn=role_arn,
            RoleSessionName=session_name
        )
        credentials = response['Credentials']
        return {
            'aws_access_key_id': credentials['AccessKeyId'],
            'aws_secret_access_key': credentials['SecretAccessKey'],
            'aws_session_token': credentials['SessionToken']
        }
    except Exception as e:
        print(f"Error assuming role: {e}")
        return None


def should_run_backup(schedule):
    """Determine if the backup should run based on the schedule."""
    today = datetime.now().strftime("%A").lower()  # e.g., "monday"
    day_of_month = datetime.now().day

    if schedule == "daily":
        return True
    elif schedule == "weekly" and today == "sunday":
        return True
    elif schedule == "monthly" and day_of_month == 1:
        return True
    return False


def fetch_broker_configuration(mq_client, broker_id):
    """Fetch broker configuration."""
    try:
        return mq_client.describe_broker(BrokerId=broker_id)
    except Exception as e:
        print(f"Error fetching broker configuration for {broker_id}: {e}")
        return None


def fetch_rabbitmq_queues(console_url, rabbit_user, rabbit_password):
    """Fetch RabbitMQ queue details using HTTP API."""
    try:
        response = requests.get(f"{console_url}/api/queues", auth=(rabbit_user, rabbit_password))
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error fetching RabbitMQ queues: {e}")
        return None


def upload_to_s3(s3_client, local_dir, s3_path):
    """Upload backup files to S3."""
    for root, _, files in os.walk(local_dir):
        for file in files:
            local_file = os.path.join(root, file)
            relative_path = os.path.relpath(local_file, local_dir)
            s3_file = f"{s3_path}/{relative_path}"
            try:
                s3_client.upload_file(local_file, S3_BUCKET, s3_file)
                print(f"Uploaded {local_file} to s3://{S3_BUCKET}/{s3_file}")
            except (NoCredentialsError, PartialCredentialsError) as e:
                print(f"Credential error: {e}")
            except Exception as e:
                print(f"Error uploading {local_file}: {e}")


def backup_instance(instance, region, backup_dir, s3_client):
    """Backup an individual instance."""
    name = instance['name']
    broker_id = instance['broker_id']
    role_arn = instance.get('role_arn')
    rabbit_user = instance['rabbit_user']
    rabbit_password = instance['rabbit_password']

    # Assume role if role ARN is provided
    if role_arn:
        credentials = assume_role(role_arn, session_name=f"{name}-Backup", region=region)
        if credentials:
            mq_client = boto3.client('mq', region_name=region, **credentials)
        else:
            print(f"Skipping {name} due to role assumption failure.")
            return
    else:
        mq_client = boto3.client('mq', region_name=region)

    # Fetch broker configuration
    print(f"Fetching broker configuration for {name}...")
    broker_config = fetch_broker_configuration(mq_client, broker_id)
    if not broker_config:
        print(f"Skipping {name} due to missing broker configuration.")
        return

    # Save broker configuration to file
    instance_backup_dir = os.path.join(backup_dir, name)
    os.makedirs(instance_backup_dir, exist_ok=True)
    broker_config_file = os.path.join(instance_backup_dir, "broker_config.json")
    with open(broker_config_file, 'w') as file:
        json.dump(broker_config, file, indent=4)

    # Fetch RabbitMQ queues
    console_url = broker_config['BrokerInstances'][0]['ConsoleURL']
    print(f"Fetching RabbitMQ queues for {name}...")
    queues = fetch_rabbitmq_queues(console_url, rabbit_user, rabbit_password)
    if queues:
        queues_file = os.path.join(instance_backup_dir, "queues.json")
        with open(queues_file, 'w') as file:
            json.dump(queues, file, indent=4)

    # Upload backup files to S3
    print(f"Uploading backup for {name} to S3...")
    upload_to_s3(s3_client, instance_backup_dir, f"{S3_BACKUP_PATH}/{name}")


def main(config_file):
    """Main function."""
    config = load_yaml(config_file)
    s3_client = boto3.client('s3', region_name=REGION)

    for instance in config['amq_instances']:
        schedule = instance['schedule'].lower()
        if should_run_backup(schedule):
            print(f"Running backup for {instance['name']}...")
            backup_instance(instance, REGION, BACKUP_DIR, s3_client)
        else:
            print(f"Skipping backup for {instance['name']} due to schedule mismatch.")


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        print("Usage: python amq_backup.py <config_file>")
        sys.exit(1)

    config_file_path = sys.argv[1]
    if not os.path.exists(config_file_path):
        print(f"Configuration file {config_file_path} does not exist.")
        sys.exit(1)

    main(config_file_path)
