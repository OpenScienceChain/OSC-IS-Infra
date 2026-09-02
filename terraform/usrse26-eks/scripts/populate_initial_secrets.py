#!/usr/bin/env python3
"""Populate disposable AWS secrets without placing values in Terraform state."""

from __future__ import annotations

import json
import os
import secrets
import string
import subprocess
import tempfile
from pathlib import Path


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


PROFILE = required("AWS_PROFILE")
REGION = required("AWS_REGION")
AUTHORIZED_ACCOUNT = required("AUTHORIZED_ACCOUNT")


def aws(*args: str) -> str:
    process = subprocess.run(
        ["aws", *args, "--profile", PROFILE, "--region", REGION, "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return process.stdout


def password(length: int = 40) -> str:
    alphabet = string.ascii_letters + string.digits + "!%+-.:_"
    while True:
        value = "".join(secrets.choice(alphabet) for _ in range(length))
        if len(set(value)) >= 12:
            return value


def put_secret(secret_id: str, value: dict[str, str]) -> None:
    path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".json", delete=False
        ) as handle:
            json.dump(value, handle, separators=(",", ":"))
            path = Path(handle.name)
        try:
            path.chmod(0o600)
        except OSError:
            pass
        aws(
            "secretsmanager",
            "put-secret-value",
            "--secret-id",
            secret_id,
            "--secret-string",
            f"file://{path}",
        )
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


identity = json.loads(aws("sts", "get-caller-identity"))
if identity.get("Account") != AUTHORIZED_ACCOUNT:
    raise SystemExit("AWS account guard failed; no secrets were written")

put_secret(
    required("APP_SECRET_ARN"),
    {
        "jwtSecret": secrets.token_hex(32),
        "bootstrapAdminPassword": password(),
        "listenerApiKey": secrets.token_hex(32),
        "nsgLedgerToken": secrets.token_hex(32),
        "citizenScienceLedgerToken": secrets.token_hex(32),
    },
)
put_secret(
    required("POSTGRES_SECRET_ARN"),
    {"username": "osc_app", "database": "osc_is", "password": password()},
)
put_secret(
    required("RABBITMQ_SECRET_ARN"),
    {"username": "osc_usrse26", "password": password()},
)

print("Populated three disposable Secrets Manager values; values were not logged.")
