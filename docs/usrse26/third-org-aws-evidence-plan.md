# Two-to-three-organization AWS evidence run

Status: reviewed 2026-09-29; catalog integration complete; AWS launch gated.
Target handoff:
2026-09-30 08:00 America/Los_Angeles. The review found no existing
incremental AWS add-org3 operation or unattended teardown in the simple run.
Neither is assumed below.

## Current checkpoint (2026-09-29 17:33 PDT)

- Phase 1 is implemented in WebApp commit `35598e5`, pushed on
  `feature/magnetic-arch-showcase`. The local `localhost:18088` service and
  three-organization Docker/Fabric stack are healthy. Focused unit tests,
  production build, and desktop/mobile live Playwright/Axe checks passed.
- The AWS account currently has no EKS cluster in `us-west-2`. The existing
  `usrse26m1` and `usrse26r1` lifecycle state machines belong to earlier
  experiments; there is no active EventBridge Scheduler schedule for this run.
- The simple AWS run has only a manual destroy command. No tested automatic
  primary or independent backup teardown exists for this run. The EKS
  two-to-three-organization operation and local rehearsal are also incomplete.
  Do not launch a billable overnight EKS runtime until these gates pass.

2026-09-29 operator direction: leave AWS available overnight for the morning
session. This explicitly changes the earlier eight-hour/same-session experiment
assumption. The run may use that exception only after a tested automatic stop
and independent backup stop are installed, with a planned end no later than
2026-09-30 10:00 PDT. If those controls cannot be proven, do not launch an
overnight runtime; report the blocker and continue local preparation.

## Purpose and claim boundary

Demonstrate a disposable EKS deployment beginning with Neuroscience Gateway and
Citizen Science, then time the addition of Magnetic Arch Plasma Showcase as a
third Fabric organization. Show application GitOps separately from Fabric
onboarding, and retain reproducible, sanitized evidence for the presentation.
One timed onboarding run is a case study, not a latency benchmark. File bytes
are never submitted to OSC; source citations, hashes, metadata, and ledger
transactions are the evidence.

## Ownership and starting point

- Release owner: this chat. One writer per worktree. The named review chat
  reviews this plan read-only before implementation.
- Source branch in all five repositories: `feature/magnetic-arch-showcase`.
  Freeze exact commits, image digests, and GitOps revision before AWS apply.
- Keep the local `localhost:18088` showcase available. Do not infer AWS
  readiness from its three-org Docker/Fabric configuration.
- AWS boundary: profile `default`, account `269624229733`, region `us-west-2`,
  exact tagged run ID, guarded Terraform plan, no pre-existing resources
  modified. The existing $200 plan ceiling and $150 read-only/teardown threshold
  remain hard stops. Recalculate the current run estimate before apply.
- The experimental EKS runtime must have a bounded expiry and a verified
  teardown path. An expiry timestamp is not automated teardown. For this
  user-authorized overnight exception, install and test a primary stop plus
  an independent backup stop before apply. A local laptop scheduled task
  alone is not independent of power/connectivity. If the existing controlled
  AWS lifecycle cannot be configured and proven for this window, do not leave
  the simple run unattended.

## Phase 1: Catalog integration (local)

1. Make public `View all artifacts` and `View all workflows` use the general
   visibility-aware catalog rather than the demo-run contribution feed.
   Preserve organization access, ownership, search, pagination, and detail links.
   Demo lifecycle limits must still apply to demo-only contribution operations.
2. Test signed-out and signed-in views. The eight curated research artifacts
   (five Magnetic Arch, one EEG, two Serengeti) and three linked workflows
   must be discoverable without making private records public. Check empty,
   pending/failed, pagination, and mobile/keyboard/accessibility states. Test
   anonymous -> org A -> sign-out -> org B transitions so cached listings
   never leak private records or remain stale across identities.
3. Run focused unit/component tests and live browser tests against `18088`.
   Commit a clean checkpoint and record the exact WebApp/Gateway revisions.

## Phase 2: Third-org readiness (local first)

1. Implement a versioned, idempotent `add-org3` command and runbook. The EKS
   bootstrap currently only deploys Org1/Org2, and the app manifests only
   define two ledger gateways/history workers. The addition needs peer/CA
   identity, channel config update and join, chaincode package/install/approval
   and service, identity upload, third-org gateway/history worker, routing,
   IAM/secrets, network policy, API membership, rollback, and evidence probes.
   Fabric bootstrap remains outside Argo CD; app workloads remain inside it.
   Do not replace the two-org baseline with a three-org cold start.
2. Rehearse that sequence in an isolated local Kubernetes environment. Start
   with two organizations, add the third without restarting or replacing the
   first two, and prove a new Magnetic Arch transaction/history plus continued
   NSG/Citizen Science operations and cross-org denials. Do not claim an AWS
   onboarding time if this gate fails.
3. Prepare immutable, scanned images and a reviewed release manifest for the
   exact frozen revisions. Pre-provision dormant third-org IAM/secrets/capacity
   in the reviewed initial Terraform plan, or review a second saved add-org
   plan before baseline apply. Never improvise Terraform during timing. Run
   static checks and the existing local E2E gates.
4. Build and validate an AWS-specific sanitized Postman collection locally.
   The existing guest-boundary collection explicitly forbids AWS. Store
   credentials in an ignored environment, poll confirmation with bounded time,
   assert transaction/history and negative cross-org responses, and export
   machine-readable results. Prepare localhost-only Argo/API port-forward
   scripts with PID/log ownership, health checks, and restart instructions.

## Phase 3: Disposable AWS run

1. Record STS account, operator CIDR, baseline inventory, current cost estimate,
   image digests, Terraform plan, expiry, and teardown command. Reject plans
   touching untagged/pre-existing resources or exposing Argo/Fabric/admin
   services publicly. Apply only the saved guarded plan.
2. Deploy two-org EKS/Fabric and OSC application. Verify Argo `Synced/Healthy`,
   both org paths, ledger confirmations/history, and a sanitized Postman smoke
   result. Capture baseline UTC timestamps and screenshots.
3. At a recorded start timestamp, add the third org using the rehearsed steps.
   At each stage record: Fabric channel membership/peer readiness, chaincode
   readiness, Argo-managed app rollout, API account/org visibility, first
   confirmed artifact and workflow, and first readable history. Define the
   end timestamp as the last of these required ready checks. Keep timestamps
   and individual phase durations; do not call pod creation alone "deployed."
4. Use Chrome through a private `kubectl port-forward` to capture Argo CD
   application tree and sync/health before and after, plus any rollout/rollback
   test. Argo proves reconciliation of application manifests only. Corroborate
   Fabric onboarding with channel/peer evidence and API/ledger responses.
   Sanitize screenshots: no tokens, secrets, private keys, or account details.
5. Use the prepared Postman environment with the private forwarded API base URL
   and credentials stored outside the repository. Run a bounded collection for
   public reads, three-org submission/history, existing-org regression, and
   forbidden cross-org update/history. Retain sanitized collection results,
   transaction IDs, UTC timestamps, and exact source/image revisions.

## Morning handoff and shutdown

By 2026-09-30 08:00 PDT, provide the user a status: private endpoint/access
method if safely active, Chrome/Argo evidence paths, measured timings with
start/end definitions if achieved, replayable Postman results/instructions, and
any failed gate. Keep the guarded runtime available only through the morning
window; automatic primary teardown is planned for 10:00 PDT with an independent
backup stop afterward. Verify baseline inventory parity and zero tagged
runtime resources. If any gate prevents an overnight run, provide the completed
local work and the exact AWS blocker; do not imply an AWS endpoint is waiting.
Retain sanitized evidence
under `docs/usrse26/platform-evidence/<run-id>/` with checksums, cost estimate,
limitations, and teardown proof. Never represent an incomplete run as success.

## Stop / escalation gates

- Wrong AWS account/region, changed operator CIDR, unexpected Terraform plan,
  unavailable credentials, secret exposure, missing rollback/teardown path,
  unreviewed mutable image, failed local third-org rehearsal, or unresolved
  cross-org authorization defect: stop before apply or transition to teardown.
- If the two-org baseline is healthy but the third-org addition fails, preserve
  the failure evidence, do not improvise a broader cloud change, and teardown.
- If the user cannot reach the private endpoint at the morning handoff, give
  exact recovery steps; do not make Argo or the API public for convenience.

## Evidence schema and limits

Add a three-org row to the claim matrix before AWS execution. Record a
machine-readable UTC timeline with `baselineReadyAt`, `additionStartedAt`,
`fabricJoinedAt`, `chaincodeReadyAt`, `applicationReadyAt`,
`firstArtifactConfirmedAt`, `firstWorkflowConfirmedAt`, and
`firstHistoryReadAt`, each with probe command/result and exact revision. The
end of onboarding is the latest required ready timestamp. Keep the earlier
two-org recovery/failover claim at its previously validated level unless the
three-org run actually repeats it.
