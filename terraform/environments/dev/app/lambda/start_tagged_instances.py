import json
import os

import boto3


ec2 = boto3.client("ec2")


def _filters_from_env():
    filters = []
    for key, value in sorted(os.environ.items()):
        if key.startswith("TAG_") and value:
            tag_key = key[4:].replace("__", ":")
            filters.append({"Name": f"tag:{tag_key}", "Values": [value]})
    return filters


def lambda_handler(event, context):
    filters = _filters_from_env()
    filters.append({"Name": "instance-state-name", "Values": ["stopped", "stopping"]})

    paginator = ec2.get_paginator("describe_instances")
    instance_ids = []

    for page in paginator.paginate(Filters=filters):
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                instance_ids.append(instance["InstanceId"])

    started_instances = []
    if instance_ids:
        ec2.start_instances(InstanceIds=instance_ids)
        started_instances = instance_ids

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "matched_instance_ids": instance_ids,
                "started_instance_ids": started_instances,
            }
        ),
    }
