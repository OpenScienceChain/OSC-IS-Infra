#!/usr/bin/env python3
"""Render an immutable AWS GitOps source from reviewed image digests."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

TOKEN = re.compile(r"__[A-Z0-9_]+__")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--templates", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    artifacts = json.loads(args.artifacts.read_text(encoding="utf-8"))
    if artifacts.get("runId") != args.run_id:
        raise SystemExit("Artifact manifest run ID mismatch")

    prefix = f"osc-usrse26-{args.run_id}"
    images = artifacts["images"]
    external_images = artifacts["externalImages"]
    replacements = {
        "__RUN_ID__": args.run_id,
        "__API_GATEWAY_IMAGE__": images["api-gateway"]["ecrReference"],
        "__LEDGER_GATEWAY_IMAGE__": images["ledger-gateway"]["ecrReference"],
        "__SUBMISSION_WORKER_IMAGE__": images["submission-worker"]["ecrReference"],
        "__SUBMISSION_LISTENER_IMAGE__": images["submission-listener"]["ecrReference"],
        "__HISTORY_WORKER_IMAGE__": images["history-worker"]["ecrReference"],
        "__AWS_LOAD_BALANCER_CONTROLLER_IMAGE__": external_images[
            "aws-load-balancer-controller"
        ],
        "__APP_SECRET_NAME__": f"{prefix}/application",
        "__POSTGRES_SECRET_NAME__": f"{prefix}/postgres",
        "__RABBITMQ_SECRET_NAME__": f"{prefix}/rabbitmq",
        "__FABRIC_NSG_SECRET_NAME__": f"{prefix}/fabric/nsg",
        "__FABRIC_CITIZEN_SECRET_NAME__": f"{prefix}/fabric/citizen-science",
    }

    if args.destination.exists():
        shutil.rmtree(args.destination)
    shutil.copytree(args.templates, args.destination)

    for path in args.destination.rglob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        for token, value in replacements.items():
            text = text.replace(token, value)
        unresolved = sorted(set(TOKEN.findall(text)))
        if unresolved:
            raise SystemExit(f"Unresolved tokens in {path}: {', '.join(unresolved)}")
        path.write_text(text, encoding="utf-8", newline="\n")

    print(f"Rendered AWS GitOps manifests at {args.destination}")


if __name__ == "__main__":
    main()
