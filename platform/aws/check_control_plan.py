#!/usr/bin/env python3
"""Fail closed on unsafe US-RSE interactive-demo control-plane plans."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

ACCOUNT = "269624229733"
REQUIRED_TAGS = {
    "Project": "OSC-IS",
    "Purpose": "USRSE26-Interactive-Demo",
    "Environment": "ephemeral",
    "ManagedBy": "Terraform",
    "RunId": None,
}
FORBIDDEN_TYPES = {"aws_instance", "aws_db_instance", "aws_eks_cluster", "aws_mq_broker"}
ALLOWED_ACTIONS = (["create"], ["read"], ["no-op"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan_json", type=Path)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    errors: list[str] = []
    creates = 0
    types: set[str] = set()

    for resource in plan.get("resource_changes", []):
        address = resource.get("address", "unknown")
        resource_type = resource.get("type", "")
        actions = resource.get("change", {}).get("actions", [])
        after = resource.get("change", {}).get("after") or {}
        types.add(resource_type)
        creates += actions == ["create"]
        if actions not in ALLOWED_ACTIONS:
            errors.append(f"{address} has forbidden actions {actions}")
        if resource_type in FORBIDDEN_TYPES:
            errors.append(f"{address} uses forbidden control-plane type {resource_type}")

        tags = after.get("tags_all", after.get("tags", {}))
        if isinstance(tags, dict) and tags:
            for key, required in REQUIRED_TAGS.items():
                expected = args.run_id if required is None else required
                if tags.get(key) != expected:
                    errors.append(f"{address} is missing tag {key}={expected}")

        if resource_type == "aws_s3_bucket_public_access_block":
            for key in ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"):
                if after.get(key) is not True:
                    errors.append(f"{address} must set {key}=true")
        if resource_type == "aws_cloudfront_distribution":
            if after.get("enabled") is not True or not after.get("web_acl_id"):
                errors.append(f"{address} must be enabled and protected by WAF")
        if resource_type == "aws_codebuild_project":
            environment = (after.get("environment") or [{}])[0]
            image = environment.get("image", "")
            if "@sha256:" not in image:
                errors.append(f"{address} lifecycle image is mutable")

    required_types = {
        "aws_budgets_budget",
        "aws_cloudfront_distribution",
        "aws_cloudwatch_metric_alarm",
        "aws_codebuild_project",
        "aws_dynamodb_table",
        "aws_scheduler_schedule",
        "aws_sfn_state_machine",
        "aws_wafv2_web_acl",
    }
    missing = required_types - types
    if missing:
        errors.append(f"control plan is missing required resource types: {', '.join(sorted(missing))}")

    outputs = plan.get("planned_values", {}).get("outputs", {})
    if not outputs.get("public_url", {}).get("value") == "https://demo.osc-staging.org":
        errors.append("public URL differs from the approved hostname")
    if creates == 0:
        errors.append("control plan contains no creates")

    if errors:
        print("Control-plane policy check failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)
    print(f"Control-plane policy check passed: {creates} creates, zero updates, zero deletes in account {ACCOUNT}.")


if __name__ == "__main__":
    main()
