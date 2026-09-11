#!/usr/bin/env python3
"""Fail closed on destructive, public, untagged, or out-of-scope Terraform plans."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

AUTHORIZED_ACCOUNT = "269624229733"
REQUIRED_TAGS = {
    "Project": "OSC-IS",
    "Purpose": "USRSE26-Interactive-Demo",
    "Environment": "ephemeral",
    "ManagedBy": "Terraform",
    "Owner": "ofgarzon",
}
FORBIDDEN_TYPES = {
    "aws_db_instance",
    "aws_instance",
    "aws_lb",
    "aws_alb",
    "aws_elb",
}


def after(change: dict[str, Any]) -> dict[str, Any]:
    value = change.get("after")
    return value if isinstance(value, dict) else {}


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan_json", type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    errors: list[str] = []
    creates = 0

    for resource in plan.get("resource_changes", []):
        address = resource.get("address", "unknown")
        resource_type = resource.get("type", "")
        actions = resource.get("change", {}).get("actions", [])
        if actions == ["create"]:
            creates += 1
        require(
            actions in (["create"], ["read"], ["no-op"]),
            f"{address} has forbidden actions: {actions}",
            errors,
        )
        require(resource_type not in FORBIDDEN_TYPES, f"{address} uses forbidden type {resource_type}", errors)

        planned = after(resource.get("change", {}))
        tags = planned.get("tags_all", planned.get("tags", {}))
        if isinstance(tags, dict) and tags:
            for key, value in REQUIRED_TAGS.items():
                require(tags.get(key) == value, f"{address} is missing required tag {key}={value}", errors)

        if resource_type == "aws_eks_cluster":
            vpc = (planned.get("vpc_config") or [{}])[0]
            cidrs = vpc.get("public_access_cidrs", [])
            require(vpc.get("endpoint_private_access") is True, f"{address} lacks private API access", errors)
            require(vpc.get("endpoint_public_access") is True, f"{address} public API state is unexpected", errors)
            require(len(cidrs) == 1 and re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}/32", cidrs[0] or "") is not None, f"{address} must use one /32 API CIDR", errors)
            require(cidrs != ["0.0.0.0/0"], f"{address} exposes the API publicly", errors)

        if resource_type == "aws_ecr_repository":
            require(planned.get("image_tag_mutability") == "IMMUTABLE", f"{address} permits mutable image tags", errors)
            scan = (planned.get("image_scanning_configuration") or [{}])[0]
            require(scan.get("scan_on_push") is True, f"{address} does not scan on push", errors)

        if resource_type == "aws_cloudformation_stack":
            template = json.loads(planned.get("template_body", "{}"))
            broker = template.get("Resources", {}).get("Broker", {}).get("Properties", {})
            require(broker.get("PubliclyAccessible") is False, f"{address} creates a public broker", errors)
            require(broker.get("DeploymentMode") == "CLUSTER_MULTI_AZ", f"{address} must use a three-broker Multi-AZ cluster", errors)
            require(broker.get("EngineType") == "RABBITMQ", f"{address} is not RabbitMQ", errors)
            serialized = json.dumps(template)
            require("{{resolve:secretsmanager:" in serialized, f"{address} does not resolve its password from Secrets Manager", errors)

    outputs = plan.get("planned_values", {}).get("outputs", {})
    account = outputs.get("account_id", {}).get("value")
    require(account == AUTHORIZED_ACCOUNT, f"Plan targets account {account}, not {AUTHORIZED_ACCOUNT}", errors)
    require(creates > 0, "Plan contains no creates", errors)

    if errors:
        print("Terraform plan policy check failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)

    print(f"Terraform plan policy check passed: {creates} creates, zero updates, zero deletes.")


if __name__ == "__main__":
    main()
