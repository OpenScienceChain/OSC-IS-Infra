#!/usr/bin/env python3
"""Upload generated Fabric service identities without logging secret material."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import tempfile
from pathlib import Path

from aws_common import assert_authorized_identity, aws_json


def kubectl_json(*args: str) -> dict:
    process = subprocess.run(
        ["kubectl", *args, "-o", "json"], capture_output=True, text=True, check=True
    )
    return json.loads(process.stdout)


def tls_ca(secret_name: str) -> str:
    secret = kubectl_json("-n", "osc-fabric", "get", "secret", secret_name)
    encoded = secret.get("data", {}).get("ca.crt")
    if not encoded:
        raise SystemExit(f"Fabric TLS CA is absent from {secret_name}")
    return base64.b64decode(encoded).decode("utf-8")


def wallet_identity(path: Path, expected_msp: str, ca: str) -> dict[str, str]:
    wallet = json.loads(path.read_text(encoding="utf-8"))
    credentials = wallet.get("credentials", {})
    certificate = credentials.get("certificate", "")
    private_key = credentials.get("privateKey", "")
    if wallet.get("mspId") != expected_msp:
        raise SystemExit(f"Unexpected MSP in {path}")
    if "BEGIN CERTIFICATE" not in certificate or "BEGIN PRIVATE KEY" not in private_key:
        raise SystemExit(f"Malformed Fabric identity in {path}")
    if "BEGIN CERTIFICATE" not in ca:
        raise SystemExit(f"Malformed Fabric TLS CA for {expected_msp}")
    return {"certificate": certificate, "privateKey": private_key, "tlsCa": ca}


def put_secret(secret_name: str, value: dict[str, str]) -> None:
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
        aws_json(
            "secretsmanager",
            "put-secret-value",
            "--secret-id",
            secret_name,
            "--secret-string",
            f"file://{path}",
        )
    finally:
        if path:
            path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    assert_authorized_identity()

    wallet = args.network / "build" / "application" / "wallet"
    nsg = wallet_identity(
        wallet / "appuser_org1.id", "NSGMSP", tls_ca("org1-peer1-tls-cert")
    )
    citizen = wallet_identity(
        wallet / "appuser_org2.id",
        "CitizenScienceMSP",
        tls_ca("org2-peer1-tls-cert"),
    )

    prefix = f"osc-usrse26-{args.run_id}/fabric"
    put_secret(f"{prefix}/nsg", nsg)
    put_secret(f"{prefix}/citizen-science", citizen)
    subprocess.run(
        [
            "kubectl",
            "-n",
            "osc-fabric",
            "delete",
            "configmap",
            "app-fabric-ids-v1-map",
            "--ignore-not-found=true",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    print("Uploaded two organization service identities; values were not logged.")


if __name__ == "__main__":
    main()
