#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: bash Approve-MagneticArch.sh <absolute-generated-test-network-dir>' >&2
  exit 2
fi

network_dir=$(cd "$1" && pwd)
package="$network_dir/osc-provenance.tar.gz"
if [[ ! -f "$package" || ! -f "$network_dir/scripts/envVar.sh" ]]; then
  echo 'Deploy the provenance chaincode and add Org3 before approving it here' >&2
  exit 1
fi
export TEST_NETWORK_HOME="$network_dir"
export FABRIC_CFG_PATH="$network_dir/../config"
export PATH="$network_dir/../bin:$PATH"
export VERBOSE=false
export OVERRIDE_ORG=
for tool in peer jq; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
source "$network_dir/scripts/envVar.sh"
setGlobals 3

peer channel getinfo -c osc-channel >/dev/null
package_id=$(peer lifecycle chaincode calculatepackageid "$package")
if ! peer lifecycle chaincode queryinstalled --output json |
  jq -e --arg id "$package_id" '.installed_chaincodes[]? | select(.package_id == $id)' >/dev/null; then
  peer lifecycle chaincode install "$package"
fi

committed=$(peer lifecycle chaincode querycommitted --channelID osc-channel --name osc-provenance --output json)
version=$(jq -r '.version' <<<"$committed")
sequence=$(jq -r '.sequence' <<<"$committed")
if [[ "$version" != '1.0' || "$sequence" != '1' ]]; then
  echo "Unexpected committed definition: version=$version sequence=$sequence" >&2
  exit 1
fi

peer lifecycle chaincode approveformyorg \
  -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile "$ORDERER_CA" --channelID osc-channel \
  --name osc-provenance --version "$version" \
  --package-id "$package_id" --sequence "$sequence"

peer lifecycle chaincode querycommitted --channelID osc-channel \
  --name osc-provenance --output json |
  jq -e '.approvals.MagneticArchMSP == true' >/dev/null
echo 'MagneticArchMSP has approved the committed provenance chaincode'
