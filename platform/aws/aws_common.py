#!/usr/bin/env python3
"""Shared, dependency-free AWS CLI helpers for the disposable evidence run."""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any

AUTHORIZED_ACCOUNT = "269624229733"
AUTHORIZED_REGION = "us-west-2"


class AwsCommandError(RuntimeError):
    """Raised when an AWS CLI command fails."""


def aws_json(*args: str) -> Any:
    command = ["aws", *args]
    if profile := os.environ.get("AWS_PROFILE"):
        command.extend(["--profile", profile])
    command.extend(
        ["--region", AUTHORIZED_REGION, "--output", "json", "--no-cli-pager"]
    )
    process = subprocess.run(command, capture_output=True, text=True)
    if process.returncode != 0:
        stderr = process.stderr.strip() or "AWS CLI command failed"
        raise AwsCommandError(f"{' '.join(command[:2])}: {stderr}")
    try:
        return json.loads(process.stdout or "null")
    except json.JSONDecodeError as error:
        raise AwsCommandError(f"AWS CLI returned malformed JSON: {error}") from error


def assert_authorized_identity() -> dict[str, Any]:
    identity = aws_json("sts", "get-caller-identity")
    if identity.get("Account") != AUTHORIZED_ACCOUNT:
        raise SystemExit(
            "AWS account guard failed: expected "
            f"{AUTHORIZED_ACCOUNT}, received {identity.get('Account', 'unknown')}"
        )
    return identity
