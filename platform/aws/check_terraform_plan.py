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
RUNTIME_ECR_REPOSITORIES = {
    "api-gateway",
    "chaincode",
    "gitops-repository",
    "history-worker",
    "ledger-gateway",
    "submission-listener",
    "submission-worker",
    "webapp",
}


def after(change: dict[str, Any]) -> dict[str, Any]:
    value = change.get("after")
    return value if isinstance(value, dict) else {}


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def check_ecr_import_reconciliation(
    resource: dict[str, Any], plan: dict[str, Any], errors: list[str]
) -> None:
    """Allow only the exact state-adoption update for staged runtime images."""
    address = resource.get("address", "unknown")
    change = resource.get("change", {})
    before = change.get("before") or {}
    planned = after(change)
    run_id = plan.get("variables", {}).get("run_id", {}).get("value")
    expires_at = plan.get("variables", {}).get("expires_at", {}).get("value")
    expected_tags = {
        **REQUIRED_TAGS,
        "RunId": run_id,
        "ExpiresAt": expires_at,
    }
    match = re.fullmatch(r'aws_ecr_repository\.experiment\["([a-z-]+)"\]', address)
    repository = match.group(1) if match else None
    expected_name = f"osc-usrse26-{run_id}/{repository}" if repository else None
    changed_fields = {
        key
        for key in set(before) | set(planned)
        if before.get(key) != planned.get(key)
    }

    require(repository in RUNTIME_ECR_REPOSITORIES, f"{address} is not an approved runtime repository", errors)
    require(planned.get("name") == expected_name, f"{address} has an unexpected repository name", errors)
    require(
        changed_fields == {"force_delete", "tags", "tags_all"},
        f"{address} changes fields outside the approved import reconciliation: {sorted(changed_fields)}",
        errors,
    )
    require(before.get("force_delete") is None, f"{address} was not imported from an unmanaged repository", errors)
    require(planned.get("force_delete") is True, f"{address} is not runtime-destroyable", errors)
    require(planned.get("tags") == {}, f"{address} has unexpected explicit tags", errors)
    require(planned.get("tags_all") == expected_tags, f"{address} tags do not match the reviewed run", errors)
    require(change.get("after_unknown", {}) == {}, f"{address} has unknown post-apply values", errors)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan_json", type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    errors: list[str] = []
    creates = 0
    ecr_import_reconciliations = 0
    configuration_resources = {
        resource.get("address"): resource
        for resource in plan.get("configuration", {}).get("root_module", {}).get("resources", [])
    }

    for resource in plan.get("resource_changes", []):
        address = resource.get("address", "unknown")
        resource_type = resource.get("type", "")
        actions = resource.get("change", {}).get("actions", [])
        if actions == ["create"]:
            creates += 1
        is_ecr_import_reconciliation = resource_type == "aws_ecr_repository" and actions == ["update"]
        if is_ecr_import_reconciliation:
            ecr_import_reconciliations += 1
            check_ecr_import_reconciliation(resource, plan, errors)
        require(
            actions in (["create"], ["read"], ["no-op"]) or is_ecr_import_reconciliation,
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
            require(
                1 <= len(cidrs) <= 2 and len(set(cidrs)) == len(cidrs) and all(
                    re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}/32", cidr or "") is not None
                    for cidr in cidrs
                ),
                f"{address} must use no more than two distinct administrator/runner /32 API CIDRs",
                errors,
            )
            require(cidrs != ["0.0.0.0/0"], f"{address} exposes the API publicly", errors)

        if resource_type == "aws_ecr_repository":
            require(planned.get("image_tag_mutability") == "IMMUTABLE", f"{address} permits mutable image tags", errors)
            scan = (planned.get("image_scanning_configuration") or [{}])[0]
            require(scan.get("scan_on_push") is True, f"{address} does not scan on push", errors)

        if resource_type == "aws_eks_node_group":
            scaling = (planned.get("scaling_config") or [{}])[0]
            require(
                scaling.get("desired_size") == 3
                and scaling.get("min_size") == 3
                and scaling.get("max_size") == 3,
                f"{address} must remain fixed at exactly three nodes",
                errors,
            )
            require(
                planned.get("instance_types") == ["m7i.large"],
                f"{address} must use only m7i.large",
                errors,
            )

        if resource_type == "aws_cloudformation_stack":
            template = json.loads(planned.get("template_body", "{}"))
            broker = template.get("Resources", {}).get("Broker", {}).get("Properties", {})
            parameter_references = (
                configuration_resources.get(address, {})
                .get("expressions", {})
                .get("parameters", {})
                .get("references", [])
            )
            broker_size = (
                plan.get("variables", {})
                .get("rabbitmq_instance_type", {})
                .get("value")
            )
            require(broker.get("PubliclyAccessible") is False, f"{address} creates a public broker", errors)
            require(broker.get("DeploymentMode") == "CLUSTER_MULTI_AZ", f"{address} must use a three-broker Multi-AZ cluster", errors)
            require(broker.get("EngineType") == "RABBITMQ", f"{address} is not RabbitMQ", errors)
            require(
                broker.get("HostInstanceType") == {"Ref": "HostInstanceType"}
                and "var.rabbitmq_instance_type" in parameter_references
                and broker_size == "mq.m7g.medium",
                f"{address} broker size is outside the reviewed bound",
                errors,
            )
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

    print(
        "Terraform plan policy check passed: "
        f"{creates} creates, {ecr_import_reconciliations} exact ECR import reconciliations, zero deletes."
    )


if __name__ == "__main__":
    main()
