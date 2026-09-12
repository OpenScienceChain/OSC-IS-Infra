#!/usr/bin/env python3
"""Fail closed unless the approved OSC-IS AWS identity is active."""

from __future__ import annotations

import json

from aws_common import AUTHORIZED_REGION, assert_authorized_identity


def main() -> None:
    identity = assert_authorized_identity()
    print(
        json.dumps(
            {
                "authorized": True,
                "account": identity["Account"],
                "arn": identity["Arn"],
                "region": AUTHORIZED_REGION,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
