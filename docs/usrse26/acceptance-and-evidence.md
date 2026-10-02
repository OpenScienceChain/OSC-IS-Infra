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

## Protected UX export gate

Lifecycle `EXPORT` must collect all three protected API responses over the
existing in-pod loopback transport using the pod's `DEMO_CONTROL_API_KEY`:

| Endpoint | Control-bucket object under `evidence/<run-id>/` | Classification |
|---|---|---|
| `/api/v1/demo/internal/export` | `sanitized-export.json` | Legacy counters and survey only |
| `/api/v1/demo/internal/ux-metrics` | `restricted/ux-metrics.json` | Restricted UX aggregates |
| `/api/v1/demo/internal/ux-feedback/comments` | `restricted/ux-feedback-comments.json` | Restricted anonymous free text from `demo_ux_feedback` |

The legacy survey is not the new UX survey. Missing endpoints, authentication
failure, malformed JSON, unexpected fields, invalid types or buckets, missing
public-access protection, or failed uploads make the export fail closed. All
responses are validated before any upload. Errors contain no response body,
comment, control key, or underlying CLI exception. Redirects are rejected; no
protected request uses the public URL or a guest session.

The destination must be the exact run's
`osc-usrse26-<run-id>-control-269624229733` bucket, distinct from `STATUS_BUCKET`,
with all four S3 public-access-block settings true at collection time. The
runner has only exact-control-bucket permission to read these settings. Objects
use the existing AES256 encrypted upload path. The control bucket is not a
CloudFront origin; never copy these objects into the edge/status bucket, a
public repository, slide deck, public run directory, build log, or attachment.
The runner's temporary workspace is private (directory mode 0700); treat it as
restricted too. Do not enable command tracing or log captured stdout.

Each response has a companion `.checksum.json` covering the exact canonical
UTF-8 JSON bytes, including the final newline. `export-complete.json` is written
last and lists the three object keys and SHA-256 digests. Acceptance requires
verifying **all three retained objects against that manifest**, not just the
presence of a completion object or a legacy checksum. A failed retry may leave
old objects or an old completion manifest; a mixed set must fail digest
verification. A failure after some uploads leaves incomplete restricted
evidence, not permission to publish it. Teardown still proceeds through the
existing export-failure notification path; export failure does not justify
keeping a runtime alive.

UX metrics cover the API's last 30 days, potentially multiple runs and phases;
the path's run ID identifies the collection run, not a filter on the report.
Retain phase/run groupings, `truncated`, scope, and caveats. Optional rating and
automation-interest answers can have fewer responses than submissions. Consent
actions are not people or total visitors; client-reported completion is not
ledger confirmation. Compare ledger outcomes to protected operational metrics.

Anonymous comments are **not sanitized**: participants can include identifiers,
PII, or secrets in the 300-character free text. Schema validation rejects extra
identity fields but cannot make the text safe. Only authorized operators may
inspect the protected comment object. A release owner must approve a separately
redacted, small-cell-reviewed derivative before publication; the completion
manifest explicitly sets `publicReleaseApproved` to false. Do not include raw
comments or exact comment timestamps in that derivative.

The API retains UX data for 30 days. The existing control-bucket evidence rule
expires current objects 30 days after upload and noncurrent versions after
7 days; S3 expiry is asynchronous, not a guarantee of deletion precisely on
the API's source expiry date. Re-exporting restarts the object-age clock.
Operators must review source age and arrange earlier deletion of all versions
when required by the research retention policy; do not repeatedly export to
extend retention. Control-plane teardown force-deletes the bucket. No retention,
live endpoint, bucket protection, or AWS execution has been demonstrated by
local mocked unit tests alone.

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

