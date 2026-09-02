#!/usr/bin/env python3
"""Render the reviewed upper-bound cost model for one evidence run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HOURLY = {
    "EKS control plane": 0.1000,
    "3 x m7i.large nodes": 0.3024,
    "Amazon MQ mq.m7g.medium": 0.1367,
    "NAT gateway": 0.0450,
    "NAT public IPv4": 0.0050,
    "EBS, logs, ECR, and data transfer allowance": 0.0400,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hours", type=float, default=8.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.hours <= 0 or args.hours > 8:
        raise SystemExit("A run must be greater than zero and no longer than eight hours")

    hourly = round(sum(HOURLY.values()), 4)
    subtotal = round(hourly * args.hours, 2)
    maximum = round(subtotal * 1.25, 2)
    report = {
        "schemaVersion": 1,
        "currency": "USD",
        "hours": args.hours,
        "componentsHourly": HOURLY,
        "estimatedHourly": hourly,
        "estimatedRun": subtotal,
        "maximumWith25PercentContingency": maximum,
        "perRunCeiling": 15.0,
        "campaignCeiling": 75.0,
        "approved": maximum < 15.0,
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    if not report["approved"]:
        raise SystemExit("Cost gate failed")


if __name__ == "__main__":
    main()
