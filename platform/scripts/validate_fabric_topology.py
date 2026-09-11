#!/usr/bin/env python3
"""Validate the generated Fabric topology used by the interactive demo."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", type=Path, required=True)
    parser.add_argument("--deploy-script", type=Path, required=True)
    args = parser.parse_args()

    deploy = args.deploy_script.read_text(encoding="utf-8")
    network = args.network
    errors: list[str] = []
    if "TEST_NETWORK_ORDERER_TYPE=raft" not in deploy:
        errors.append("deployment script does not pin Raft ordering")

    test_network = (network / "scripts/test_network.sh").read_text(encoding="utf-8")
    unconditional = test_network.split('if  [ "${ORDERER_TYPE}" == "bft" ]', 1)[0]
    orderers = sorted(set(re.findall(r"apply_template kube/org0/org0-(orderer[0-9]+)[.]yaml", unconditional)))
    if orderers != ["orderer1", "orderer2", "orderer3"]:
        errors.append(f"expected three active Raft orderers, found {orderers}")

    for org in ("org1", "org2"):
        peers = sorted(set(re.findall(rf"apply_template kube/{org}/{org}-(peer[0-9]+)[.]yaml", test_network)))
        if peers != ["peer1", "peer2"]:
            errors.append(f"expected two peers for {org}, found {peers}")

    required = [
        network / "kube/org0/org0-orderer1.yaml",
        network / "kube/org0/org0-orderer2.yaml",
        network / "kube/org0/org0-orderer3.yaml",
        network / "kube/org1/org1-peer1.yaml",
        network / "kube/org1/org1-peer2.yaml",
        network / "kube/org2/org2-peer1.yaml",
        network / "kube/org2/org2-peer2.yaml",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        errors.append(f"missing generated manifests: {', '.join(missing)}")

    for path in required:
        if path.is_file() and "@sha256:" not in path.read_text(encoding="utf-8"):
            errors.append(f"{path} contains no immutable image reference")

    if errors:
        print("Fabric topology validation failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)
    print("Fabric topology validation passed: Raft 3 orderers, NSG 2 peers, Citizen Science 2 peers.")


if __name__ == "__main__":
    main()
