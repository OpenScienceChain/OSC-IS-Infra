#!/usr/bin/env python3
"""Create a reviewed OSC copy of the pinned Fabric Kubernetes test network."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path


TEXT_SUFFIXES = {".json", ".md", ".properties", ".sh", ".txt", ".yaml", ".yml"}


def parse_versions(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def replace_required(path: Path, old: str, new: str, expected: int | None = None) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count == 0 or (expected is not None and count != expected):
        raise RuntimeError(f"unexpected upstream shape in {path}: found {count} copies of {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")


def regex_replace_required(path: Path, pattern: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError(f"unexpected upstream shape in {path}: pattern did not match once")
    path.write_text(updated, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--fabric-bin", type=Path, required=True)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--versions", type=Path, required=True)
    args = parser.parse_args()

    versions = parse_versions(args.versions)
    head = subprocess.check_output(
        ["git", "-C", str(args.source_root), "rev-parse", "HEAD"], text=True
    ).strip()
    if head != versions["FABRIC_SAMPLES_COMMIT"]:
        raise RuntimeError(f"Fabric samples commit mismatch: {head}")

    source = args.source_root / "test-network-k8s"
    if args.destination.exists():
        shutil.rmtree(args.destination)
    shutil.copytree(source, args.destination)

    for path in args.destination.rglob("*"):
        if path.is_file() and (path.suffix in TEXT_SUFFIXES or path.name == "network"):
            path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n"))

    shutil.copy2(args.vendor / "cert-manager-v1.21.1.yaml", args.destination / "kube" / "cert-manager.yaml")
    shutil.copy2(
        args.vendor / "ingress-nginx-kind-v1.15.1.yaml",
        args.destination / "kube" / "ingress-nginx-kind.yaml",
    )

    for path in args.destination.rglob("*"):
        if path.is_file() and (path.suffix in TEXT_SUFFIXES or path.name == "network"):
            text = path.read_text(encoding="utf-8")
            text = text.replace("Org1MSP", "NSGMSP").replace("Org2MSP", "CitizenScienceMSP")
            path.write_text(text, encoding="utf-8", newline="\n")

    cluster_script = args.destination / "scripts" / "cluster.sh"
    replace_required(
        cluster_script,
        "kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml",
        "kubectl apply --server-side -f kube/cert-manager.yaml",
        1,
    )
    replace_required(
        cluster_script,
        "curl https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml | kubectl delete -f -",
        "kubectl delete -f kube/cert-manager.yaml --ignore-not-found=true",
        1,
    )

    ingress = args.destination / "kube" / "ingress-nginx-kind.yaml"
    replace_required(
        ingress,
        "        - --ingress-class=nginx\n",
        "        - --ingress-class=nginx\n        - --enable-ssl-passthrough\n",
        1,
    )
    replace_required(
        ingress,
        "      nodeSelector:\n        kubernetes.io/os: linux\n      serviceAccountName: ingress-nginx\n",
        "      nodeSelector:\n        ingress-ready: \"true\"\n        kubernetes.io/os: linux\n      serviceAccountName: ingress-nginx\n",
        1,
    )

    prereqs = args.destination / "scripts" / "prereqs.sh"
    regex_replace_required(
        prereqs,
        r"  # Use the local fabric binaries if available\. If not, go get them\..*?  # Check if the binaries match your docker images",
        """  # Binaries are downloaded and checksum-verified by prepare-local.sh.
  if ! bin/peer version &> /dev/null || ! bin/fabric-ca-client version &> /dev/null; then
    echo "Verified Fabric binaries are unavailable; run platform/scripts/prepare-local.sh"
    exit 1
  fi

  # Check if the binaries match your docker images""",
    )

    image_replacements = {
        "${FABRIC_CONTAINER_REGISTRY}/fabric-ca:${FABRIC_CA_VERSION}": versions["FABRIC_CA_IMAGE"],
        "${FABRIC_CONTAINER_REGISTRY}/fabric-orderer:${FABRIC_VERSION}": versions["FABRIC_ORDERER_IMAGE"],
        "${FABRIC_PEER_IMAGE}": versions["FABRIC_PEER_IMAGE"],
        "couchdb:${COUCHDB_VERSION}": versions["COUCHDB_IMAGE"],
        "busybox:latest": versions["BUSYBOX_IMAGE"],
    }
    for path in (args.destination / "kube").rglob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        for old, new in image_replacements.items():
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8", newline="\n")

    chaincode = args.destination / "scripts" / "chaincode.sh"
    replace_required(
        chaincode,
        "    publish_chaincode_image ${cc_name} ${CHAINCODE_IMAGE}\n",
        """    publish_chaincode_image ${cc_name} ${CHAINCODE_IMAGE}
    export CHAINCODE_IMAGE=$(${CONTAINER_CLI} inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' ${CHAINCODE_IMAGE} | grep \"^localhost:${LOCAL_REGISTRY_PORT}/\" | head -1)
    if [[ \"${CHAINCODE_IMAGE}\" != localhost:${LOCAL_REGISTRY_PORT}/*@sha256:* ]]; then
      echo \"Unable to resolve immutable chaincode image digest\"
      exit 1
    fi
""",
        1,
    )
    replace_required(
        chaincode,
        """function launch_chaincode() {
  local org=org1
  local cc_name=$1
  local cc_id=$2
  local cc_image=$3

  launch_chaincode_service ${org} peer1 ${cc_name} ${cc_id} ${cc_image}
  launch_chaincode_service ${org} peer2 ${cc_name} ${cc_id} ${cc_image}
}
""",
        """function launch_chaincode() {
  local cc_name=$1
  local cc_id=$2
  local cc_image=$3

  for org in org1 org2; do
    launch_chaincode_service ${org} peer1 ${cc_name} ${cc_id} ${cc_image}
    launch_chaincode_service ${org} peer2 ${cc_name} ${cc_id} ${cc_image}
  done
}
""",
        1,
    )
    replace_required(
        chaincode,
        """function install_chaincode() {
  local org=org1
  local cc_package=$1

  install_chaincode_for ${org} peer1 ${cc_package}
  install_chaincode_for ${org} peer2 ${cc_package}
}
""",
        """function install_chaincode() {
  local cc_package=$1

  for org in org1 org2; do
    install_chaincode_for ${org} peer1 ${cc_package}
    install_chaincode_for ${org} peer2 ${cc_package}
  done
}
""",
        1,
    )
    regex_replace_required(
        chaincode,
        r"# approve the chaincode package for an org and assign a name\nfunction approve_chaincode\(\) \{.*?\n\}\n\n# commit the named chaincode for an org",
        """# approve the chaincode package for each peer organization
function approve_chaincode_for() {
  local org=$1
  local peer=peer1
  local cc_name=$2
  local cc_id=$3
  push_fn "Approving chaincode ${cc_name} for ${org} with ID ${cc_id}"

  export_peer_context $org $peer

  peer lifecycle chaincode approveformyorg \\
    --channelID     ${CHANNEL_NAME} \\
    --name          ${cc_name} \\
    --version       1 \\
    --package-id    ${cc_id} \\
    --sequence      1 \\
    --orderer       org0-orderer1.${DOMAIN}:${NGINX_HTTPS_PORT} \\
    --connTimeout   ${ORDERER_TIMEOUT} \\
    --tls --cafile  ${TEMP_DIR}/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem \\
    ${APPROVE_EXTRA_ARGS}

  pop_fn
}

function approve_chaincode() {
  local cc_name=$1
  local cc_id=$2
  approve_chaincode_for org1 ${cc_name} ${cc_id}
  approve_chaincode_for org2 ${cc_name} ${cc_id}
}

# commit the named chaincode for an org""",
    )

    for template in (
        args.destination / "kube" / "org1" / "org1-cc-template.yaml",
        args.destination / "kube" / "org2" / "org2-cc-template.yaml",
    ):
        replace_required(
            template,
            """            - name: CORE_CHAINCODE_ID_NAME
              value: {{CHAINCODE_ID}}
          ports:
""",
            """            - name: CORE_CHAINCODE_ID_NAME
              value: {{CHAINCODE_ID}}
            - name: CHAINCODE_TLS_REQUIRED
              value: "false"
          ports:
""",
            1,
        )
        replace_required(
            template,
            """    spec:
      containers:
""",
            """    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
""",
            1,
        )
        replace_required(
            template,
            """          imagePullPolicy: IfNotPresent
          env:
""",
            """          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
            runAsUser: 65532
            runAsGroup: 65532
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          env:
""",
            1,
        )

    bin_dir = args.destination / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name in ("peer", "configtxgen", "configtxlator", "fabric-ca-client", "osnadmin"):
        source_bin = args.fabric_bin / name
        if not source_bin.is_file():
            raise RuntimeError(f"verified Fabric binary missing: {source_bin}")
        shutil.copy2(source_bin, bin_dir / name)
        os.chmod(bin_dir / name, 0o755)
    os.chmod(args.destination / "network", 0o755)

    forbidden = ("curl -sSL", "busybox:latest", "Org1MSP", "Org2MSP")
    for path in args.destination.rglob("*"):
        if path.is_file() and (path.suffix in TEXT_SUFFIXES or path.name == "network"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for token in forbidden:
                if token in text:
                    raise RuntimeError(f"forbidden token {token!r} remains in {path}")

    print(f"Prepared OSC Fabric network at {args.destination}")


if __name__ == "__main__":
    main()
