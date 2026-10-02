#!/usr/bin/env python3
"""Upload the third Fabric identity and independent gateway token without echoing values."""

from __future__ import annotations

import argparse
import secrets
from pathlib import Path

from aws_common import assert_authorized_identity, aws_json
from upload_fabric_identities import put_secret, tls_ca


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    if args.run_id != "usrse260930":
        raise SystemExit("Only the reviewed evidence run is supported")
    assert_authorized_identity()

    msp = (
        args.network
        / "build"
        / "enrollments"
        / "org3"
        / "users"
        / "org3admin"
        / "msp"
    )
    certificate = (msp / "signcerts" / "cert.pem").read_text(encoding="utf-8")
    private_key = (msp / "keystore" / "key.pem").read_text(encoding="utf-8")
    root = tls_ca("org3-peer1-tls-cert")
    if ("BEGIN CERTIFICATE" not in certificate or "BEGIN PRIVATE KEY" not in private_key
            or "BEGIN CERTIFICATE" not in root):
        raise SystemExit("Third-org Fabric identity is incomplete")

    prefix = f"osc-usrse26-{args.run_id}"
    names = (
        f"{prefix}/fabric/magnetic-arch",
        f"{prefix}/ledger-token/magnetic-arch",
    )
    for name in names:
        versions = aws_json(
            "secretsmanager", "describe-secret", "--secret-id", name
        ).get("VersionIdsToStages", {})
        if any("AWSCURRENT" in stages for stages in versions.values()):
            raise SystemExit(
                "Third-org credentials already exist; refusing an uncoordinated rotation"
            )
    put_secret(
        names[0],
        {"certificate": certificate, "privateKey": private_key, "tlsCa": root},
    )
    put_secret(
        names[1],
        {"token": secrets.token_urlsafe(48)},
    )
    print("Uploaded the third-org service identity and independent token; values were not logged.")


if __name__ == "__main__":
    main()
