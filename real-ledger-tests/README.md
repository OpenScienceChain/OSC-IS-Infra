# Local real-ledger portal verification

The in-progress three-organization Magnetic Arch showcase is described in
`MAGNETIC-ARCH-SHOWCASE.md`. The two-organization revision pins and commands
below document the previous run and must not be treated as a validated
three-organization bring-up.

This harness is for the restored guest portal. It is not the `ui-tests` HTTP
simulator or the `system-tests` mock ledger. The target topology is one WebApp,
Gateway, PostgreSQL, RabbitMQ, worker/listener, two history workers, two Fabric
gateways, and a two-organization `OSC-Network/test-network` running the current
`OSC-Chaincode` `ProvenanceContract`. No AWS service is part of this test.

## Frozen inputs and stop gate

The unified WebApp checkout is `8bf7b92c746c008ba86f5a22d7c97ba7a3462bbf`
on the familiar `56429d1` portal base. The local chaincode candidate is
`1d7d710485e5731e9489dc3df4fd5b0b18baaa0c`. The Gateway checkout used
for the 2026-09-26 run is `6cd6f45959d1a18b41c6da6afc6b6e97fbee6307`.
The independent Cypress runner is the separate
`OSC-WebApp-live-e2e-prep-20260923` worktree at
`e4175c210d1a676059620ebd016d77df0077092c`; it serves no application
code. Record all final revisions in run evidence. Guest UI routes are `/`, `/list-artifacts`, `/contribute`,
`/create-workflow`, and `/artifacts/:id/history`; `/api/v1/demo` is the
internal Gateway API, not a second user site.

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
Linux Go 1.26.7 is staged in the ignored `.generated/go1.26.7` directory from
the already-cached chaincode Dockerfile image digest
`sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468`.
The copy was made with `--pull never --network none` and verified with
`GOTOOLCHAIN=local` in WSL. Pass its absolute WSL `/mnt/c/.../bin/go` path to
`Test-Preflight.ps1 -LinuxGoExecutable`, and put its `bin` first on `PATH`
when invoking `network.sh`. Do not allow an implicit Go toolchain download.

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

1. Freeze and record exact Gateway, WebApp, E2E runner, Submission, Chaincode,
   and Network commits. Pass all six SHAs as the `-ExpectedRevisions` hashtable
   to `Test-Preflight.ps1 -VerifySources` and require clean source worktrees.
   Confirm the Gateway includes the rich create/edit contract and UX
   includes the matching browser forms. Do not substitute this folder's older
   checked-in WebApp/Gateway paths silently.
2. Stage the tracked sample network with `Stage-Network.ps1 -ToolsRoot
   <reviewed-Fabric-tools-dir>`, where that directory contains pinned `bin` and
   `config`. Use a new `-Destination` if a previous generated copy exists; the
   staging script refuses to overwrite it.
3. Run `Test-Preflight.ps1 -GeneratedNetwork <staged-test-network>
   -ExpectedRevisions <six-SHA-hashtable> -RequireReady`. Inspect the entire generated diff for the two MSP renames
   and Fabric image digests. A static pass is **not** proof that generated
   certificates or the deployed channel use those MSPs.
4. From the generated test-network directory, with
   `COMPOSE_PROJECT_NAME=osc-is-fabric-e2e`, run `bash ./network.sh up
   createChannel -c osc-channel` and then `bash ./network.sh deployCC -c
   osc-channel -ccn osc-provenance -ccp <absolute-frozen-chaincode-go-dir>
   -ccl go`. Check the live channel MSPs and committed chaincode definition on
   both peers with `bash Verify-LiveFabric.sh <generated-test-network>` before
   proceeding. Do not use `network.sh down` for teardown.
5. Use `New-LocalEnv.ps1 -GeneratedNetwork <staged-test-network>` to create
   ignored `.generated/local.env` with exact checkout paths, reviewed image
   digests, generated Fabric identity files, and disposable local-only secrets.
   It refuses to overwrite an existing run file. Re-run
   `Test-Preflight.ps1 -ExpectedRevisions <six-SHA-hashtable> -VerifySources`
   immediately before app build. Use `docker compose --env-file
   .generated/local.env -f compose.yaml config --quiet` before build. Then start
   exactly this Compose project with `docker compose --env-file
   .generated/local.env -f compose.yaml up
   --build --detach --wait`. The intended browser URL is
   `http://localhost:18088/`, API `http://localhost:13388/api/v1/`.
6. Run `Open-LocalDemo.ps1` with the disposable `LOCAL_CONTROL_KEY` read from
   `.generated/local.env` into the process environment. It uses only localhost, a unique local
   `runId`, state `OPEN`, and a short explicit window. This is local state only.
   When extending an existing run, pass the same `-RunId`; the script retains
   its original opening time so earlier confirmed records remain visible.
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
TypeScript validation. The 2026-09-26 live run and its limitations are recorded
in `RUN-EVIDENCE-2026-09-26.md`; a new run must record its own output, resource
usage, revision hashes, and teardown instructions. The source `network.sh` has global
cleanup behavior, so the operator must perform project-scoped teardown and
account for peer-spawned chaincode containers by exact ID. Never run a broad
Docker prune or label-only container deletion.
