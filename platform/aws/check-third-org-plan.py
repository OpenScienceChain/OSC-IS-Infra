#!/usr/bin/env python3
"""Reject any Terraform change beyond the reviewed third-org secret boundary."""

from __future__ import annotations

import json
import sys
from pathlib import Path

EXPECTED = {
    'aws_eks_pod_identity_association.workload_secrets["ledger-gateway-magnetic-arch"]': ["create"],
    'aws_iam_role.workload_secrets["ledger-gateway-magnetic-arch"]': ["create"],
    'aws_iam_role_policy.workload_secrets["ledger-gateway-magnetic-arch"]': ["create"],
    'aws_iam_role_policy.workload_secrets["submission-worker"]': ["update"],
    "aws_secretsmanager_secret.fabric_magnetic_arch": ["create"],
    "aws_secretsmanager_secret.ledger_magnetic_arch_token": ["create"],
}
PREFIX = "osc-usrse26-usrse260930"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-third-org-plan.py PLAN_JSON")
    plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    variables = plan["variables"]
    for key, expected in (
        ("authorized_account_id", "269624229733"),
        ("aws_region", "us-west-2"),
        ("run_id", "usrse260930"),
    ):
        if variables[key]["value"] != expected:
            raise SystemExit(f"Unexpected {key}")
    changes = {
        item["address"]: item["change"]
        for item in plan["resource_changes"]
        if item["change"]["actions"] != ["no-op"]
    }
    if {key: value["actions"] for key, value in changes.items()} != EXPECTED:
        raise SystemExit("Plan contains missing or out-of-scope resource changes")

    for suffix, name in (
        ("fabric_magnetic_arch", f"{PREFIX}/fabric/magnetic-arch"),
        ("ledger_magnetic_arch_token", f"{PREFIX}/ledger-token/magnetic-arch"),
    ):
        after = changes[f"aws_secretsmanager_secret.{suffix}"]["after"]
        if after["name"] != name or after["recovery_window_in_days"] != 0:
            raise SystemExit(f"Unexpected secret settings: {suffix}")

    association = changes[EXPECTED_KEY_ASSOCIATION]["after"]
    if (association["cluster_name"] != f"{PREFIX}-eks"
            or association["namespace"] != "osc-apps"
            or association["service_account"] != "ledger-gateway-magnetic-arch"):
        raise SystemExit("Unexpected Pod Identity association")

    role = changes[EXPECTED_KEY_ROLE]["after"]
    if role["name"] != f"{PREFIX}-ledger-gateway-magnetic-arch" or not role["permissions_boundary"]:
        raise SystemExit("Unexpected gateway role or missing permissions boundary")

    worker = changes['aws_iam_role_policy.workload_secrets["submission-worker"]']
    prior = json.loads(worker["before"]["policy"])
    statement = prior["Statement"]
    if len(statement) != 1 or set(statement[0]["Action"]) != {
        "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"
    } or statement[0]["Effect"] != "Allow":
        raise SystemExit("Unexpected existing worker policy")
    if worker["after"]["name"] != "read-exact-osc-secrets":
        raise SystemExit("Unexpected worker policy name")

    print("Reviewed third-org plan: five creates, one exact-secret policy update, no other resource changes.")


EXPECTED_KEY_ASSOCIATION = 'aws_eks_pod_identity_association.workload_secrets["ledger-gateway-magnetic-arch"]'
EXPECTED_KEY_ROLE = 'aws_iam_role.workload_secrets["ledger-gateway-magnetic-arch"]'

if __name__ == "__main__":
    main()
