# Acceptance and Evidence Contract

## Reference scenario

1. An authenticated NSG submitter creates a private artifact.
2. The API Gateway derives NSG from the active membership, persists the request,
   and publishes it through the outbox.
3. A submission worker consumes the durable command and calls the NSG Ledger
   Gateway identity.
4. The provenance contract validates `NSGMSP`, writes deterministic metadata,
   and emits a lifecycle event.
5. The listener updates application state idempotently.
6. An authorized NSG user retrieves the artifact and its history.
7. A Citizen Science user is denied private NSG mutation and history access.
8. A controlled worker or peer interruption is introduced; processing recovers
   without losing or duplicating the committed operation.

The same scenario is run locally first and then, if all gates pass, once in the
ephemeral AWS environment.

## Evidence levels

| Level | Meaning |
|---|---|
| Implemented | Code and configuration exist and received static review. |
| Locally validated | The behavior passed in the isolated local environment. |
| AWS demonstrated | The behavior passed in the disposable AWS run. |
| Proposed | Design is documented but not implemented or executed. |
| Not tested | No acceptable evidence exists. |

## Initial claim matrix

| Claim | Required evidence | Initial level |
|---|---|---|
| OSC-IS separates portal IAM from ledger invariants | auth ADR, focused contract diff, negative tests | Proposed |
| Two organizations are isolated across API and ledger boundaries | membership tests and cross-org transaction denial | Proposed |
| Provenance operations retain deterministic history and request attribution | transaction IDs, history output, metadata assertions | Proposed |
| Event processing survives a temporary worker or peer failure | queue state and recovery timing | Proposed |
| GitOps detects drift and supports controlled rollback | Argo state, revisions, digest, timing | Proposed |
| The deployment is reproducible from reviewed source and immutable artifacts | source manifest, image digests, SBOMs, clean rebuild | Proposed |
| The AWS experiment has a plan-approved estimate and bounded disposable exposure | planning estimate, timestamps, schedules, tagged inventory, destroy proof | Proposed |
| OSC-IS is production-ready | prohibited claim | Not tested |
| Researchers have adopted OSC-IS or experienced measured improvement | prohibited claim | Not tested |

## Run directory contract

Each `platform-evidence/<run-id>/` directory must contain:

- `README.md`: purpose, environment, start/end UTC, operator, limitations.
- `source-revisions.json`: repository and immutable image revisions.
- `versions.txt`: sanitized tool and platform versions.
- `tests/`: machine-readable and concise human-readable results.
- `gitops/`: sync, drift, rollout, rollback state and timings.
- `fabric/`: sanitized transaction, event, denial, and history evidence.
- `resilience/`: injected fault, expected behavior, recovery timing.
- `aws/`: account number only, region, plan summary, planning estimate,
  bounded-exposure controls, tagged inventory, teardown proof, and an actual
  billed-cost field that remains `NOT_RECONCILED` unless a human supplies a
  CloudBank or account billing record. Do not record IAM user IDs or
  secret-bearing ARNs.
- `checksums.sha256`: integrity manifest for retained evidence.
- `claim-matrix.md`: final status of every claim.

## Stop conditions

Stop before AWS apply when any of these is true:

- STS account is not `269624229733`.
- The reviewed pre-deployment planning estimate is absent, non-concrete, or
  exceeds the USD 200 planning-estimate ceiling.
- The 72-hour deadline, fixed capacity, primary stop, independent backup stop,
  teardown authorization, exact-tag sweep, or zero-inventory proof is absent or
  inconsistent.
- Terraform plans to change an untagged or pre-existing resource.
- A required secret must be placed in source, state input, an image, or evidence.
- Local provenance, authorization, recovery, GitOps, or teardown gates fail.
- The environment cannot be destroyed in the same work session.

