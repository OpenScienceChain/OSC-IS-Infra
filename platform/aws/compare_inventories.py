#!/usr/bin/env python3
"""Prove that final AWS inventory contains no resource absent from baseline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("final", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    baseline = load(args.baseline)
    final = load(args.final)
    if baseline.get("account") != final.get("account") or baseline.get("region") != final.get("region"):
        raise SystemExit("Inventory account or region mismatch")

    added: dict[str, list[str]] = {}
    for category, final_values in final.get("resources", {}).items():
        baseline_values = set(baseline.get("resources", {}).get(category, []))
        difference = sorted(set(final_values) - baseline_values)
        if difference:
            added[category] = difference

    prefix = f"osc-usrse26-{args.run_id}"
    run_remnants = {
        category: [value for value in values if prefix in value]
        for category, values in final.get("resources", {}).items()
        if any(prefix in value for value in values)
    }

    report = {
        "schemaVersion": 1,
        "runId": args.run_id,
        "parity": not added,
        "addedSinceBaseline": added,
        "runRemnants": run_remnants,
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")

    if added or run_remnants:
        raise SystemExit("AWS teardown verification failed: resources remain after the run")


if __name__ == "__main__":
    main()
