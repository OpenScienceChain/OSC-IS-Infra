#!/usr/bin/env python3
"""Write the reviewed US-RSE control-plane variables as deterministic HCL."""

from __future__ import annotations

import argparse
import json
from decimal import Decimal, InvalidOperation
from pathlib import Path


def bounded_planning_estimate(value: str) -> Decimal:
    try:
        cost = Decimal(value)
    except InvalidOperation as error:
        raise argparse.ArgumentTypeError("planning estimate must be a decimal") from error
    if not Decimal("0") <= cost <= Decimal("200"):
        raise argparse.ArgumentTypeError("planning estimate must be between 0 and 200")
    return cost


def decimal_hcl(value: Decimal) -> str:
    rendered = format(value, "f")
    if "." in rendered:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered or "0"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--hosted-zone-id", required=True)
    parser.add_argument("--admin-cidr", required=True)
    parser.add_argument("--lifecycle-runner-image", required=True)
    parser.add_argument("--artifact-manifest-s3-uri", required=True)
    parser.add_argument("--artifact-manifest-sha256", required=True)
    parser.add_argument("--planning-estimate-usd", required=True, type=bounded_planning_estimate)
    parser.add_argument("--notification-email")
    args = parser.parse_args()

    notification_email = (args.notification_email or "").strip() or None
    values: list[tuple[str, str | Decimal | None]] = [
        ("run_id", args.run_id),
        ("hosted_zone_id", args.hosted_zone_id),
        ("admin_cidr", args.admin_cidr),
        ("lifecycle_runner_image", args.lifecycle_runner_image),
        ("artifact_manifest_s3_uri", args.artifact_manifest_s3_uri),
        ("artifact_manifest_sha256", args.artifact_manifest_sha256),
        ("cost_control_mode", "TIME_BOUNDED"),
        ("planning_estimate_usd", args.planning_estimate_usd),
        ("notification_email", notification_email),
    ]

    lines = []
    for key, value in values:
        if value is None:
            rendered = "null"
        elif isinstance(value, Decimal):
            rendered = decimal_hcl(value)
        else:
            rendered = json.dumps(value, ensure_ascii=True)
        lines.append(f"{key} = {rendered}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
