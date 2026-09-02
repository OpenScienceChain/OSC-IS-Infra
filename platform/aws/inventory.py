#!/usr/bin/env python3
"""Capture a deterministic inventory of AWS resources relevant to OSC-IS."""

from __future__ import annotations

import argparse
import json
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable

from aws_common import AUTHORIZED_ACCOUNT, AUTHORIZED_REGION, assert_authorized_identity, aws_json


def sorted_unique(values: list[str]) -> list[str]:
    return sorted({value for value in values if value})


def flatten_instances(payload: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        instance
        for reservation in payload.get("Reservations", [])
        for instance in reservation.get("Instances", [])
    ]


def active_stacks(payload: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        stack
        for stack in payload.get("StackSummaries", [])
        if stack.get("StackStatus") != "DELETE_COMPLETE"
    ]


EC2_TAG_INDEX_TYPES = {
    "instance": "ec2_instances",
    "volume": "ebs_volumes",
    "snapshot": "ebs_snapshots_owned",
    "natgateway": "nat_gateways",
    "elastic-ip": "elastic_ips",
}


def tag_index_entry_is_active(arn: str, resources: dict[str, list[str]]) -> bool:
    """Ignore Resource Groups entries that EC2 already reports as deleted."""
    match = re.fullmatch(
        rf"arn:aws:ec2:{re.escape(AUTHORIZED_REGION)}:{AUTHORIZED_ACCOUNT}:([^/]+)/(.+)",
        arn,
    )
    if not match:
        return True
    resource_type, resource_id = match.groups()
    authoritative_inventory = EC2_TAG_INDEX_TYPES.get(resource_type)
    if authoritative_inventory is None:
        return True
    return resource_id in resources[authoritative_inventory]


def collect() -> dict[str, Any]:
    assert_authorized_identity()

    queries: list[tuple[str, tuple[str, ...], Callable[[dict[str, Any]], list[str]]]] = [
        ("eks_clusters", ("eks", "list-clusters"), lambda p: p.get("clusters", [])),
        ("mq_brokers", ("mq", "list-brokers"), lambda p: [x.get("BrokerId", "") for x in p.get("BrokerSummaries", [])]),
        ("rds_instances", ("rds", "describe-db-instances"), lambda p: [x.get("DBInstanceIdentifier", "") for x in p.get("DBInstances", [])]),
        ("nat_gateways", ("ec2", "describe-nat-gateways"), lambda p: [x.get("NatGatewayId", "") for x in p.get("NatGateways", []) if x.get("State") != "deleted"]),
        ("elastic_ips", ("ec2", "describe-addresses"), lambda p: [x.get("AllocationId", "") for x in p.get("Addresses", [])]),
        ("ebs_volumes", ("ec2", "describe-volumes"), lambda p: [x.get("VolumeId", "") for x in p.get("Volumes", [])]),
        ("ebs_snapshots_owned", ("ec2", "describe-snapshots", "--owner-ids", "self"), lambda p: [x.get("SnapshotId", "") for x in p.get("Snapshots", [])]),
        ("ec2_instances", ("ec2", "describe-instances"), lambda p: [x.get("InstanceId", "") for x in flatten_instances(p) if x.get("State", {}).get("Name") != "terminated"]),
        ("load_balancers_v2", ("elbv2", "describe-load-balancers"), lambda p: [x.get("LoadBalancerArn", "") for x in p.get("LoadBalancers", [])]),
        ("load_balancers_classic", ("elb", "describe-load-balancers"), lambda p: [x.get("LoadBalancerName", "") for x in p.get("LoadBalancerDescriptions", [])]),
        ("ecr_repositories", ("ecr", "describe-repositories"), lambda p: [x.get("repositoryName", "") for x in p.get("repositories", [])]),
        ("secrets", ("secretsmanager", "list-secrets", "--include-planned-deletion"), lambda p: [x.get("Name", "") for x in p.get("SecretList", [])]),
        ("log_groups", ("logs", "describe-log-groups"), lambda p: [x.get("logGroupName", "") for x in p.get("logGroups", [])]),
        ("cloudformation_stacks", ("cloudformation", "list-stacks"), lambda p: [x.get("StackName", "") for x in active_stacks(p)]),
    ]

    resources: dict[str, list[str]] = {}
    for name, command, selector in queries:
        resources[name] = sorted_unique(selector(aws_json(*command)))

    tagged = aws_json(
        "resourcegroupstaggingapi",
        "get-resources",
        "--tag-filters",
        "Key=Project,Values=OSC-IS",
    )
    tagged_arns = [item.get("ResourceARN", "") for item in tagged.get("ResourceTagMappingList", [])]
    resources["osc_is_tagged_arns"] = sorted_unique(
        [arn for arn in tagged_arns if tag_index_entry_is_active(arn, resources)]
    )

    return {
        "schemaVersion": 1,
        "capturedAt": datetime.now(UTC).isoformat(),
        "account": AUTHORIZED_ACCOUNT,
        "region": AUTHORIZED_REGION,
        "resources": resources,
        "counts": {name: len(values) for name, values in resources.items()},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    inventory = collect()
    rendered = json.dumps(inventory, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
        print(f"Wrote AWS inventory to {args.output}")
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
