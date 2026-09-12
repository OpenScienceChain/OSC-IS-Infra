#!/usr/bin/env python3
"""Render and locally simulate the run-scoped IAM permissions boundary."""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
from pathlib import Path
from typing import Any


ACCOUNT = "269624229733"
REGION = "us-west-2"
MAX_MANAGED_POLICY_CHARACTERS = 6_144
FORBIDDEN_BILLING_ACTION_PREFIXES = ("budgets:", "aws-portal:", "ce:", "billing:")


def values(value: Any) -> list[str]:
    return value if isinstance(value, list) else [value]


def matches_any(actual: str, patterns: Any, *, casefold: bool = False) -> bool:
    if casefold:
        actual = actual.lower()
    for pattern in values(patterns):
        candidate = str(pattern).lower() if casefold else str(pattern)
        if fnmatch.fnmatchcase(actual, candidate):
            return True
    return False


def conditions_match(conditions: dict[str, Any], context: dict[str, str]) -> bool:
    for operator, entries in conditions.items():
        if operator not in {"StringEquals", "ArnEquals", "StringLike"}:
            raise RuntimeError(f"Unsupported policy simulator condition: {operator}")
        for key, expected in entries.items():
            actual = context.get(key)
            if actual is None:
                return False
            if operator == "StringLike":
                if not matches_any(actual, expected):
                    return False
            elif actual not in values(expected):
                return False
    return True


def decision(policy: dict[str, Any], action: str, resource: str, context: dict[str, str]) -> str:
    allowed = False
    for statement in policy["Statement"]:
        if not matches_any(action, statement["Action"], casefold=True):
            continue
        if not matches_any(resource, statement["Resource"]):
            continue
        if not conditions_match(statement.get("Condition", {}), context):
            continue
        if statement["Effect"] == "Deny":
            return "explicitDeny"
        allowed = True
    return "allowed" if allowed else "implicitDeny"


def render_policies(terraform_root: Path, run_id: str) -> dict[str, dict[str, Any]]:
    digest = "a" * 64
    arguments = [
        "terraform",
        f"-chdir={terraform_root}",
        "console",
        f"-var=run_id={run_id}",
        "-var=hosted_zone_id=ZLOCALPOLICYSIMULATION",
        "-var=admin_cidr=203.0.113.10/32",
        f"-var=lifecycle_runner_image={ACCOUNT}.dkr.ecr.{REGION}.amazonaws.com/osc-usrse26-{run_id}/lifecycle-runner@sha256:{digest}",
        f"-var=artifact_manifest_s3_uri=s3://local-policy-evidence/releases/{run_id}/manifest.json",
        f"-var=artifact_manifest_sha256={digest}",
    ]
    rendered = subprocess.run(
        arguments,
        input="jsonencode({ boundary = local.lifecycle_boundary_policy, identity = local.lifecycle_role_policy })\n",
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
    return json.loads(json.loads(rendered))


def effective_decision(
    boundary: dict[str, Any],
    identity: dict[str, Any],
    action: str,
    resource: str,
    context: dict[str, str],
) -> str:
    if decision(boundary, action, resource, context) != "allowed":
        return "implicitDeny"
    return decision(identity, action, resource, context)


def compact_policy_characters(policy: dict[str, Any]) -> int:
    return len(json.dumps(policy, separators=(",", ":")))


def simulate(boundary: dict[str, Any], identity: dict[str, Any], run_id: str) -> dict[str, Any]:
    role = f"arn:aws:iam::{ACCOUNT}:role/osc-usrse26-{run_id}-eks-cluster"
    run_bucket = f"arn:aws:s3:::osc-usrse26-{run_id}-control-{ACCOUNT}"
    run_secret = f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:osc-usrse26-{run_id}/api/auth-AbCdEf"
    creation_tags = {
        "aws:RequestTag/Project": "OSC-IS",
        "aws:RequestTag/RunId": run_id,
    }
    cases = [
        ("runtime role creation", "iam:CreateRole", role, {}, "implicitDeny"),
        ("inline policy mutation", "iam:PutRolePolicy", role, {}, "implicitDeny"),
        ("trust policy mutation", "iam:UpdateAssumeRolePolicy", role, {}, "implicitDeny"),
        ("assume altered runtime role", "sts:AssumeRole", role, {}, "implicitDeny"),
        ("approved EKS pass role", "iam:PassRole", role, {"iam:PassedToService": "eks.amazonaws.com"}, "allowed"),
        ("unlisted same-run pass role", "iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/osc-usrse26-{run_id}-unlisted", {"iam:PassedToService": "eks.amazonaws.com"}, "implicitDeny"),
        ("pass role outside run prefix", "iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/admin", {"iam:PassedToService": "eks.amazonaws.com"}, "implicitDeny"),
        ("pass role to unapproved service", "iam:PassRole", role, {"iam:PassedToService": "lambda.amazonaws.com"}, "implicitDeny"),
        ("permissions boundary mutation", "iam:DeleteRolePermissionsBoundary", role, {}, "implicitDeny"),
        ("run-scoped S3 object", "s3:GetObject", f"{run_bucket}/runtime-state/{run_id}/terraform.tfstate", {}, "allowed"),
        ("unrelated S3 object", "s3:GetObject", "arn:aws:s3:::unrelated-account-data/private.txt", {}, "implicitDeny"),
        ("run-scoped secret", "secretsmanager:GetSecretValue", run_secret, {}, "allowed"),
        ("unrelated Secrets Manager secret", "secretsmanager:GetSecretValue", f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:production/database-AbCdEf", {}, "implicitDeny"),
        ("named run secret creation", "secretsmanager:CreateSecret", "*", {**creation_tags, "secretsmanager:Name": f"osc-usrse26-{run_id}/api/auth"}, "allowed"),
        ("unrelated secret creation", "secretsmanager:CreateSecret", "*", {**creation_tags, "secretsmanager:Name": "production/database"}, "implicitDeny"),
        ("broad inline policy intersected for run data", "s3:GetObject", f"{run_bucket}/evidence/{run_id}/summary.json", {}, "allowed"),
        ("broad inline policy intersected for unrelated data", "s3:GetObject", "arn:aws:s3:::production-data/records.json", {}, "implicitDeny"),
    ]
    results = []
    for name, action, resource, context, expected in cases:
        actual = effective_decision(boundary, identity, action, resource, context)
        results.append({"name": name, "action": action, "resource": resource, "expected": expected, "actual": actual, "passed": actual == expected})
    policy_characters = compact_policy_characters(boundary)
    policy_actions = {
        action
        for policy in (boundary, identity)
        for statement in policy["Statement"]
        for action in values(statement["Action"])
    }
    forbidden_billing_actions = sorted(
        action for action in policy_actions
        if str(action).lower().startswith(FORBIDDEN_BILLING_ACTION_PREFIXES)
    )
    return {
        "schemaVersion": 1,
        "simulation": "local identity-policy and permissions-boundary intersection model",
        "account": ACCOUNT,
        "region": REGION,
        "runId": run_id,
        "boundaryArn": f"arn:aws:iam::{ACCOUNT}:policy/osc-usrse26-{run_id}-runtime-boundary",
        "boundaryPolicyCharacters": policy_characters,
        "managedPolicyQuotaCharacters": MAX_MANAGED_POLICY_CHARACTERS,
        "forbiddenBillingActions": forbidden_billing_actions,
        "allPassed": (
            policy_characters <= MAX_MANAGED_POLICY_CHARACTERS
            and not forbidden_billing_actions
            and all(item["passed"] for item in results)
        ),
        "cases": results,
        "limitations": "Local identity-policy and permissions-boundary semantics only; repeat with AWS IAM simulation during an authorized rehearsal.",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-root", type=Path, required=True)
    parser.add_argument("--run-id", default="usrse26r1")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    policies = render_policies(args.terraform_root.resolve(), args.run_id)
    report = simulate(policies["boundary"], policies["identity"], args.run_id)
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    if not report["allPassed"]:
        raise SystemExit("IAM permissions-boundary simulation failed")


if __name__ == "__main__":
    main()
