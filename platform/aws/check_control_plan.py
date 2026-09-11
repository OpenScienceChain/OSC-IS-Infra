#!/usr/bin/env python3
"""Fail closed on unsafe US-RSE interactive-demo control-plane plans."""

from __future__ import annotations

import argparse
import fnmatch
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
RUNTIME_ROLE_SUFFIXES = {
    "eks-cluster",
    "eks-nodes",
    "alb-controller",
    "api-gateway",
    "postgres",
    "submission-worker",
    "submission-listener",
    "ledger-gateway-nsg",
    "ledger-gateway-citizen-science",
    "ebs-csi",
}
FORBIDDEN_LIFECYCLE_ACTIONS = {
    "iam:AttachRolePolicy",
    "iam:CreatePolicy",
    "iam:CreatePolicyVersion",
    "iam:CreateRole",
    "iam:DeleteRolePermissionsBoundary",
    "iam:PutRolePermissionsBoundary",
    "iam:PutRolePolicy",
    "iam:SetDefaultPolicyVersion",
    "iam:UpdateAssumeRolePolicy",
    "sts:AssumeRole",
}


def policy_actions(policy: str) -> set[str]:
    try:
        document = json.loads(policy)
    except (TypeError, json.JSONDecodeError):
        return set()
    result: set[str] = set()
    for statement in document.get("Statement", []):
        actions = statement.get("Action", [])
        result.update([actions] if isinstance(actions, str) else actions)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan_json", type=Path)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    errors: list[str] = []
    creates = 0
    types: set[str] = set()
    bounded_roles: set[str] = set()
    codebuild_projects: set[str] = set()
    boundary_checked = False

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
            name = after.get("name", "")
            codebuild_projects.add(name)
            environment = (after.get("environment") or [{}])[0]
            image = environment.get("image", "")
            if "@sha256:" not in image:
                errors.append(f"{address} lifecycle image is mutable")
            if name.endswith("-cleanup") and after.get("vpc_config"):
                errors.append(f"{address} cleanup project must remain outside every VPC")

        if resource_type == "aws_iam_role":
            name = after.get("name", "")
            expected_roles = {
                f"osc-usrse26-{args.run_id}-{suffix}" for suffix in RUNTIME_ROLE_SUFFIXES
            } | {f"osc-usrse26-{args.run_id}-lifecycle"}
            if name in expected_roles:
                expected_boundary = (
                    f"arn:aws:iam::{ACCOUNT}:policy/"
                    f"osc-usrse26-{args.run_id}-runtime-boundary"
                )
                if after.get("permissions_boundary") != expected_boundary:
                    errors.append(f"{address} does not use the exact run boundary")
                bounded_roles.add(name)

        if resource_type == "aws_iam_policy" and after.get("name") == f"osc-usrse26-{args.run_id}-runtime-boundary":
            boundary_checked = True
            actions = policy_actions(after.get("policy", ""))
            forbidden = sorted({
                candidate
                for candidate in FORBIDDEN_LIFECYCLE_ACTIONS
                if any(fnmatch.fnmatchcase(candidate.lower(), action.lower()) for action in actions)
            })
            if forbidden:
                errors.append(f"{address} restores forbidden IAM actions: {', '.join(forbidden)}")

    required_types = {
        "aws_budgets_budget",
        "aws_cloudfront_distribution",
        "aws_cloudwatch_metric_alarm",
        "aws_codebuild_project",
        "aws_dynamodb_table",
        "aws_iam_policy",
        "aws_iam_role",
        "aws_scheduler_schedule",
        "aws_sfn_state_machine",
        "aws_wafv2_web_acl",
    }
    missing = required_types - types
    if missing:
        errors.append(f"control plan is missing required resource types: {', '.join(sorted(missing))}")

    expected_roles = {
        f"osc-usrse26-{args.run_id}-{suffix}" for suffix in RUNTIME_ROLE_SUFFIXES
    } | {f"osc-usrse26-{args.run_id}-lifecycle"}
    missing_roles = expected_roles - bounded_roles
    if missing_roles:
        errors.append(f"control plan is missing bounded fixed roles: {', '.join(sorted(missing_roles))}")
    expected_projects = {
        f"osc-usrse26-{args.run_id}-lifecycle",
        f"osc-usrse26-{args.run_id}-cleanup",
    }
    missing_projects = expected_projects - codebuild_projects
    if missing_projects:
        errors.append(f"control plan is missing lifecycle projects: {', '.join(sorted(missing_projects))}")
    if not boundary_checked:
        errors.append("control plan is missing the inspectable run permissions boundary")

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
