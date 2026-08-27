import json
import logging
import os

import boto3
from botocore.config import Config


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

CONFIG = Config(
    retries={"total_max_attempts": 4, "mode": "adaptive"},
    connect_timeout=3,
    read_timeout=10,
)
PROJECT_TAG_VALUE = os.environ["PROJECT_TAG_VALUE"]
AUTOSTOP_TAG_VALUE = os.environ["AUTOSTOP_TAG_VALUE"]
TARGET_REGIONS = tuple(
    region.strip() for region in os.environ["TARGET_REGIONS"].split(",") if region.strip()
)
EC2_CLIENTS = {
    region: boto3.client("ec2", region_name=region, config=CONFIG)
    for region in TARGET_REGIONS
}


def stoppable_instance_ids(ec2_client) -> list[str]:
    paginator = ec2_client.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[
            {"Name": "tag:Project", "Values": [PROJECT_TAG_VALUE]},
            {"Name": "tag:AutoStop", "Values": [AUTOSTOP_TAG_VALUE]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running"],
            },
        ]
    )

    instance_ids = []
    for page in pages:
        for reservation in page.get("Reservations", []):
            instance_ids.extend(
                instance["InstanceId"] for instance in reservation.get("Instances", [])
            )
    return instance_ids


def handler(event, context):
    stopped_by_region = {}

    for region, ec2_client in EC2_CLIENTS.items():
        instance_ids = stoppable_instance_ids(ec2_client)
        if instance_ids:
            ec2_client.stop_instances(InstanceIds=instance_ids)
        stopped_by_region[region] = instance_ids

    result = {
        "request_id": context.aws_request_id,
        "stopped_by_region": stopped_by_region,
        "trigger_records": len(event.get("Records", [])),
    }
    LOGGER.info("%s", json.dumps(result, sort_keys=True))
    return result
