# USRSE26 Interactive Demo AWS Rehearsal Lessons

**Rehearsal window:** 2026-09-14–15 (UTC evidence timestamps; Pacific schedule times are called out explicitly)

**Authoritative Infra freeze:** `OSC-IS-Infra@35958ae2036bc0f82e1f3712a53508232aca53df`

**Run:** `usrse26r1`

**Account / region:** `269624229733` / `us-west-2`
**Disposition:** application rehearsal succeeded; scheduled unattended lifecycle did not; bounded operator recovery completed final teardown.

## Executive verdict

The rehearsal produced a usable application demonstration and a verified final
teardown. The successful CANARY build
`f8d02526-c94f-4258-8e91-cc70270e2ae4` completed at
`2026-09-15T02:38:29Z`; its durable evidence records an artifact transaction,
a workflow transaction, zero duplicate ledger revisions, and successful
cross-organization denial. The public browser rendered the OPEN state with no
console warnings or errors, and later rendered the CLOSED contribution-window
state at `2026-09-15T03:00:07Z`.

That is separate from lifecycle automation. The 01:00 Pacific safety schedule
fired at approximately `2026-09-15T08:00:46Z`, but the original STOP failed at
`08:18:21Z`; a bounded retry later failed with `RuntimeTeardownIncomplete` at
`09:45:56Z`. Operator recovery resumed around `15:34Z`. Final out-of-VPC
destroy build `48d829ca-38ab-495c-92cc-718c97a291ef` succeeded at
`15:46:01Z`, sweep `48a7647d-3c90-4f21-acda-c79c69a042d9` at
`15:47:06Z`, and independent inventory began at `15:47:17Z`. The fresh proof
is `DESTROYED_AND_VERIFIED`, with zero active residual resources.

**Fact:** application E2E behavior and final teardown succeeded.

**Fact:** scheduled unattended lifecycle did not succeed; operator recovery was required.
**Not established:** unattended readiness, production reliability, or any exact billed amount.

## Source and identity record

Primary sources, all relative to this repository at the frozen revision:

- `docs/usrse26/platform-evidence/20260911-usrse26r1/aws/LIVE-RESUME-STATUS-20260914.md` — chronological recovery, build IDs, IAM decisions, application results, and final narrative.
- `docs/usrse26/platform-evidence/20260911-usrse26r1/aws/RUNTIME-TEARDOWN-VERIFICATION-20260915.json` — structured final inventory, proof versions, timestamps, controls, retained-cost estimate, and limitations.
- `docs/usrse26/platform-evidence/20260911-usrse26r1/aws/` — retained topology, canary, cost, schedule, teardown, and manifest records.
- `C:\Users\ofgar\Projects\GithubProjects\OSC-IS\USRSE26-BRANCH-GOVERNANCE\INTERACTIVE-DEMO-STATUS.md` — public status and final control-plane handoff.

The deployed application source manifest (`source-revisions.json`) records:

| Repository | Deployed revision |
|---|---|
| OSC-IS-Infra | `ddc8cecff36347dc6d95ed915d4204bdfbd8b364` |
| OSC-WebApp | `f05c02da0579a4fb82bd6433c382147d6973e00d` |
| OSC-APIGateway | `2351746fad480bbe376e02da376a0864c59c1ad7` |
| OSC-Artifact-Submission | `12c465381d7cd2f61fbedab3fa7f9e1ba44d7c81` |
| OSC-Chaincode | `1d7d710485e5731e9489dc3df4fd5b0b18baaa0c` |

GitOps known-good and rollout revisions were respectively
`2fcbaf9b86c3df821422fe41c70951b96369866a` and
`0bf853599bec1ce8574ff758278f5f3500d26b01`. The evidence-owned worktree
itself is frozen at `35958ae`; these are execution-source identifiers, not a
claim that later recovery edits were part of the original deployment.

## Rehearsal facts and identifiers

The validated AWS topology was EKS 1.35 with three `m7i.large` nodes, 71
running pods, two Fabric organizations, three orderers, four peers, four
external chaincode services, and a three-broker private Amazon MQ RabbitMQ
4.2 `CLUSTER_MULTI_AZ` deployment. The retained snapshot labels this an
observed validation topology, not a capacity, scale, availability, or
production-topology claim (`aws/validated-topology.json`).

Application evidence includes:

- Canary artifact `872bd307-bef3-4958-8c2a-a28eb97edfb8`, transaction
  `df9672d0f76278d9157283d96f63c66519e09683cb6a3fa7684d9dfd30e3ead8` in the
  final canary narrative; workflow transaction
  `c847d31ab077f85c81af47d4524e234e95729725ed4754686c01f8b2549fc23d`.
- Earlier validation artifact `a40b8751-ba12-4e33-9467-6af602dd6d9f` reached
  two revisions; workflow `77676c9b-ea7f-4950-a4bf-726d92ac8276` reached one;
  all six authorization controls in `fabric/provenance-and-authorization.json`
  passed.
- Recovery summary: Ledger Gateway `71s`, RabbitMQ/worker `224s`, peer
  `5s`; each recovered to one ledger revision and no duplicate writes.
- GitOps summary: drift self-heal `156s`, rollout `21s`, rollback `20s`, with
  immutable images and post-rollback validation.
- Public edge: VPC origin `vo_JwlVpK48cN0CjiCEb544JZ`, CloudFront
  `E26XTII1H57RTX`, internal ALB
  `arn:aws:elasticloadbalancing:us-west-2:269624229733:loadbalancer/app/k8s-oscapps-oscdemoa-ce1b201649/d85b3eb88707d4cb`,
  and start-evidence build `92de6fd6-256e-45d3-b1eb-d11e22d9aa80`.

## Contribution-window and public-state timeline

At `2026-09-15T02:38:29Z`, the official canary was successful and public
`status.json` reported `OPEN`; health returned HTTP 200 and the browser showed
the organization controls and canary records without warnings or errors. At
`2026-09-15T03:00:07Z` (20:00 Pacific), a reload without mutation showed
`CLOSED`, removed contribution controls, and preserved public counters and
record browsing. This was a client/window boundary, not teardown. The final
state at `15:47:04Z` was `READ_ONLY`, `applicationUrl=null`; the static edge
remained HTTP 200 after runtime removal.

## Incident register

The table distinguishes direct evidence from interpretation. “Hypothesis” is
not a confirmed root cause; “temporary recovery” records what was done in this
rehearsal, not a release recommendation.

| Symptom | Direct evidence | Established root cause or unresolved hypothesis | Temporary recovery | Permanent correction required | Regression / preflight test | Limitation |
|---|---|---|---|---|---|---|
| `RunInstances` failed for the node group | IAM decode identified implicit deny on `instance/*`, then on exact launch-template ARN `lt-06f5c124f20ed5cc8` in `LIVE-RESUME-STATUS-20260914.md`; authorized retry `authorized-retry1-20260914-221455` stopped at `22:17:09Z`. | Established: lifecycle identity lacked the required multi-resource EKS launch permission; EKS evaluates instance and launch-template resources separately. | Authorized exact run-scoped recovery policy and one fail-closed retry; later managed recovery policy v10 permitted the node group. | Keep `RunInstances` constrained to exact launch template, instance type, IMDSv2, VPC/subnets, and run tags; require IAM simulation for every evaluated resource ARN. | Exact/wrong-template and exact/wrong-instance simulations plus real VPC CodeBuild preflight. | Simulation covered observed contexts; it is not proof of all future AWS resource evaluations. |
| EKS bootstrap tagging failed | `ec2:CreateTags` condition could not bootstrap the EKS-managed security group; `sg-08847ffcdf5a444f7` and the later rule are named in the live report. | Established: required `Project`/`RunId` resource-tag condition was not present on an AWS/EKS-created group at bootstrap. | Narrow candidate allowed tagging only when the exact EKS cluster-name tag matched; later recovery completed tagging. | Separate bootstrap-tag permissions from steady-state tag deletion, with exact cluster/VPC conditions and ordering tests. | CreateTags simulation on exact versus another security group; fresh node-group preflight. | Does not prove tag ordering is safe under all partial-failure sequences. |
| CodeBuild ENI preflight failed | Decoded failures covered `DeleteNetworkInterface` wildcard, exact private subnet/runner security group, and boundary denial for `CreateNetworkInterfacePermission` on `eni-07aa9c3c68bd3c81c`. | Established: VPC CodeBuild requires a multi-step ENI permission set; prior policy omitted exact create/use/delegation conditions. | Added exact VPC/subnet/security-group grants and proved build `c2e43fbb-9b8e-4d06-bf1c-456183040485` create, attach, build, and cleanup. | Keep ENI permissions VPC/subnet/security-group scoped and delegate only to `codebuild.amazonaws.com`. | Real VPC CodeBuild preflight plus wrong subnet/service denial checks. | Does not establish broad CodeBuild/VPC portability. |
| Fabric PVCs remained pending | START retry 8 reached `ACTIVE` nodes while `deploy_runtime()` omitted `gp3-osc`; helper build `00bdba0f-a5c0-4ad2-81eb-fe3445312215` applied it. | Established: required StorageClass was absent from lifecycle bootstrap. | Applied the exact manifest, stopped the parent before destructive cleanup, and resumed existing Terraform state. | Make StorageClass presence and parameter canonicalization a preflight invariant before PVC creation. | Assert all application/Fabric PVCs Bound before sync; local 57-test suite. | Does not prove storage behavior under node or volume failure. |
| Fabric readiness and packaging raced | Healthy peers lacked CCAAS services; `ed540f41-c199-4cff-8449-cafcacd1ba62` reproduced `shasum` unavailable where `sha256sum` existed; build `65d201c6-ae8f-4ec4-8cca-3cad9da4ea13` completed operations but had a bad post-commit jq path. | Established: helper assumed a command and advanced through non-fail-fast steps; readiness sequencing also allowed a certificate-data race and peer rollout timing race. | Portable hash fallback, explicit CCAAS rollout, package install/approval/commit, and traced retry; official canary `f8d02526-c94f-4258-8e91-cc70270e2ae4` succeeded. | Fail fast after each Fabric phase; wait on Secret readiness, peer rollout, package ID, and committed sequence; validate JSON paths against retained outputs. | Focused 37-test contract suite, peer/orderer health checks, package/sequence queries. | A passing canary is one run, not a general readiness SLO. |
| Empty organization identities caused CSI mounts to fail | Secret-safe diagnostic found correct MSP IDs but zero-length certificate/private-key fields; both run-scoped identity Secrets had no usable versions. | Established: recovery container lacked the admin enrollments produced during original channel creation; helper also accepted malformed empty wallet state. | Re-enrolled already-registered org admins, validated markers without logging values, uploaded two wallet documents, and verified one `AWSCURRENT` version per Secret. | Make identity readiness and non-empty key/certificate validation explicit before GitOps sync; isolate terminal assertions from optional permission checks. | Secret marker/length checks, exact Secret-version verification, and application pod readiness. | Secret values are intentionally not retained; this does not prove all credential-rotation paths. |
| False success from shell sequencing | The helper’s final marker hid application-connection failure and malformed wallet; final status was caused by unauthorized `ListSecretVersionIds` after `PutSecretValue` had succeeded. | Established: multi-operation shell command was not fail-fast and terminal assertion was outside the lifecycle role’s allowed action set. | Re-enrolled identities and verified externally; preserved least privilege rather than adding list permission. | Use `set -euo pipefail`, separate assertions, and make success markers depend only on authorized, essential checks. | Controlled failure injection and explicit terminal-state assertions. | A corrected script still needs release-image validation; frozen runner image was not rebuilt. |
| Argo reported immutable StorageClass drift | `gp3-osc` `ExpiresAt` differed only in serialization (`...03:00Z` versus `...03:00.0000000+00:00`); Kubernetes forbids in-place parameter updates. | Established: canonical JSON/time formatting drifted between recovery-created and Git-managed manifests. | Verified PVCs Bound, deleted only the StorageClass, recreated exact frozen manifest, and forced bounded sync; Argo became `Synced`/`Healthy`. | Canonicalize generated manifests and add an immutable-object diff gate before apply. | Hash/render comparison and pre-sync PVC preservation test. | Deleting/recreating a StorageClass is safe here only because PVC/PV preservation was asserted. |
| STOP Export lost `runId` | Original STOP `026aa8fb-0034-40d6-9b53-5c6f9fc1d643` failed at `08:18:21Z` because successful ReadOnly CodeBuild result replaced whole execution input; Export could not resolve `$.runId`. | Established: Step Functions result-path/input propagation defect. | Patched five STOP tasks to preserve result under dedicated paths; live definition revision `24d5118d-22bf-4877-8efe-deff2b513b10`, definition hash changed to `923a71...`. | Add state-machine contract tests asserting input preservation through every task and export. | `runId` fixture through success/failure paths, versioned definition hash, and one full dry run. | The historical failed execution remains failed; a new success was not fabricated. |
| CodeBuild VPC reset rejected empty-string input | Retry `autonomous-safe-retry-resultpath-20260915-0121` reached cleanup but frozen runner used `vpcId=""`; AWS rejected the update. | Established: CodeBuild API requires an empty VPC object `{}`, not an empty string. | Reset exact live cleanup project outside VPC and used out-of-VPC destroy. | Normalize optional VPC configuration to `{}` and test update/delete transitions. | API-shape unit test plus read-only project configuration assertion. | Does not prove future AWS API compatibility beyond this field. |
| Missing ECR lifecycle-policy deletion permission | Frozen SWEEP was denied on lifecycle policy deletion; exact repair added only `ecr:DeleteLifecyclePolicy` to identity and boundary. | Established: permission was absent from both scoped documents. | Applied exact-run grant; wrong-run simulation remained implicit deny. | Maintain action/resource matrix and quota check for every teardown operation. | Exact repository simulation, wrong repository denial, and full sweep. | Does not authorize unscoped repository inventory. |
| IAM tag deletion self-locked | Removing `Project` first invalidated the IAM condition needed for later Terraform tag deletion on `sg-08847ffcdf5a444f7`. | Established: teardown ordering destroyed its own tag-based authorization predicate. | Validated exact cluster/VPC and removed only remaining Terraform tags, preserving AWS/Name tags. | Delete tags in dependency-safe order or use a narrowly authorized teardown phase that cannot self-lock. | Simulate deletion order against exact resource tags; assert no broad tag cleanup. | Operator recovery was required; unattended ordering remains unproven. |
| MQ/CloudFormation managed ENI blocked stack deletion | Exact RabbitMQ stack entered `DELETE_FAILED` because lifecycle caller could not detach MQ-managed ENI. | Established: managed ENI ownership requires a provider-aware/operator path; no generalized ENI grant was added. | Verified ownership tags and stack ARN, then restarted deletion with authorized operator session; stack reached `DELETE_COMPLETE`. | Add an explicit, reviewed provider-managed ENI teardown contract or operator escalation path. | Stack deletion preflight and exact ownership/empty-ENI checks. | Does not prove unattended deletion of future managed-service variants. |
| Controller-created security group lacked complete tags | `sg-0043440574dd4a162` lacked required runtime tags; exact name/VPC and empty ENI inventory were checked before deletion. | Established: controller-created resource fell outside expected tag propagation. | Deleted only that verified empty backend group. | Add controller-resource tag reconciliation and exact ownership checks before cleanup. | Enumerate controller groups by exact VPC/name and fail closed on non-empty ENIs. | No broad security-group cleanup was performed; other controllers may differ. |
| Unscoped ECR inventory was denied | Frozen SWEEP attempted unscoped `ecr:DescribeRepositories`, correctly denied by least-privilege policy. | Established: cleanup assumed account-wide inventory while policy intentionally scoped run repositories. | Tested recovery override enumerating eight explicit runtime repository names; only `RepositoryNotFoundException` means absent. | Keep explicit repository inventory and fail closed on all other errors. | Exact-name list/delete simulation; wrong repository and denied inventory tests. | Does not prove account-wide absence of unrelated repositories. |
| Stale teardown proof and checksum/newline portability | September 12 proof objects remained in versioned storage; export checksum object initially mismatched exact stored bytes because code hashed spaced JSON while `put_json` stored compact sorted JSON. Windows newline translation was also exposed. | Established: object existence was mistaken for freshness; canonical-byte and text-mode serialization differed. | Required fresh proof versions, performed ETag-conditional checksum-only repair, preserved export version, and switched to explicit UTF-8 bytes. Proof version `08nB1...`; export SHA-256 `9907bdfa...`. | Gate STOP on fresh version IDs/timestamps and hash the exact bytes that are uploaded; use newline-portable serialization. | Byte-level upload regression, ETag conditional read-back, fresh-version freshness guard, Terraform whitespace check. | Versioned old evidence remains recoverable; checksum repair proves this object, not every future export. |

## Final teardown proof and retained resources

Structured proof is `aws/RUNTIME-TEARDOWN-VERIFICATION-20260915.json`:

- proof version `08nB1s6Dx4TALosYhKlvrZT6BvDFck4W`, checked at
  `2026-09-15T15:47:03Z`, written at `15:47:05Z`, SHA-256
  `dc9ab653c07d431c78c2a8e812cb6b524c78424623e70a7c850a537decd3eb09`;
- destroy version `8uifKdzlV9o859XZVusN5bz25_3FD9xh`, completed at
  `15:46:00Z`; destroy build and sweep IDs are recorded above;
- EKS, RabbitMQ, EC2, EBS, EIP, VPC, subnets, security groups, ENIs, launch
  templates, runtime load balancers/target groups, runtime ECR repositories,
  runtime Secrets, and managed Terraform resources all read zero; NAT is
  `deleted`, RabbitMQ stack `DELETE_COMPLETE`, and runtime origin `ABSENT`;
- exact five-tag queries have no active resources. The `us-west-2` index still
  contains two confirmed deleted tombstones (NAT and a default security group),
  which are excluded only after direct EC2 reconciliation. This is not a claim
  that the raw tag index is instantly empty;
- CloudFront `E26XTII1H57RTX` is deployed with only `static-edge`, no runtime
  behavior/origin; public root and `status.json` return HTTP 200;
- controls are preserved, lifecycle is `CLOSED`, active CodeBuild jobs and
  state-machine executions are zero, Terraform locks are zero, scheduler DLQ
  is empty, and the one-time backup schedule self-deleted. The cleanup-failure
  alarm remains `ALARM_FROM_RECENT_FAILED_BUILD` and was not reset.

Retained control/static-edge resources are not the deleted runtime. The final
inventory retains three S3 buckets, three lifecycle-runner images, logs, WAF,
six standard alarms, and two pay-per-request DynamoDB tables. The sanitized
export is 605 bytes, version `ZL4M2MPK3oFNjOODh8i7zKpUCo3Ks.zD`, SHA-256
`9907bdfa79bf8d347f51df38a8410a7cb062eb85ae5fe0b0961084feacb8e146`; only its
checksum object changed during repair.

## Cost: exact billed amount versus estimates

**Exact billed cost:** unavailable; retained evidence says
`actualBilledCost.status = NOT_RECONCILED` and `amountUsd = null`.

**Pre-deployment planning estimate:** `aws/cost-estimate.json` estimated
`USD 5.66` for six hours, `USD 27.07` with 25% contingency, a fixed
rehearsal/control allowance of `USD 20`, and a `USD 200` ceiling with a
72-hour maximum runtime bound. These are planning values, not invoices.

**Retained monthly control estimate:** after runtime destruction, the structured
proof estimates approximately `USD 10.80/month` or `USD 0.36/day` (30-day
month), dominated by one WAF ACL at `USD 10.00`, six alarms at `USD 0.60`,
approximately `USD 0.18` retained ECR image storage, and less than `USD 0.01`
for S3/log/tiny-table storage. The existing Route 53 zone is separate at
`USD 0.50/month`; traffic, requests, ingestion, transitions, delivery, and
future builds are additional. None of these estimates is a provider invoice.

## What this rehearsal does not prove

- production capacity, load/soak behavior, or a reliability target/SLO;
- high availability, disaster recovery, backup/restore, region failure, or
  unattended lifecycle readiness;
- researcher adoption, measured researcher impact, or usability outcomes;
- exact billed cost or account-wide absence of unrelated resources;
- universal exactly-once delivery, despite no duplicate ledger revisions in the
  retained controlled cases;
- comprehensive security, compliance, or individual cryptographic authorship.

The safe operational statement is therefore: **application E2E behavior and
final teardown succeeded, while the scheduled unattended lifecycle failed and
required bounded operator recovery.** The document records lessons and
regression gates; it does not authorize production deployment, a new AWS run,
or release of the frozen runner image.

## Source integrity

The retained evidence tree is checksum-covered by
`docs/usrse26/platform-evidence/20260911-usrse26r1/checksums.sha256`. The
structured final verification is the authoritative post-teardown record; the
chronological live-resume report is the authoritative incident narrative.
Paths and identifiers above are intentionally exact where the retained source
provides them. Any statement not directly supported by those sources is marked
as a hypothesis, limitation, or unsupported claim.
