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
FORBIDDEN_BILLING_RESOURCE_TYPES = {"aws_budgets_budget"}
FORBIDDEN_BILLING_ACTION_PREFIXES = ("budgets:", "aws-portal:", "ce:", "billing:")
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


def is_lifecycle_import_reconciliation(
    address: str,
    resource_type: str,
    change: dict[str, Any],
    run_id: str,
) -> bool:
    """Allow only Terraform's state-only force_delete reconciliation after import."""
    if address != "aws_ecr_repository.lifecycle_runner" or resource_type != "aws_ecr_repository":
        return False
    if change.get("actions") != ["update"] or change.get("after_unknown"):
        return False
    before = dict(change.get("before") or {})
    after = dict(change.get("after") or {})
    if before.get("force_delete") not in (None, False) or after.get("force_delete") is not True:
        return False
    before["force_delete"] = True
    if before != after:
        return False
    return (
        after.get("name") == f"osc-usrse26-{run_id}/lifecycle-runner"
        and after.get("image_tag_mutability") == "IMMUTABLE"
        and (after.get("image_scanning_configuration") or [{}])[0].get("scan_on_push") is True
    )


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
    import_reconciliations = 0
    one_time_schedule_names: set[str] = set()
    configuration_resources = {
        resource.get("address"): resource
        for resource in plan.get("configuration", {}).get("root_module", {}).get("resources", [])
    }

    for resource in plan.get("resource_changes", []):
        address = resource.get("address", "unknown")
        resource_type = resource.get("type", "")
        change = resource.get("change", {})
        actions = change.get("actions", [])
        after = change.get("after") or {}
        after_unknown = change.get("after_unknown") or {}
        types.add(resource_type)
        creates += actions == ["create"]
        if is_lifecycle_import_reconciliation(address, resource_type, change, args.run_id):
            import_reconciliations += 1
        elif actions not in ALLOWED_ACTIONS:
            errors.append(f"{address} has forbidden actions {actions}")
        if resource_type in FORBIDDEN_TYPES:
            errors.append(f"{address} uses forbidden control-plane type {resource_type}")
        if resource_type in FORBIDDEN_BILLING_RESOURCE_TYPES:
            errors.append(f"{address} uses forbidden billing resource type {resource_type}")

        if resource_type in {"aws_iam_policy", "aws_iam_role_policy"}:
            rendered_actions = policy_actions(after.get("policy", ""))
            forbidden_billing = sorted(
                action for action in rendered_actions
                if action.lower().startswith(FORBIDDEN_BILLING_ACTION_PREFIXES)
            )
            if forbidden_billing:
                errors.append(
                    f"{address} contains forbidden billing actions: {', '.join(forbidden_billing)}"
                )

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
            waf_references = (
                configuration_resources.get(address, {})
                .get("expressions", {})
                .get("web_acl_id", {})
                .get("references", [])
            )
            computed_waf = (
                after_unknown.get("web_acl_id") is True
                and "aws_wafv2_web_acl.edge.arn" in waf_references
            )
            if after.get("enabled") is not True or not (after.get("web_acl_id") or computed_waf):
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
            environment_variables = {
                item.get("name"): item.get("value")
                for item in environment.get("environment_variable", [])
            }
            if name in {
                f"osc-usrse26-{args.run_id}-lifecycle",
                f"osc-usrse26-{args.run_id}-cleanup",
            }:
                if environment_variables.get("COST_CONTROL_MODE") != "TIME_BOUNDED":
                    errors.append(f"{address} must use TIME_BOUNDED mode")
                if environment_variables.get("PLANNING_ESTIMATE_CEILING_USD") != "200":
                    errors.append(f"{address} must use the USD 200 planning-estimate ceiling")
                try:
                    runner_estimate = float(environment_variables["PLANNING_ESTIMATE_USD"])
                except (KeyError, TypeError, ValueError):
                    runner_estimate = float("inf")
                if not 0 <= runner_estimate <= 200:
                    errors.append(f"{address} has an invalid planning estimate")
                stale_names = {
                    "BUDGET_NAME", "COST_INFO_USD", "COST_WARNING_USD",
                    "COST_TEARDOWN_USD", "COST_CEILING_USD", "PLANNING_COST_USD",
                }
                present_stale_names = sorted(stale_names & set(environment_variables))
                if present_stale_names:
                    errors.append(f"{address} retains stale live-cost variables: {', '.join(present_stale_names)}")

        if resource_type == "aws_scheduler_schedule":
            name = after.get("name", "")
            expected_one_time_names = {
                f"osc-usrse26-{args.run_id}-start",
                f"osc-usrse26-{args.run_id}-stop",
                f"osc-usrse26-{args.run_id}-backup-stop",
            }
            if name in expected_one_time_names:
                one_time_schedule_names.add(name)
                window = (after.get("flexible_time_window") or [{}])[0]
                target = (after.get("target") or [{}])[0]
                retry = (target.get("retry_policy") or [{}])[0]
                if after.get("action_after_completion") != "DELETE":
                    errors.append(f"{address} must delete itself after completion")
                if window.get("mode") != "OFF":
                    errors.append(f"{address} must disable flexible scheduling")
                if not target.get("dead_letter_config"):
                    errors.append(f"{address} must have a dead-letter queue")
                if retry.get("maximum_retry_attempts") != 2:
                    errors.append(f"{address} must retain two scheduler retries")

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
    expected_one_time_schedule_names = {
        f"osc-usrse26-{args.run_id}-start",
        f"osc-usrse26-{args.run_id}-stop",
        f"osc-usrse26-{args.run_id}-backup-stop",
    }
    if one_time_schedule_names != expected_one_time_schedule_names:
        errors.append("control plan is missing an exact one-time start, stop, or backup-stop schedule")

    outputs = plan.get("planned_values", {}).get("outputs", {})
    if not outputs.get("public_url", {}).get("value") == "https://demo.osc-staging.org":
        errors.append("public URL differs from the approved hostname")
    if outputs.get("cost_control_mode", {}).get("value") != "TIME_BOUNDED":
        errors.append("cost-control mode must be TIME_BOUNDED")
    planning_estimate = outputs.get("planning_estimate_usd", {}).get("value")
    planning_ceiling = outputs.get("planning_estimate_ceiling_usd", {}).get("value")
    if (
        not isinstance(planning_estimate, (int, float))
        or isinstance(planning_estimate, bool)
        or not isinstance(planning_ceiling, (int, float))
        or isinstance(planning_ceiling, bool)
        or planning_ceiling != 200
        or planning_estimate < 0
        or planning_estimate > planning_ceiling
    ):
        errors.append("pre-deployment planning estimate must be concrete and no greater than USD 200")
    if outputs.get("maximum_runtime_hours", {}).get("value") != 72:
        errors.append("maximum runtime must remain exactly 72 hours")
    expected_schedule = {
        "timezone": "America/Los_Angeles",
        "start": "2026-10-20T08:00:00",
        "stop": "2026-10-23T08:00:00",
        "backup_stop": "2026-10-23T10:00:00",
        "hard_close": "2026-10-23T15:00:00Z",
    }
    if outputs.get("lifecycle_schedule", {}).get("value") != expected_schedule:
        errors.append("lifecycle schedule or hard-close deadline differs from the approved 72-hour window")
    if creates == 0:
        errors.append("control plan contains no creates")

    if errors:
        print("Control-plane policy check failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)
    print(
        f"Control-plane policy check passed: {creates} creates, "
        f"{import_reconciliations} state-only import reconciliation, zero deletes in account {ACCOUNT}."
    )


if __name__ == "__main__":
    main()
