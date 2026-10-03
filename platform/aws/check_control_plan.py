#!/usr/bin/env python3
"""Fail closed on unsafe US-RSE interactive-demo control-plane plans."""

from __future__ import annotations

import argparse
from collections import Counter
import fnmatch
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

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
HISTORY_PATH_REGEX = r"^/api/v1/demo/(artifacts|workflows)/[^/]+/history/?$"
REQUIRED_WAF_REDACTED_HEADERS = {
    "authorization",
    "cookie",
    "x-api-key",
    "x-demo-control-key",
    "x-demo-csrf",
}
EKS_SYSTEM_IMAGE_PULL_ACTIONS = {
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
}
EKS_SYSTEM_IMAGE_REPOSITORIES = {
    "arn:aws:ecr:us-west-2:602401143452:repository/amazon/aws-network-policy-agent",
    "arn:aws:ecr:us-west-2:602401143452:repository/amazon-k8s-cni*",
    "arn:aws:ecr:us-west-2:602401143452:repository/eks/*",
}
PREVIOUS_EKS_SYSTEM_IMAGE_REPOSITORIES = EKS_SYSTEM_IMAGE_REPOSITORIES - {
    "arn:aws:ecr:us-west-2:602401143452:repository/amazon/aws-network-policy-agent",
}
EKS_CNI_BOOTSTRAP_ACTIONS = {
    "ec2:AssignIpv6Addresses",
    "ec2:AssignPrivateIpAddresses",
    "ec2:AttachNetworkInterface",
    "ec2:CreateNetworkInterface",
    "ec2:CreateTags",
    "ec2:DeleteNetworkInterface",
    "ec2:DetachNetworkInterface",
    "ec2:ModifyNetworkInterfaceAttribute",
    "ec2:UnassignIpv6Addresses",
    "ec2:UnassignPrivateIpAddresses",
}


def history_path_matches(path: str) -> bool:
    """Mirror the WAF URL_DECODE then LOWERCASE URI-path matching contract."""
    normalized_path = unquote(urlsplit(path).path).lower()
    return re.fullmatch(HISTORY_PATH_REGEX, normalized_path) is not None


def single_block(value: Any, key: str) -> dict[str, Any] | None:
    blocks = value.get(key) if isinstance(value, dict) else None
    if not isinstance(blocks, list) or len(blocks) != 1 or not isinstance(blocks[0], dict):
        return None
    return blocks[0]


def validate_waf_web_acl(after: dict[str, Any], run_id: str, errors: list[str]) -> None:
    rules = after.get("rule")
    if not isinstance(rules, list):
        errors.append("aws_wafv2_web_acl.edge has no rendered rules")
        return

    visibility_targets = [("web ACL", after)] + [
        (f"rule {rule.get('name', 'unknown')}", rule)
        for rule in rules
        if isinstance(rule, dict)
    ]
    for label, target in visibility_targets:
        visibility = single_block(target, "visibility_config")
        if visibility is None:
            errors.append(f"WAF {label} must have one visibility configuration")
            continue
        if visibility.get("cloudwatch_metrics_enabled") is not True:
            errors.append(f"WAF {label} must retain aggregate CloudWatch metrics")
        if visibility.get("sampled_requests_enabled") is not False:
            errors.append(f"WAF {label} must disable sampled requests")
    web_acl_visibility = single_block(after, "visibility_config")
    expected_web_acl_metric = f"osc-usrse26-{run_id}-edge"
    if (
        after.get("name") != expected_web_acl_metric
        or web_acl_visibility is None
        or web_acl_visibility.get("metric_name") != expected_web_acl_metric
    ):
        errors.append("WAF web ACL name and aggregate metric dimension must remain run-scoped")

    matches = [
        rule for rule in rules
        if isinstance(rule, dict) and rule.get("name") == "DemoHistoryRateLimit"
    ]
    if len(matches) != 1:
        errors.append("WAF must contain exactly one DemoHistoryRateLimit rule")
        return
    rule = matches[0]
    if rule.get("priority") != 25:
        errors.append("DemoHistoryRateLimit must retain priority 25")

    action = single_block(rule, "action")
    block = single_block(action, "block") if action is not None else None
    custom_response = single_block(block, "custom_response") if block is not None else None
    if custom_response is None or custom_response.get("response_code") != 429:
        errors.append("DemoHistoryRateLimit must block with HTTP 429")

    statement = single_block(rule, "statement")
    rate = single_block(statement, "rate_based_statement") if statement is not None else None
    if rate is None:
        errors.append("DemoHistoryRateLimit must contain one rate-based statement")
        return
    if rate.get("aggregate_key_type") != "CONSTANT":
        errors.append("DemoHistoryRateLimit must use CONSTANT aggregation")
    if rate.get("evaluation_window_sec") != 60:
        errors.append("DemoHistoryRateLimit must use a 60-second evaluation window")
    if rate.get("limit") != 300:
        errors.append("DemoHistoryRateLimit must retain the 300-request threshold")

    scope = single_block(rate, "scope_down_statement")
    regex_match = single_block(scope, "regex_match_statement") if scope is not None else None
    if regex_match is None:
        errors.append("DemoHistoryRateLimit must contain one normalized regex matcher")
        return
    if regex_match.get("regex_string") != HISTORY_PATH_REGEX:
        errors.append("DemoHistoryRateLimit has an incorrect history-route regex")
    field = single_block(regex_match, "field_to_match")
    uri_path = field.get("uri_path") if field is not None else None
    if not isinstance(uri_path, list) or len(uri_path) != 1:
        errors.append("DemoHistoryRateLimit must match the URI path")
    transformations = regex_match.get("text_transformation")
    if not isinstance(transformations, list):
        transformations = []
    normalized_transformations = sorted(
        (
            {"priority": item.get("priority"), "type": item.get("type")}
            for item in transformations
            if isinstance(item, dict)
        ),
        key=lambda item: item["priority"] if isinstance(item["priority"], int) else -1,
    )
    if normalized_transformations != [
        {"priority": 0, "type": "URL_DECODE"},
        {"priority": 1, "type": "LOWERCASE"},
    ]:
        errors.append("DemoHistoryRateLimit must URL-decode then lowercase the URI path")
    visibility = single_block(rule, "visibility_config")
    if visibility is None or visibility.get("metric_name") != "DemoHistoryRate":
        errors.append("DemoHistoryRateLimit must publish the DemoHistoryRate metric dimension")


def validate_waf_logging(
    after: dict[str, Any],
    configuration: dict[str, Any],
    errors: list[str],
) -> None:
    redacted_headers: set[str] = set()
    for field in after.get("redacted_fields") or []:
        header = single_block(field, "single_header")
        if header is not None and isinstance(header.get("name"), str):
            redacted_headers.add(header["name"].lower())
    if redacted_headers != REQUIRED_WAF_REDACTED_HEADERS:
        errors.append("WAF logging must retain the exact sensitive-header redaction set")

    expressions = configuration.get("expressions", {})
    acl_references = expressions.get("resource_arn", {}).get("references", [])
    if "aws_wafv2_web_acl.edge.arn" not in acl_references:
        errors.append("WAF logging must attach to aws_wafv2_web_acl.edge")
    log_references = expressions.get("log_destination_configs", {}).get("references", [])
    allowed_log_references = {
        "aws_cloudwatch_log_group.waf",
        "aws_cloudwatch_log_group.waf.arn",
    }
    if (
        not isinstance(log_references, list)
        or "aws_cloudwatch_log_group.waf.arn" not in log_references
        or not set(log_references).issubset(allowed_log_references)
    ):
        errors.append("WAF logging must use the restricted WAF CloudWatch log group")


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


def policy_document(policy: str) -> dict[str, Any] | None:
    try:
        document = json.loads(policy)
    except (TypeError, json.JSONDecodeError):
        return None
    return document if isinstance(document, dict) else None


def normalized_statement(statement: dict[str, Any]) -> str:
    normalized = dict(statement)
    for key in ("Action", "Resource"):
        value = normalized.get(key)
        if isinstance(value, list):
            normalized[key] = sorted(value)
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def expected_eks_system_image_pull_statement() -> dict[str, Any]:
    return {
        "Effect": "Allow",
        "Action": sorted(EKS_SYSTEM_IMAGE_PULL_ACTIONS),
        "Resource": sorted(EKS_SYSTEM_IMAGE_REPOSITORIES),
    }


def expected_eks_cni_bootstrap_statement(*, include_create_tags: bool) -> dict[str, Any]:
    actions = EKS_CNI_BOOTSTRAP_ACTIONS
    if not include_create_tags:
        actions = actions - {"ec2:CreateTags"}
    return {
        "Effect": "Allow",
        "Action": sorted(actions),
        "Resource": ["*"],
    }


def validate_eks_system_image_pull_policy(policy: str, errors: list[str]) -> None:
    document = policy_document(policy)
    statements = document.get("Statement", []) if document else []
    if not isinstance(statements, list):
        errors.append("runtime boundary has no inspectable statements")
        return
    expected = normalized_statement(expected_eks_system_image_pull_statement())
    normalized = [
        normalized_statement(statement)
        for statement in statements
        if isinstance(statement, dict)
    ]
    if normalized.count(expected) != 1:
        errors.append("runtime boundary must contain the exact pull-only AWS EKS system-image grant")
    for statement in statements:
        if not isinstance(statement, dict) or statement.get("Effect") != "Allow":
            continue
        resources = statement.get("Resource", [])
        resources = [resources] if isinstance(resources, str) else resources
        if any(":602401143452:repository/" in resource for resource in resources):
            actions = statement.get("Action", [])
            actions = [actions] if isinstance(actions, str) else actions
            if set(actions) != EKS_SYSTEM_IMAGE_PULL_ACTIONS or set(resources) != EKS_SYSTEM_IMAGE_REPOSITORIES:
                errors.append("runtime boundary broadens access to the AWS EKS image registry")


def is_eks_bootstrap_boundary_update(
    address: str,
    resource_type: str,
    change: dict[str, Any],
) -> bool:
    if address != "aws_iam_policy.lifecycle_boundary" or resource_type != "aws_iam_policy":
        return False
    if change.get("actions") != ["update"] or change.get("after_unknown"):
        return False
    before = dict(change.get("before") or {})
    after = dict(change.get("after") or {})
    before_policy = policy_document(before.pop("policy", None))
    after_policy = policy_document(after.pop("policy", None))
    if before != after or before_policy is None or after_policy is None:
        return False
    if before_policy.get("Version") != after_policy.get("Version"):
        return False
    before_statements = before_policy.get("Statement")
    after_statements = after_policy.get("Statement")
    if not isinstance(before_statements, list) or not isinstance(after_statements, list):
        return False
    before_counter = Counter(
        normalized_statement(statement)
        for statement in before_statements
        if isinstance(statement, dict)
    )
    after_counter = Counter(
        normalized_statement(statement)
        for statement in after_statements
        if isinstance(statement, dict)
    )
    expected_pull = normalized_statement(expected_eks_system_image_pull_statement())
    if after_counter == before_counter + Counter({expected_pull: 1}):
        return True

    previous_pull = normalized_statement({
        **expected_eks_system_image_pull_statement(),
        "Resource": sorted(PREVIOUS_EKS_SYSTEM_IMAGE_REPOSITORIES),
    })
    previous_cni = normalized_statement(expected_eks_cni_bootstrap_statement(include_create_tags=False))
    expected_cni = normalized_statement(expected_eks_cni_bootstrap_statement(include_create_tags=True))
    expected_after = before_counter.copy()
    for old_statement, new_statement in (
        (previous_pull, expected_pull),
        (previous_cni, expected_cni),
    ):
        if expected_after[old_statement] != 1:
            return False
        expected_after[old_statement] -= 1
        if expected_after[old_statement] == 0:
            del expected_after[old_statement]
        expected_after[new_statement] += 1
    return after_counter == expected_after


def policy_actions(policy: str) -> set[str]:
    document = policy_document(policy)
    if document is None:
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
    boundary_updates = 0
    import_reconciliations = 0
    one_time_schedule_names: set[str] = set()
    waf_controls_checked = False
    waf_logging_checked = False
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
        elif is_eks_bootstrap_boundary_update(address, resource_type, change):
            boundary_updates += 1
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
        if resource_type == "aws_wafv2_web_acl" and address == "aws_wafv2_web_acl.edge":
            validate_waf_web_acl(after, args.run_id, errors)
            waf_controls_checked = True
        if (
            resource_type == "aws_wafv2_web_acl_logging_configuration"
            and address == "aws_wafv2_web_acl_logging_configuration.edge"
        ):
            validate_waf_logging(after, configuration_resources.get(address, {}), errors)
            waf_logging_checked = True
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
            validate_eks_system_image_pull_policy(after.get("policy", ""), errors)
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
        "aws_wafv2_web_acl_logging_configuration",
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
    if not waf_controls_checked:
        errors.append("control plan is missing the exact reviewed WAF web ACL")
    if not waf_logging_checked:
        errors.append("control plan is missing the exact reviewed WAF logging configuration")
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
    if creates == 0 and import_reconciliations == 0 and boundary_updates == 0:
        errors.append("control plan contains no reviewed changes")

    if errors:
        print("Control-plane policy check failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)
    print(
        f"Control-plane policy check passed: {creates} creates, "
        f"{import_reconciliations} state-only import reconciliation, "
        f"{boundary_updates} exact EKS bootstrap boundary update, zero deletes in account {ACCOUNT}."
    )


if __name__ == "__main__":
    main()
