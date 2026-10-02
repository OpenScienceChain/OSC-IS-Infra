# Correlated Provenance Trace Report

## Result

PASS. The remediated OSC-IS revisions were deployed into a disposable local Kind cluster with a real two-organization Hyperledger Fabric network. One retained NSG artifact was followed across the API, PostgreSQL transactional outbox, RabbitMQ command, submission worker, organization-scoped Ledger Gateway, Fabric transaction, RabbitMQ completion event, submission listener, and final API state.

The retained trace uses correlation ID `usrse26-e2e-20260902-local-003`, artifact ID `44050742-a9b8-4c5e-9a82-b088f2d7c83a`, and Fabric transaction ID `da988e11e1ffd1bd5b724f876fee86ffe19b3dee995dddbd4e8580214608ca25` throughout. Fabric history contains exactly one revision. No duplicate ledger revision was observed.

## Trace Evidence

| Boundary | Evidence and link quality | Correlated value |
| --- | --- | --- |
| Authenticated NSG API request | Direct: `api-boundaries.json` | Correlation and artifact IDs |
| PostgreSQL artifact plus transactional outbox | Direct: `database-outbox.json` | Artifact, outbox, correlation, published state, zero retries |
| RabbitMQ `artifact.submit` | Direct: `rabbitmq-boundaries.json` | Audit-queue copy of the real command |
| Worker to NSG Ledger Gateway | Bounded inference: `rabbitmq-boundaries.json` | Correlated completion event carries the Fabric transaction returned by the organization path |
| Fabric commit and chaincode state | Direct: `fabric-history.json` | Transaction, artifact, NSG MSP, correlation, revision 1 |
| RabbitMQ `artifact.submitted` | Direct: `rabbitmq-boundaries.json` | Audit-queue copy of the real completion |
| Listener and final API state | Bounded inference: `api-boundaries.json`, `queue-depths-after.json` | Final API success/transaction state plus an empty completion queue |

`trace-manifest.json` is the machine-readable index. `checksums.sha256` covers the seven primary trace files. The RabbitMQ observer used an exclusive, auto-delete queue and retained only identifiers and routing metadata; it did not alter production queues or message acknowledgement.

## Authorization

The artifact belongs to **nEUROSCIENCE GATEWAY** (`NSGMSP`). A **CITIZEN SCIENCE** user was denied access through the API with HTTP 403. The Citizen Science Fabric identity was independently denied the same history through its organization-scoped Ledger Gateway with HTTP 403. This proves both application-layer tenancy enforcement and chaincode-layer organization isolation for the retained record.

## Reconciliation And Recovery

The application manifests were applied twice. SHA-256 hashes over the canonicalized `.data` of all seven application credential Secrets were unchanged, and `platform/.generated/runtime-secrets` was absent after both runs. Only hashes are retained in `secret-reconciliation-hashes.json`.

The broader recovery suite passed controlled outages of the NSG Ledger Gateway, RabbitMQ, and the primary Fabric peer. All recovered artifacts reached `SUCCESS` with one ledger revision, the RabbitMQ outbox changed from pending to published after recovery, and no duplicate ledger writes were observed.

Argo CD then detected and self-healed replica drift, applied a controlled rollout, and restored the known-good immutable API image during rollback. Detailed summaries are under `integrated/`.

## Source And Build Integrity

`source-revisions.json` records all five exact remediated source revisions and the five immutable local image digests. npm images used lockfile scanning, `npm ci --ignore-scripts`, registry signature verification, and reviewed lifecycle rebuilds. Python services used hash-locked binary-only installation. The Fabric chaincode image came from the exact recorded Go revision.

No AWS environment was used. No repository was pushed. `OSC-API`, `OSC-Docker`, and `OSC-Network` were untouched.

## Harness Development Note

Two preliminary correlations were not retained as evidence. `...001` exposed an evidence-harness failure after submission. `...002` captured the full RabbitMQ path but revealed that Fabric history names its identifier `transactionId`, not `txId`. The final validator was corrected against the actual contract and rerun as `...003`. These preliminary records lived only in the disposable cluster and do not alter the retained artifact's verified single-revision history.

## Assessment

The local evidence is sufficient to validate the remediated asynchronous architecture and the narrow correlation defect without another AWS deployment. An AWS rerun would add environment parity and managed-service evidence, but it would not materially strengthen the proof that correlation, outbox delivery, organization isolation, and single-write provenance now work end to end. Reuse AWS only when presentation evidence specifically requires managed EKS or Amazon MQ screenshots and operational timing.
