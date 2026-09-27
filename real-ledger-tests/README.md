# Local real-ledger portal verification

This harness is for the restored guest portal. It is not the `ui-tests` HTTP
simulator or the `system-tests` mock ledger. The target topology is one WebApp,
Gateway, PostgreSQL, RabbitMQ, worker/listener, two history workers, two Fabric
gateways, and a two-organization `OSC-Network/test-network` running the current
`OSC-Chaincode` `ProvenanceContract`. No AWS service is part of this test.

## Frozen inputs and stop gate

The guest API contract is `OSC-APIGateway/docs/demo-guest-portal-contract.md`
at `e87f4bd18ab0570526c24f0a16eec438df2cba4c`; the existing baseline is
`56d7f5de662b5fff6f0cf32e136ae2ac320c7910`. The local chaincode candidate
is `1d7d710485e5731e9489dc3df4fd5b0b18baaa0c`. Record the final Gateway,
WebApp, Submission, Network, and Infra revisions in the run evidence before
testing. Do not run the full stack until the Gateway and UX owners freeze their
implementations and the control owner signals readiness.

`OSC-Network/test-network` is a useful real Fabric fixture, but its checked-in
config creates `Org1MSP` and `Org2MSP`. The current provenance chaincode and
ledger gateways accept **only** `NSGMSP` and `CitizenScienceMSP`. Running the
network unchanged cannot validate the product. The test-network inputs must be
copied into a disposable generated directory and customized consistently
(channel config, peer MSP env, CLI env, deployment scripts, certificate paths),
then checked before startup. Never edit the Network repo in place or weaken the
chaincode's MSP check just to get a green test. `Stage-Network.ps1` copies only
tracked test-network files and substitutes the two MSP IDs in a disposable
directory and pins Fabric images from `platform/versions.env`;
`Test-Preflight.ps1` fails closed until that generated network is supplied and
verified. Fabric binaries/config must be supplied from a reviewed,
version-pinned tool cache via `-ToolsRoot`; staging does not download them.

On this workstation, the verified `ToolsRoot` is
`C:\Users\ofgar\Projects\GithubProjects\OSC-IS\.codex-interactive-demo-worktrees\OSC-IS-Infra\.osc-tools\fabric-2.5.16-1.5.22`.
Its Fabric 2.5.16 and CA 1.5.22 archives match the SHA-256 values in
`platform/versions.env`; extracted `peer`, `cryptogen`, `configtxgen`,
`fabric-ca-client`, `core.yaml`, and `configtx.yaml` matched archive members
byte-for-byte on 2026-09-26. This path belongs to another local Infra worktree:
read/copy it, but do not mutate that worktree. Reverify if the cache changes.

## Test matrix

| ID | Journey / interruption | Oracle |
| --- | --- | --- |
| B1 | Public home, status, both org catalogs | No auth; accurate state; current-run public records only |
| B2 | NSG guest session, artifact create | Exact Origin + secure cookie + CSRF; accepted then ledger-confirmed |
| B3 | Citizen Science guest session, artifact create | Separate organization and MSP; no cross-org mutation |
| B4 | Each guest creates workflow linking own artifact | Confirmed workflow has transaction ID and per-org history |
| B5 | Each guest edits own confirmed artifact twice | Each unique revision appears in Fabric-backed public history |
| B6 | Same request ID retry / changed-payload retry | Same result / conflict; no duplicate ledger revision |
| B7 | Cross-session/org edit, expired cookie, wrong Origin/CSRF | Denied without new outbox or Fabric transaction |
| B8 | Read-only and seeded records | Public reads/history work; writes stop; seed resumable, exactly once per run |
| B9 | History privacy | Revision-specific fields only; no token, email, actor ID, raw ledger or file bytes |
| F1 | Stop RabbitMQ, then restore | Writes fail/retry deterministically; no silent success or duplicate commit |
| F2 | Stop Gateway, then restore | Browser/API show bounded error; existing confirmed ledger data survives |
| F3 | Stop history worker / Fabric peer, then restore | Provenance unavailable is explicit; database is not substituted as ledger proof |
| F4 | Stop PostgreSQL, then restore | Session/mutation unavailable; confirmed ledger persists; recovery checked |
| F5 | Stop worker/listener, then restore | Pending status remains truthful; exactly one eventual confirmation |

Run fault cases **sequentially**, one component at a time, and restore it
before the next. Record correlation ID, API status, outbox count, queue depth,
Fabric transaction ID/history, and recovery time. A 200 from the WebApp alone
is never the oracle for B2-B5 or F1-F5. The test data are synthetic and public.

## Resource and teardown rules

Use only one local stack. Before starting, inspect Docker projects, fixed
Fabric container names, ports, available memory, and source revisions. Refuse
to start alongside a second OSC demo/Fabric stack or with insufficient memory.
Keep the verified portal running for manual inspection only after all fault
cases are restored. Provide its exact localhost URL, container inventory, and
the exact stop command. Teardown must use project-scoped Compose resources;
do **not** call `network.sh down`, whose `clearContainers` removes every Docker
container carrying `service=hyperledger-fabric`, including unrelated ones.

## Manual preflight

From this directory, run `pwsh ./Test-Preflight.ps1 -OscIsRoot <absolute-root>`.
It is read-only and does not pull images, build, start, or stop containers.
Until the generated network has the expected MSPs, its nonzero exit is the
intended result. The operator should not override this gate with simulation.

## Bring-up after owner readiness

1. Freeze and record exact Gateway, WebApp, Submission, Chaincode, and Network
   commits. Confirm the Gateway includes the rich create/edit contract and UX
   includes the matching browser forms. Do not substitute this folder's older
   checked-in WebApp/Gateway paths silently.
2. Stage the tracked sample network with `Stage-Network.ps1 -ToolsRoot
   <reviewed-Fabric-tools-dir>`, where that directory contains pinned `bin` and
   `config`. Use a new `-Destination` if a previous generated copy exists; the
   staging script refuses to overwrite it.
3. Run `Test-Preflight.ps1 -GeneratedNetwork <staged-test-network>
   -RequireReady`. Inspect the entire generated diff for the two MSP renames
   and Fabric image digests. A static pass is **not** proof that generated
   certificates or the deployed channel use those MSPs.
4. From the generated test-network directory, with
   `COMPOSE_PROJECT_NAME=osc-is-fabric-e2e`, run `bash ./network.sh up
   createChannel -c osc-channel` and then `bash ./network.sh deployCC -c
   osc-channel -ccn osc-provenance -ccp <absolute-frozen-chaincode-go-dir>
   -ccl go`. Check the live channel MSPs and committed chaincode definition on
   both peers with `bash Verify-LiveFabric.sh <generated-test-network>` before
   proceeding. Do not use `network.sh down` for teardown.
5. Set the required variables named in `compose.yaml` to exact frozen checkout
   paths, reviewed Postgres/RabbitMQ image digests, generated Fabric client
   cert/key and peer TLS CA files, and disposable local-only secrets. Use
   `docker compose -f compose.yaml config --quiet` before build. Then start
   exactly this Compose project with `docker compose -f compose.yaml up
   --build --detach --wait`. The intended browser URL is
   `http://localhost:18088/`, API `http://localhost:13388/api/v1/`.
6. Run `Open-LocalDemo.ps1` with the disposable `LOCAL_CONTROL_KEY` already
   present in the process environment. It uses only localhost, a unique local
   `runId`, state `OPEN`, and a short explicit window. This is local state only.
7. Run `newman run guest-boundary.postman_collection.json` from this directory
   for public/read-only and denial checks. Its default target is localhost;
   never override `baseUrl` to a shared or cloud environment. It does not
   claim to have exercised Fabric writes.
8. From the E2E WebApp worktree, use the existing local Cypress binary with
   `--config baseUrl=http://localhost:18088 --expose
   LOCAL_REAL_LEDGER=true --spec cypress/e2e/demo/local-real-ledger.cy.ts`.
   The spec is inert without the opt-in and exact localhost URL. Run the
   browser/UI spec and accessibility checks separately after the API journey.
9. Only after a clean happy path, run `Test-SequentialFaults.ps1
   -ConfirmLocalFaults` and optionally `-IncludeFabricPeer`. It restores each
   exact service in `finally`, checks health, and writes a local JSON record.
   It is **not** a queue-integrity or exactly-once assertion: run the API and
   Cypress provenance checks again and inspect outbox/queue counts before
   accepting F1-F5. Never run these interruptions on a shared stack.

Do not infer that the live Fabric deployment is sound from static Compose or
TypeScript validation. This checkpoint has **not** run the full stack, Newman,
Cypress, or fault tests. The final run must record output, resource usage,
revision hashes, and teardown instructions. The source `network.sh` has global
cleanup behavior, so the operator must perform project-scoped teardown and
account for peer-spawned chaincode containers by exact ID. Never run a broad
Docker prune or label-only container deletion.
