# Local real-ledger portal run: 2026-09-26

## Scope and frozen sources

This was one isolated local run, not an AWS or production deployment. The
browser, Gateway, PostgreSQL, RabbitMQ, workers, bridges, two Fabric peers,
orderer, and `osc-provenance` chaincode ran in Docker on this workstation.
All submitted data were synthetic. No cloud resources or remote branches were
created or changed.

| Source | Exact commit |
| --- | --- |
| OSC-Network | `3ef0a24faf597afdfac21da97d50509f66b3a8ca` |
| OSC-Chaincode | `1d7d710485e5731e9489dc3df4fd5b0b18baaa0c` |
| OSC-Artifact-Submission | `12c465381d7cd2f61fbedab3fa7f9e1ba44d7c81` |
| OSC-APIGateway | `6cd6f45959d1a18b41c6da6afc6b6e97fbee6307` |
| Served OSC-WebApp | `8bf7b92c746c008ba86f5a22d7c97ba7a3462bbf` |
| Independent Cypress runner | `e4175c210d1a676059620ebd016d77df0077092c` |

The source-verifying preflight passed with all six exact revisions and clean
worktrees. The served WebApp was built from a separate clean checkout, leaving
the UX agent's worktree and its untracked Cypress downloads untouched.

## Results

- Live Fabric verification passed on both peers: channel members were
  `NSGMSP` and `CitizenScienceMSP`, and `osc-provenance` version 1.0 sequence 1
  was committed. The source Network repo was not edited; the test network was
  staged under ignored `.generated/test-network-live-2`.
- The real Cypress browser journey passed three times, once initially, once
  after service interruptions and recovery, and once after an exact NSG peer
  restart on the final Gateway image. Each passing run created an artifact,
  two edits, and a workflow for each organization, then checked public Fabric
  history and cross-organization denial. No tests were skipped in those runs.
- Newman `guest-boundary.postman_collection.json` passed 6/6 on the final
  Gateway: health, open status, both catalogs, wrong-Origin 403, and no-cookie
  create 401. Separate signed-in API sanity checks returned 201 for login and
  200 for token validation and protected artifact listing.
- The most recent NSG artifact `f59f56b6-0c98-4482-bb25-5fef97a848ac` and
  Citizen Science artifact `d0087f55-03d9-44b5-b2b7-4bbd7958b537` were
  `SUCCESS`; each public history returned three revisions with distinct
  Fabric transaction IDs. The matching workflows
  `efc11592-480f-480f-91a4-2e0989d9b496` (NSG) and
  `486492f5-8acf-4bba-9c59-2046341a45a0` (Citizen Science) were `SUCCESS`;
  each public history returned one Fabric transaction. The PostgreSQL outbox
  had 25 published and zero pending messages at final inspection.
- RabbitMQ, Gateway, and NSG history worker were each stopped and restored
  sequentially; their health returned. The NSG Fabric peer was stopped for
  three seconds, restarted, passed live Fabric verification, and the browser
  journey passed again. Latest observed free host memory was 24.47 GiB.

## Findings and limits

1. PostgreSQL outage caused the Gateway to exit after a connection-resolution
   error. PostgreSQL recovered, but the Gateway needed an explicit scoped
   restart. The sequential fault script aborted before writing its JSON record
   or reaching the peer step; the peer was tested manually afterward. This is
   **not** evidence of automatic Gateway recovery or exactly-once failure
   handling. Add restart policy/reconnection handling and rerun a bounded
   fault suite before claiming either.
2. An early bridge run failed when Docker Desktop could not bind-mount deep
   WSL-generated certificate paths. Copies under the shallow ignored
   `.generated` directory fixed the mount and the later complete journeys
   passed. The failed synthetic record remains in the disposable database.
3. Extending the demo initially moved `opensAt` forward, hiding earlier
   records from the public catalog. `Open-LocalDemo.ps1` now preserves the
   opening time for the same run. The current run was restored to
   `2026-09-27T03:40:00Z`; the latest artifact histories were rechecked and
   returned three revisions each. Do not reopen this run under a new ID.
4. The disposable database needed the existing synthetic organization/user
   seed applied manually after migration. Blank-VM bring-up is therefore not
   yet a single unattended command. The local test does not establish EKS,
   cloud cost, availability, or security properties.

## Open demo handoff

At final check, run `local-real-ledger-20260926204128` was `OPEN` at
`http://localhost:18088/` (API `http://localhost:13388/api/v1/`). Its window
closes at **2026-09-28 04:06:18 UTC** (September 27, 9:06pm PDT).
The app Compose project `osc-is-real-ledger-e2e` had ten running containers;
Fabric project `osc-is-fabric-e2e` had the orderer and two peers running.
This is a local laptop demo, not a durable hosted endpoint. Fernando can
visit the home page, both public catalogs, and the artifact/workflow history
links. Manual contributions are synthetic and should not include personal data.

To extend this same run from `real-ledger-tests`, set the disposable
`LOCAL_CONTROL_KEY` from the ignored `.generated/local-staged.env` in the
current process, then run:

```powershell
./Open-LocalDemo.ps1 -RunId local-real-ledger-20260926204128 -Hours 24
```

To stop the app stack without deleting its volumes, from `real-ledger-tests`:

```powershell
docker compose --env-file .generated/local-staged.env -f compose.yaml down
```

Then stop only the three known Fabric containers, if no further local test
needs them: `docker stop peer0.org1.example.com peer0.org2.example.com
orderer.example.com`. Do not run the sample `network.sh down`; it has broad
Fabric cleanup behavior. These stop commands were documented, **not run**, so
the manual demo remains available.
