# Magnetic Arch Plasma Showcase

## Scope and source

This is a public, curator-owned example using the five configurations S0, S1,
D0, DA, and DB from [Zenodo 13987138](https://zenodo.org/records/13987138).
The source reports measurements collected in February-March 2023. OSC records
80 named file SHA-256 hashes, five configuration-level footprints, metadata,
and one workflow linking all five artifacts. OSC does not import or host the
underlying CSV/TXT files. The preparation script temporarily downloads the
source archives, checks the published archive sizes and MD5 values, hashes
individual entries, then removes downloads from that run. It leaves a
hash-only JSON manifest in ignored `.generated` storage.

The source description calls its license CC BY 4.0, while the structured
Zenodo API currently reports `odc-by`. Do not state one as definitive in the
portal; point viewers to the source record for the authoritative terms and
credit the authors. Do not redistribute the source files from OSC.

## Local integration gate

Use the isolated `feature/magnetic-arch-showcase` worktrees for Gateway,
Chaincode, Artifact Submission, and Infra. The WebApp includes the other
agent's completed `98b9281` checkpoint of the 18088 portal. Do not start
this stack while another OSC demo stack or fixed-name Fabric network is live.
The generated network is disposable, but the source repos and current 18088
application are not.

1. Checkpoint all five source repos, record exact SHAs, and run the relevant
   unit tests. The showcase Gateway and worker changes must be built into the
   local Compose images, not substituted with the current running containers.
2. From this directory, run `Prepare-MagneticArchDataset.ps1`. Review the
   generated hash-only `.generated/magnetic-arch-manifest.json`: five
   configurations, 80 files, source DOI, per-file hashes, and no file bytes.
3. Run `Stage-Network.ps1 -ToolsRoot <verified-local-Fabric-tools>` once into
   a fresh ignored `.generated/test-network`. It copies tracked Network files
   and substitutes `NSGMSP`, `CitizenScienceMSP`, and `MagneticArchMSP` only in
   the disposable copy. Run `Test-Preflight.ps1` with exact source revisions,
   the completed WebApp checkout, and `-RequireReady` before startup.
4. After the other stack is stopped, create the Fabric channel with the staged
   `network.sh`, deploy this branch's Go chaincode as `osc-provenance` version
   1.0 sequence 1, then join Org3 through the staged `addOrg3/addOrg3.sh`.
   Run `Approve-MagneticArch.sh <absolute-staged-network>` and
   `Verify-LiveFabric.sh <absolute-staged-network>`. The latter must show all
   three MSPs in the live channel and all three peers observing the committed
   definition. A static preflight is not a substitute.
5. Generate ignored `local.env` with `New-LocalEnv.ps1` only after Org3 has
   issued its client identity. Run `docker compose --env-file
   .generated/local.env config --quiet`, then build/start exactly this
   Compose project. The app is intended at `http://localhost:18088/` and the
   Gateway at `http://127.0.0.1:13388/api/v1/`.
6. Run `node Seed-MagneticArch.mjs`. It creates a dedicated third-org curator
   through the local bootstrap admin, submits each artifact through the
   normal authenticated Gateway/outbox/worker path, waits for a confirmed
   transaction in Fabric history, then links them in one workflow. A rerun
   checks existing public records and should not create duplicates. Never
   declare success from database state alone.
7. Verify anonymous catalog/detail/history reads; compare every displayed
   hash and footprint with the prepared manifest. Check that another member
   cannot update these records, and that third-org identity cannot read or
   mutate records owned by the other two MSPs. Test an interrupted worker,
   pending state, recovery, and a second seed invocation. Exercise desktop
   and mobile layouts and Axe/keyboard checks after WebApp integration.

The local E2E run remains **unverified** until steps 4-7 execute against real
Fabric. The existing 18088 stack uses fixed ports/names, so it must not be
disturbed by an overlapping run. Preserve the active stack until its owner has
finished; never use broad Docker prune or `network.sh down` for teardown.

## EKS adoption plan (no cloud changes in this branch)

The EKS deployment presently encodes two organizations. Add a third only
after the local evidence above passes and a separate cost/security review
approves cloud work. Keep the same Gateway and provenance chaincode contract;
this is an additional member organization and application route, not a new
per-organization chaincode or a second portal.

1. **Inventory and design:** enumerate current channel config, orderer and
   peer policies, persistent volume capacity, external secrets, namespaces,
   GitOps ownership, and exact image digests. Record what a third peer/MSP
   changes in quorum and endorsement policy. Define an explicit rollback that
   leaves the two existing orgs and their ledger intact.
2. **Identity and channel:** issue unique MagneticArchMSP CA material and
   registrar/admin/client identities. Add its organization definition through
   the channel-config update process; verify signatures and a peer joining
   the channel. Do not repurpose NSG or Citizen Science certs or simply set
   a third name in an environment variable.
3. **Chaincode lifecycle:** package the tested three-MSP chaincode and run
   install/approve/commit at a new sequence where required. Confirm the live
   definition and endorsement policy on all three peers before accepting
   submissions. Back up channel/config evidence and pin package IDs/digests.
4. **GitOps services:** extend `platform/scripts/patch_fabric_network.py`,
   the AWS Fabric peer topology, `platform/gitops/aws/ledger-gateways.yaml`,
   `history-workers.yaml`, `submission-services.yaml`, `api-gateway.yaml`,
   `certificates.yaml`, secret providers, service accounts, and network
   policies for a third peer, bridge, and history worker. Keep bridge tokens
   internal and identities scoped to their own MSP. The Gateway's fixed org
   migration and public showcase routes then target these services.
5. **Verification and release:** stage GitOps diff in a nonproduction EKS
   environment, run topology validation and cross-org denial tests, seed the
   curator records once, verify each transaction ID against Fabric history,
   and run browser accessibility and responsive checks. Measure peer join,
   chaincode rollout, service deployment, and first confirmed write
   separately; present observed timings, not a speculative speed claim.
6. **Operations:** monitor channel/peer health, queue retries, pending and
   failed submissions, history read latency, storage, and certificate expiry.
   Keep the source dataset at Zenodo; only hashes/metadata and ledger proof
   belong in OSC. Document backup/restore and curator credential rotation.

The EKS plan is intentionally not an instruction to run Terraform, Argo CD,
AWS CLI, or any deployment now.
