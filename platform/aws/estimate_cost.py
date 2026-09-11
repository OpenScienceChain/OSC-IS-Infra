#!/usr/bin/env python3
"""Render the reviewed pre-deployment planning estimate for the demo."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HOURLY = {
    "EKS control plane": 0.1000,
    "3 x m7i.large nodes": 0.3024,
    "3 x Amazon MQ mq.m7g.medium brokers": 0.4101,
    "NAT gateway": 0.0450,
    "NAT public IPv4": 0.0050,
    "EBS, logs, ECR, edge, lifecycle, and data transfer allowance": 0.0800,
}

FIXED_REHEARSAL_AND_CONTROL_ALLOWANCE = 20.0
PLANNING_ESTIMATE_CEILING = 200.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hours", type=float, default=72.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.hours <= 0 or args.hours > 72:
        raise SystemExit("A run must be greater than zero and no longer than 72 hours")

    hourly = round(sum(HOURLY.values()), 4)
    subtotal = round(hourly * args.hours, 2)
    maximum = round(subtotal * 1.25 + FIXED_REHEARSAL_AND_CONTROL_ALLOWANCE, 2)
    report = {
        "schemaVersion": 3,
        "costControlMode": "TIME_BOUNDED",
        "evidenceClass": "PRE_DEPLOYMENT_PLANNING_ESTIMATE",
        "currency": "USD",
        "hours": args.hours,
        "componentsHourly": HOURLY,
        "estimatedHourly": hourly,
        "estimatedRun": subtotal,
        "plannedEstimateWith25PercentContingency": maximum,
        "fixedRehearsalAndControlAllowance": FIXED_REHEARSAL_AND_CONTROL_ALLOWANCE,
        "planningEstimateCeilingUsd": PLANNING_ESTIMATE_CEILING,
        "boundedExposure": {
            "maximumRuntimeHours": 72,
            "capacity": "fixed reviewed topology; no unbounded autoscaling or user infrastructure",
        },
        "actualBilledCost": {
            "status": "NOT_RECONCILED",
            "amountUsd": None,
            "source": "human CloudBank or account billing reconciliation after teardown",
        },
        "approvedForPlanning": maximum <= PLANNING_ESTIMATE_CEILING,
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    if not report["approvedForPlanning"]:
        raise SystemExit("Pre-deployment planning-estimate gate failed")


if __name__ == "__main__":
    main()
