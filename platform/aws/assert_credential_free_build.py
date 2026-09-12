#!/usr/bin/env python3
"""Fail closed when common cloud credential sources reach an artifact build."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Mapping, Sequence


CREDENTIAL_ENVIRONMENT_VARIABLES = {
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_URL",
    "AWS_ACCESS_KEY_ID",
    "AWS_CONFIG_FILE",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_DEFAULT_PROFILE",
    "AWS_PROFILE",
    "AWS_ROLE_ARN",
    "AWS_ROLE_SESSION_NAME",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SECURITY_TOKEN",
    "AWS_SESSION_TOKEN",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AZURE_CLIENT_CERTIFICATE_PATH",
    "AZURE_CLIENT_SECRET",
    "AZURE_FEDERATED_TOKEN_FILE",
    "CI_JOB_JWT",
    "CI_JOB_JWT_V2",
    "GOOGLE_APPLICATION_CREDENTIALS",
}
SAFE_AWS_ENVIRONMENT_VARIABLES = {
    "AWS_DEFAULT_REGION",
    "AWS_EC2_METADATA_DISABLED",
    "AWS_REGION",
}


def default_home_paths(environment: Mapping[str, str]) -> list[Path]:
    values = {
        environment.get("HOME", "").strip(),
        environment.get("USERPROFILE", "").strip(),
    }
    return [Path(value) for value in sorted(values) if value]


def default_service_token_paths() -> list[Path]:
    return [
        Path("/var/run/secrets/eks.amazonaws.com/serviceaccount/token"),
        Path("/var/run/secrets/kubernetes.io/serviceaccount/token"),
    ]


def path_contains_files(path: Path) -> bool:
    if path.is_file():
        return path.stat().st_size > 0
    if path.is_dir():
        return any(candidate.is_file() for candidate in path.rglob("*"))
    return False


def inspect_sources(
    environment: Mapping[str, str],
    home_paths: Sequence[Path],
    service_token_paths: Sequence[Path],
) -> dict[str, object]:
    findings: list[dict[str, str]] = []
    populated = {name for name, value in environment.items() if value.strip()}
    aws_candidates = {
        name for name in populated
        if name.startswith("AWS_") and name not in SAFE_AWS_ENVIRONMENT_VARIABLES
    }
    for name in sorted((populated & CREDENTIAL_ENVIRONMENT_VARIABLES) | aws_candidates):
        if environment.get(name, "").strip():
            findings.append({"kind": "environment", "source": name})
    if environment.get("AWS_EC2_METADATA_DISABLED", "").lower() != "true":
        findings.append({"kind": "metadata-service", "source": "AWS_EC2_METADATA_DISABLED"})

    for home in home_paths:
        aws_root = home / ".aws"
        for relative in ("credentials", "config", "sso/cache", "cli/cache"):
            candidate = aws_root / relative
            if path_contains_files(candidate):
                findings.append({"kind": "aws-home", "source": str(candidate)})

    for candidate in service_token_paths:
        if path_contains_files(candidate):
            findings.append({"kind": "service-token", "source": str(candidate)})

    return {
        "schemaVersion": 1,
        "status": (
            "ENFORCED_COMMON_AWS_SOURCES_ABSENT"
            if not findings
            else "REJECTED_CREDENTIAL_SOURCE_PRESENT"
        ),
        "commonAwsCredentialSourcesAbsent": not findings,
        "checks": {
            "credentialEnvironmentVariables": len(CREDENTIAL_ENVIRONMENT_VARIABLES),
            "unknownAwsEnvironmentVariablesRejected": True,
            "instanceMetadataDisabled": environment.get("AWS_EC2_METADATA_DISABLED", "").lower() == "true",
            "homeDirectories": len(home_paths),
            "serviceTokenPaths": len(service_token_paths),
        },
        "findings": findings,
        "limitation": (
            "This fail-closed preflight checks common AWS, CI OIDC, cloud SDK, "
            "and service-account credential sources. It does not prove that an "
            "unknown credential source cannot exist. Artifact builds must also "
            "run in a job with no secrets and no id-token permission."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    report = inspect_sources(
        os.environ,
        default_home_paths(os.environ),
        default_service_token_paths(),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not report["commonAwsCredentialSourcesAbsent"]:
        raise SystemExit(
            "Credential-bearing build rejected; only source names and paths were reported."
        )


if __name__ == "__main__":
    main()
