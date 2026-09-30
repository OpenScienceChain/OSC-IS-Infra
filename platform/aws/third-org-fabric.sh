#!/usr/bin/env bash
set -e -o pipefail
set +x

phase=${1:?Expected phase: identity, rotate-secrets, peer, inspect-channel, prepare-channel, channel, verify-channel, join, wait-joined, or chaincode}
: "${NETWORK_DIR:?}"
: "${ORG3_CREDENTIALS_FILE:?}"
: "${ORG3_EVIDENCE_DIR:?}"
cd "$NETWORK_DIR"

export DOMAIN=localho.st
export NGINX_HTTPS_PORT=18443
export NS=osc-fabric ORG0_NS=osc-fabric ORG1_NS=osc-fabric ORG2_NS=osc-fabric ORG3_NS=osc-fabric
export TEMP_DIR="$PWD/build" CHANNEL_NAME=osc-channel ORDERER_TIMEOUT=20s
export CLUSTER_RUNTIME=eks CHAINCODE_BUILDER=ccaas LOG_FILE=/dev/null
export RCAADMIN_USER=rcaadmin
export RCAADMIN_PASS
RCAADMIN_PASS=$(jq -r '.root' "$ORG3_CREDENTIALS_FILE")
admin_pass=$(jq -r '.admin' "$ORG3_CREDENTIALS_FILE")
peer_pass=$(jq -r '.peer' "$ORG3_CREDENTIALS_FILE")
test "${#RCAADMIN_PASS}" -ge 32
test "${#admin_pass}" -ge 32
test "${#peer_pass}" -ge 32

. scripts/utils.sh
. scripts/fabric_CAs.sh
. scripts/channel.sh
. scripts/test_network.sh
. scripts/chaincode.sh

milestone() {
  jq -nc --arg phase "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{phase:$phase,atUtc:$at}' >> "$ORG3_EVIDENCE_DIR/third-org-milestones.jsonl"
}

case "$phase" in
  identity)
    if [ ! -f "$TEMP_DIR/enrollments/org3/users/rcaadmin/msp/signcerts/cert.pem" ]; then
      enroll_bootstrap_ECert_CA_user org3 "$ORG3_NS"
    fi
    if [ ! -f "$TEMP_DIR/enrollments/org3/users/org3admin/msp/signcerts/cert.pem" ]; then
      register_org_admin org3 org3admin "$admin_pass" >/dev/null 2>&1
      enroll_org_admin peer org3 org3admin "$admin_pass"
    fi
    create_channel_org_MSP org3 peer "$ORG3_NS"
    if [ ! -f "$TEMP_DIR/org3-peer1-enrolled" ]; then
      fabric-ca-client register \
        --id.name org3-peer1 --id.secret "$peer_pass" --id.type peer \
        --url "https://org3-ca.${DOMAIN}:${NGINX_HTTPS_PORT}" \
        --tls.certfiles "$TEMP_DIR/cas/org3-ca/tlsca-cert.pem" \
        --mspdir "$TEMP_DIR/enrollments/org3/users/rcaadmin/msp" >/dev/null 2>&1
      kubectl -n "$ORG3_NS" exec -i deploy/org3-ca -- /bin/sh <<EOF
set -e
export FABRIC_CA_CLIENT_HOME=/var/hyperledger/fabric-ca-client
export FABRIC_CA_CLIENT_TLS_CERTFILES=/var/hyperledger/fabric/config/tls/ca.crt
node_msp=/var/hyperledger/fabric/organizations/peerOrganizations/org3.example.com/peers/org3-peer1.org3.example.com/msp
fabric-ca-client enroll --url "https://org3-peer1:${peer_pass}@org3-ca:443" \
  --csr.hosts localhost,org3-peer1,org3-peer-gateway-svc --mspdir "\$node_msp"
cp "\$node_msp"/cacerts/*.pem "\$node_msp"/cacerts/org3-ca.pem
printf '%s\n' 'NodeOUs:' '  Enable: true' '  ClientOUIdentifier:' \
  '    Certificate: cacerts/org3-ca.pem' '    OrganizationalUnitIdentifier: client' \
  '  PeerOUIdentifier:' '    Certificate: cacerts/org3-ca.pem' '    OrganizationalUnitIdentifier: peer' \
  '  AdminOUIdentifier:' '    Certificate: cacerts/org3-ca.pem' '    OrganizationalUnitIdentifier: admin' \
  '  OrdererOUIdentifier:' '    Certificate: cacerts/org3-ca.pem' '    OrganizationalUnitIdentifier: orderer' > "\$node_msp/config.yaml"
EOF
      touch "$TEMP_DIR/org3-peer1-enrolled"
    fi
    milestone identity-ready
    echo 'Third-org CA, admin, peer identity, and channel MSP are ready.'
    ;;
  rotate-secrets)
    new_admin=$(openssl rand -hex 32)
    new_peer=$(openssl rand -hex 32)
    ca_url="https://org3-ca.${DOMAIN}:${NGINX_HTTPS_PORT}"
    root_msp="$TEMP_DIR/enrollments/org3/users/rcaadmin/msp"
    fabric-ca-client identity modify org3admin --secret "$new_admin" \
      --url "$ca_url" --tls.certfiles "$TEMP_DIR/cas/org3-ca/tlsca-cert.pem" \
      --mspdir "$root_msp" >/dev/null 2>&1
    fabric-ca-client identity modify org3-peer1 --secret "$new_peer" \
      --url "$ca_url" --tls.certfiles "$TEMP_DIR/cas/org3-ca/tlsca-cert.pem" \
      --mspdir "$root_msp" >/dev/null 2>&1
    temp_json=$(mktemp "$ORG3_EVIDENCE_DIR/.org3-credential-rotation.XXXXXX")
    trap 'rm -f "$temp_json"' EXIT
    jq --arg admin "$new_admin" --arg peer "$new_peer" '.admin=$admin | .peer=$peer' \
      "$ORG3_CREDENTIALS_FILE" > "$temp_json"
    cat "$temp_json" > "$ORG3_CREDENTIALS_FILE"
    rm -f "$temp_json"
    trap - EXIT
    milestone enrollment-secrets-rotated
    echo 'Third-org admin and peer enrollment secrets rotated; no values displayed.'
    ;;
  peer)
    test -f "$TEMP_DIR/org3-peer1-enrolled"
    envsubst < kube/org3/org3-peer1.yaml | kubectl -n "$ORG3_NS" apply -f -
    kubectl -n "$ORG3_NS" rollout status deploy/org3-peer1 --timeout=180s
    milestone peer-pod-ready
    ;;
  inspect-channel)
    export_peer_context org1 peer1
    peer channel fetch config "$ORG3_EVIDENCE_DIR/channel-before.pb" \
      -o "org0-orderer1.${DOMAIN}:${NGINX_HTTPS_PORT}" -c "$CHANNEL_NAME" \
      --tls --cafile "$TEMP_DIR/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem" >/dev/null
    configtxlator proto_decode --input "$ORG3_EVIDENCE_DIR/channel-before.pb" \
      --type common.Block --output "$ORG3_EVIDENCE_DIR/channel-before-block.json"
    jq '.data.data[0].payload.data.config' "$ORG3_EVIDENCE_DIR/channel-before-block.json" > "$ORG3_EVIDENCE_DIR/channel-before-config.json"
    jq -n --slurpfile config "$ORG3_EVIDENCE_DIR/channel-before-config.json" \
      '{sequence:$config[0].sequence,applicationOrgs:($config[0].channel_group.groups.Application.groups|keys),endorsement:$config[0].channel_group.groups.Application.policies.Endorsement.policy.value}' \
      > "$ORG3_EVIDENCE_DIR/channel-before-summary.json"
    echo 'Fetched current channel config and policy summary to private evidence directory.'
    ;;
  prepare-channel)
    : "${ORG3_CONFIGTX_TEMPLATE:?}"
    test -s "$ORG3_EVIDENCE_DIR/channel-before-config.json"
    mkdir -p "$TEMP_DIR/org3-configtx"
    envsubst < "$ORG3_CONFIGTX_TEMPLATE" > "$TEMP_DIR/org3-configtx/configtx.yaml"
    configtxgen -printOrg MagneticArchMSP -configPath "$TEMP_DIR/org3-configtx" \
      > "$ORG3_EVIDENCE_DIR/org3-config-group.json"
    jq -e '.mod_policy == "Admins" and (.values.MSP.value.config.name == "MagneticArchMSP")' \
      "$ORG3_EVIDENCE_DIR/org3-config-group.json" >/dev/null
    jq --slurpfile third "$ORG3_EVIDENCE_DIR/org3-config-group.json" '
      .channel_group.groups.Application.groups.MagneticArchMSP = $third[0]
      | reduce ["Endorsement", "LifecycleEndorsement"][] as $policy (.;
          .channel_group.groups.Application.policies[$policy].policy.value.identities += [
            {principal_classification:"ROLE",principal:{msp_identifier:"MagneticArchMSP",role:"PEER"}}
          ]
          | .channel_group.groups.Application.policies[$policy].policy.value.rule.n_out_of.rules += [{signed_by:2}])
    ' "$ORG3_EVIDENCE_DIR/channel-before-config.json" > "$ORG3_EVIDENCE_DIR/channel-after-config.json"
    jq -e '
      (.channel_group.groups.Application.groups|keys) == ["CitizenScienceMSP","MagneticArchMSP","NSGMSP"]
      and (.channel_group.groups.Application.policies.Endorsement.policy.value.identities|length) == 3
      and (.channel_group.groups.Application.policies.LifecycleEndorsement.policy.value.identities|length) == 3
    ' "$ORG3_EVIDENCE_DIR/channel-after-config.json" >/dev/null
    configtxlator proto_encode --input "$ORG3_EVIDENCE_DIR/channel-before-config.json" \
      --type common.Config --output "$ORG3_EVIDENCE_DIR/channel-before-config.pb"
    configtxlator proto_encode --input "$ORG3_EVIDENCE_DIR/channel-after-config.json" \
      --type common.Config --output "$ORG3_EVIDENCE_DIR/channel-after-config.pb"
    configtxlator compute_update --channel_id "$CHANNEL_NAME" \
      --original "$ORG3_EVIDENCE_DIR/channel-before-config.pb" \
      --updated "$ORG3_EVIDENCE_DIR/channel-after-config.pb" \
      --output "$ORG3_EVIDENCE_DIR/org3-config-update.pb"
    configtxlator proto_decode --input "$ORG3_EVIDENCE_DIR/org3-config-update.pb" \
      --type common.ConfigUpdate --output "$ORG3_EVIDENCE_DIR/org3-config-update.json"
    jq -n --arg channel "$CHANNEL_NAME" --slurpfile update "$ORG3_EVIDENCE_DIR/org3-config-update.json" \
      '{payload:{header:{channel_header:{channel_id:$channel,type:2}},data:{config_update:$update[0]}}}' \
      > "$ORG3_EVIDENCE_DIR/org3-config-envelope.json"
    configtxlator proto_encode --input "$ORG3_EVIDENCE_DIR/org3-config-envelope.json" \
      --type common.Envelope --output "$ORG3_EVIDENCE_DIR/org3-config-envelope.pb"
    echo 'Prepared unsigned config update: one org group plus two endorsement policies.'
    ;;
  channel)
    test -s "$ORG3_EVIDENCE_DIR/org3-config-envelope.pb"
    export_peer_context org1 peer1
    peer channel signconfigtx -f "$ORG3_EVIDENCE_DIR/org3-config-envelope.pb"
    export_peer_context org2 peer1
    peer channel signconfigtx -f "$ORG3_EVIDENCE_DIR/org3-config-envelope.pb"
    export_peer_context org1 peer1
    peer channel update -f "$ORG3_EVIDENCE_DIR/org3-config-envelope.pb" \
      -c "$CHANNEL_NAME" -o "org0-orderer1.${DOMAIN}:${NGINX_HTTPS_PORT}" \
      --tls --cafile "$TEMP_DIR/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem"
    milestone channel-update-submitted
    ;;
  verify-channel)
    export_peer_context org1 peer1
    peer channel fetch config "$ORG3_EVIDENCE_DIR/channel-after.pb" \
      -o "org0-orderer1.${DOMAIN}:${NGINX_HTTPS_PORT}" -c "$CHANNEL_NAME" \
      --tls --cafile "$TEMP_DIR/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem" >/dev/null
    configtxlator proto_decode --input "$ORG3_EVIDENCE_DIR/channel-after.pb" \
      --type common.Block --output "$ORG3_EVIDENCE_DIR/channel-after-block.json"
    jq '.data.data[0].payload.data.config' "$ORG3_EVIDENCE_DIR/channel-after-block.json" \
      > "$ORG3_EVIDENCE_DIR/channel-committed-config.json"
    jq -e '.sequence == "1" and (.channel_group.groups.Application.groups.MagneticArchMSP != null)
      and (.channel_group.groups.Application.policies.Endorsement.policy.value.identities|length) == 3' \
      "$ORG3_EVIDENCE_DIR/channel-committed-config.json" >/dev/null
    milestone channel-config-committed
    echo 'Committed config sequence 1 contains MagneticArchMSP and three-org endorsement policy.'
    ;;
  join)
    test -s "$ORG3_EVIDENCE_DIR/channel-after.pb"
    export_peer_context org3 peer1
    peer channel fetch 0 "$ORG3_EVIDENCE_DIR/channel-genesis.pb" \
      -o "org0-orderer1.${DOMAIN}:${NGINX_HTTPS_PORT}" -c "$CHANNEL_NAME" \
      --tls --cafile "$TEMP_DIR/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem" >/dev/null
    peer channel join --blockpath "$ORG3_EVIDENCE_DIR/channel-genesis.pb" \
      --orderer "org0-orderer1.${DOMAIN}" --connTimeout "$ORDERER_TIMEOUT" \
      --tls --cafile "$TEMP_DIR/channel-msp/ordererOrganizations/org0/orderers/org0-orderer1/tls/signcerts/tls-cert.pem"
    milestone peer-join-submitted
    ;;
  wait-joined)
    export_peer_context org3 peer1
    for attempt in $(seq 1 48); do
      if peer channel getinfo -c "$CHANNEL_NAME" > "$ORG3_EVIDENCE_DIR/org3-channel-info.txt" 2>/dev/null; then
        milestone peer-joined-and-readable
        echo 'Third peer channel info is readable.'
        exit 0
      fi
      sleep 5
    done
    echo 'Third peer did not become readable within 240 seconds.' >&2
    exit 1
    ;;
  chaincode)
    : "${ORG3_CHAINCODE_IMAGE:?}"
    [[ "$ORG3_CHAINCODE_IMAGE" == *@sha256:* ]] || { echo 'Chaincode image must be pinned by digest.' >&2; exit 2; }
    package="$TEMP_DIR/org3-osc-provenance.tgz"
    package_chaincode osc-provenance osc-provenance "$package"
    set_chaincode_id "$package"
    launch_chaincode_service org3 peer1 osc-provenance "$CHAINCODE_ID" "$ORG3_CHAINCODE_IMAGE"
    install_chaincode_for org3 peer1 "$package"
    approve_chaincode_for org3 osc-provenance "$CHAINCODE_ID"
    export_peer_context org3 peer1
    peer lifecycle chaincode querycommitted -C "$CHANNEL_NAME" -n osc-provenance \
      > "$ORG3_EVIDENCE_DIR/org3-chaincode-committed.txt"
    grep -q 'Sequence: 1' "$ORG3_EVIDENCE_DIR/org3-chaincode-committed.txt"
    milestone chaincode-ready
    echo 'Third peer installed and approved the pinned chaincode; committed definition sequence 1 is visible.'
    ;;
  *) echo "Unknown phase: $phase" >&2; exit 2 ;;
esac
