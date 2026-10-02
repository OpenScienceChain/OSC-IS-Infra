#!/usr/bin/env python3
"""Render an immutable AWS GitOps source from reviewed image digests."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlsplit

TOKEN = re.compile(r"__[A-Z0-9_]+__")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--templates", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--demo-origin", default="https://demo.osc-staging.org")
    args = parser.parse_args()

    origin = urlsplit(args.demo_origin)
    https_origin = re.fullmatch(
        r"https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?", args.demo_origin
    )
    loopback_origin = re.fullmatch(
        r"http://(?:localhost|127\.0\.0\.1)(?::[0-9]{1,5})?", args.demo_origin
    )
    try:
        origin.port
    except ValueError as error:
        raise SystemExit("Demo origin has an invalid port") from error
    if (
        not (https_origin or loopback_origin)
        or origin.scheme not in ("http", "https")
        or not origin.netloc
        or origin.path
        or origin.query
        or origin.fragment
        or origin.username
        or origin.password
    ):
        raise SystemExit("Demo origin must be an HTTPS origin or a loopback HTTP origin")

    artifacts = json.loads(args.artifacts.read_text(encoding="utf-8"))
    if artifacts.get("runId") != args.run_id:
        raise SystemExit("Artifact manifest run ID mismatch")

    prefix = f"osc-usrse26-{args.run_id}"
    expires_at = artifacts.get("expiresAt")
    if not isinstance(expires_at, str) or not expires_at:
        raise SystemExit("Artifact manifest is missing expiresAt")
    images = artifacts["images"]
    external_images = artifacts["externalImages"]
    replacements = {
        "__RUN_ID__": args.run_id,
        "__EXPIRES_AT__": expires_at,
        "__API_GATEWAY_IMAGE__": images["api-gateway"]["ecrReference"],
        "__WEBAPP_IMAGE__": images["webapp"]["ecrReference"],
        "__DEMO_ALLOWED_ORIGIN__": args.demo_origin,
        "__LEDGER_GATEWAY_IMAGE__": images["ledger-gateway"]["ecrReference"],
        "__SUBMISSION_WORKER_IMAGE__": images["submission-worker"]["ecrReference"],
        "__SUBMISSION_LISTENER_IMAGE__": images["submission-listener"]["ecrReference"],
        "__HISTORY_WORKER_IMAGE__": images["history-worker"]["ecrReference"],
        "__AWS_LOAD_BALANCER_CONTROLLER_IMAGE__": external_images[
            "aws-load-balancer-controller"
        ],
        "__API_AUTH_SECRET_NAME__": f"{prefix}/api/auth",
        "__LISTENER_AUTH_SECRET_NAME__": f"{prefix}/submission-listener/auth",
        "__DEMO_AUTH_SECRET_NAME__": f"{prefix}/demo/auth",
        "__LEDGER_NSG_AUTH_SECRET_NAME__": f"{prefix}/ledger/nsg/auth",
        "__LEDGER_CITIZEN_AUTH_SECRET_NAME__": f"{prefix}/ledger/citizen-science/auth",
        "__LEDGER_MAGNETIC_ARCH_AUTH_SECRET_NAME__": f"{prefix}/ledger/magnetic-arch/auth",
        "__POSTGRES_SECRET_NAME__": f"{prefix}/postgres",
        "__RABBITMQ_SECRET_NAME__": f"{prefix}/rabbitmq",
        "__FABRIC_NSG_SECRET_NAME__": f"{prefix}/fabric/nsg",
        "__FABRIC_CITIZEN_SECRET_NAME__": f"{prefix}/fabric/citizen-science",
        "__FABRIC_MAGNETIC_ARCH_SECRET_NAME__": f"{prefix}/fabric/magnetic-arch",
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
