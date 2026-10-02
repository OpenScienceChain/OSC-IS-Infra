# Live Resume Status — 2026-09-14

## Outcome

Run `usrse26r1` is **not OPEN**. The public URL
`https://demo.osc-staging.org` returns HTTP 200 for the closed/static shell,
while `status.json` reports `READ_ONLY` with `applicationUrl: null`.

The latest START execution and CodeBuild job are terminal. They were stopped
before state-machine retries after a new IAM/security boundary appeared. No
replacement deployment was created.

## Frozen source revisions

| Repository | Revision |
|---|---|
| OSC-IS-Infra | `2d518f128285d3df81566e5f11efc7652bd3764b` |
| OSC-APIGateway | `2351746fad480bbe376e02da376a0864c59c1ad7` |
| OSC-Artifact-Submission | `12c465381d7cd2f61fbedab3fa7f9e1ba44d7c81` |
| OSC-Chaincode | `1d7d710485e5731e9489dc3df4fd5b0b18baaa0c` |
| OSC-WebApp | `f05c02da0579a4fb82bd6433c382147d6973e00d` |

The four application worktrees are clean. The infrastructure worktree retains
the reviewed, uncommitted lifecycle-recovery changes. Nothing was pushed or
merged.

## Live AWS and spend-risk state

Read-only inspection in account `269624229733`, region `us-west-2`, showed:

- EKS cluster `osc-usrse26-usrse26r1-eks`: `ACTIVE`, Kubernetes 1.35, zero
  node groups, only `vpc-cni` and `kube-proxy` installed.
- RabbitMQ broker `osc-usrse26-usrse26r1-rabbitmq`: `RUNNING`; its
  CloudFormation stack is `CREATE_COMPLETE`.
- NAT gateway `nat-0a3db594a1e76fd3e`: `available`.
- Lifecycle row: `PREPARING`.
- No running START execution, active CodeBuild job, or Terraform lock.

The EKS control plane, three-broker RabbitMQ deployment, NAT gateway, and
associated network resources can incur charges even though no worker nodes
exist. Provider billing has not been reconciled; the reviewed 72-hour planning
estimate remains USD 104.83 under the USD 200 ceiling.

## Automatic teardown

The independent schedule `osc-usrse26-usrse26r1-today-backup-stop` remains
`ENABLED` for `2026-09-14 20:00:00 America/Los_Angeles`. It targets the exact
`usrse26r1` STOP state machine and deletes itself after completion. It was not
postponed or disabled.

## Exact security gate

The reviewed repair image
`sha256:71676f94051d99dbee99251f2820a4447e77955d8cad0576317c98d8c04a9f7f`
was published to the existing run-scoped repository and installed on both
existing control projects. The candidate had passed the 57-test USRSE26 suite,
runtime-plan policy, self-test, and a zero-high/critical Trivy scan.

The resumed apply then exposed three authorization facts:

1. `ec2:CreateTags` cannot bootstrap the required run tags onto the
   EKS-managed cluster security group. Its current AWS/EKS tags do not satisfy
   the existing `Project` and `RunId` resource-tag condition.
2. AWS decoded the node-group failure as an implicit deny for
   `ec2:RunInstances` on `arn:aws:ec2:us-west-2:269624229733:instance/*`, using
   the exact run launch template `lt-06f5c124f20ed5cc8`, instance type
   `m7i.large`, and IMDSv2-required metadata settings. No explicit deny was
   reported. Further launch-template resource checks may follow if this
   permission is granted.
3. Same-build cleanup calls `tag:GetResources`, while the deployed policy uses
   the non-authorizing prefix `resourcegroupstaggingapi:GetResources`.

Because `RunInstances` and bootstrap tagging materially expand the lifecycle
identity design, no further IAM change was made without an explicit decision.
The runtime remains protected by the 8:00 PM PT automatic stop.

## Read-only candidate review

AWS documents that the identity calling EKS `CreateNodegroup` with a launch
template needs both `ec2:RunInstances` and `ec2:CreateTags`. AWS also documents
using the `ec2:LaunchTemplate` and `ec2:IsLaunchTemplateResource` condition keys
to prevent launch-parameter overrides:

- <https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html>
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html>

The exact existing launch template is version 1 of
`lt-06f5c124f20ed5cc8`. It is tagged `Project=OSC-IS` and
`RunId=usrse26r1`; it requires IMDSv2, uses one encrypted 40 GiB gp3 root
volume, and carries the exact run tags for instances and volumes.

A **not-applied** candidate was checked with AWS IAM simulation. It restricts
`RunInstances` to that exact launch-template ARN, `m7i.large`, IMDSv2, and the
exact `Project`/`RunId` request tags. It permits bootstrap `CreateTags` only
where the target security group already has
`aws:eks:cluster-name=osc-usrse26-usrse26r1-eks`, and corrects the inventory
action to `tag:GetResources`. Simulation results were:

- exact launch: `allowed`; wrong template or larger instance type:
  `implicitDeny`;
- exact EKS cluster security group: `allowed`; another security group:
  `implicitDeny`;
- `tag:GetResources`: `allowed`.

The candidate remains within both IAM document quotas (10,032/10,240 inline
characters and 5,912/6,144 boundary characters). It is not sufficient proof
for application: `RunInstances` performs multiple resource evaluations, while
the decoded failure and simulation cover only the observed `instance/*`
evaluation. A live retry could expose a different resource ARN and must stop
rather than broaden automatically.

## Authorized fail-closed retry

At `2026-09-14T22:14:55Z`, explicit authorization was received for the exact
candidate and one fail-closed resume retry. The candidate was simulated again
with the same six expected results, then applied as:

- lifecycle inline policy SHA-256
  `ab0989ee9b1717821dab39ee2856911793c1144495b2fd7dcc6e8cdbbb319d9c`,
  10,032/10,240 characters;
- runtime boundary SHA-256
  `ddd57e48fa0906c0a82af9bf7675b33c0d79bafaeab33eb39dc29a0c2d558e0b`,
  5,912/6,144 characters, default version `v12`.

The 8:00 PM America/Los_Angeles backup stop was verified before and after the
policy change. Execution
`authorized-retry1-20260914-221455` started exactly once. It successfully
tagged EKS-managed cluster security group `sg-08847ffcdf5a444f7` and created
the run-scoped lifecycle ingress rule, then failed closed during node-group
creation.

The decoded failure is an implicit deny, with no explicit deny, for
`ec2:RunInstances` on the new resource evaluation
`arn:aws:ec2:us-west-2:269624229733:launch-template/lt-06f5c124f20ed5cc8`.
The decoded context confirms launch-template version `1`,
`ec2:IsLaunchTemplateResource=true`, and the exact run resource tags. This
evaluation does not contain the instance-type, IMDS, or request-tag context
keys used by the authorized `instance/*` statement.

The execution was aborted at `2026-09-14T22:17:09Z` before its built-in retry,
and the associated CodeBuild job is terminal `STOPPED`. No additional IAM
permission or START retry was attempted. Read-only verification showed zero
node groups, zero active builds, zero running START executions, and zero
Terraform locks. The public status remains `READ_ONLY`; EKS, RabbitMQ, and the
NAT gateway remain present and potentially charging. The 8:00 PM PT stop
remains `ENABLED`.

## Version-pinned launch-template correction gate

A subsequent authorization permitted preparation and simulation of one exact
launch-template correction, provided IAM simulation could allow version 1 and
deny every other version. No application was permitted unless that prerequisite
passed.

The decoded live evaluation exposes `ec2:LaunchTemplateVersion=1`, but AWS does
not list `ec2:LaunchTemplateVersion` among the supported `RunInstances`
condition keys for a launch-template resource. The supported controls include
`aws:ResourceTag`, `ec2:ResourceTag`, `ec2:IsLaunchTemplateResource`, and
`ec2:LaunchTemplate`:

- <https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html>
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html>

The pre-apply simulations confirmed the limitation:

- exact launch-template ARN, exact `Project`/`RunId` resource tags, and
  `ec2:IsLaunchTemplateResource=true`: version 1 `allowed` and hypothetical
  version 2 also `allowed`;
- the same statement with `ec2:LaunchTemplateVersion=1`: version 1
  `implicitDeny` and version 2 `implicitDeny`.

The live launch template currently has only version 1, which is both default
and latest. That state fact cannot satisfy the authorized requirement for an
IAM-enforced denial of other versions. The escalation trigger therefore fired:
no IAM document was changed, boundary `v12` and the 10,032-character inline
policy remain intact, and the additional START retry was not consumed. A
read-only safety check again showed zero active builds, running START
executions, or Terraform locks, with the 8:00 PM PT backup stop `ENABLED`.

The smallest next decision is whether to accept the weaker, IAM-enforceable
constraint set (exact launch-template ARN, exact run/project resource tags,
and non-overridable launch-template resources) while relying on external
state/workflow validation that version 1 is the only version. That requires
fresh authorization. The alternative is immediate or scheduled teardown.

## External-version-control continuation gate

Fresh authorization accepted external validation of version 1, but added a
mandatory precondition: the lifecycle identity must be unable to create,
modify, or delete launch templates or launch-template versions. The apply and
one additional retry remained conditional on that check.

Read-only verification found that the exact launch template still has only
version 1, which is both default and latest. Version 1 retains IMDSv2-required
metadata, hop limit 1, an encrypted delete-on-termination 40 GiB gp3 root
volume, and exact `Project=OSC-IS` / `RunId=usrse26r1` instance and volume tag
specifications. The template intentionally has no instance type; `m7i.large`
is fixed by the reviewed EKS node-group configuration.

Live-principal simulation of the existing lifecycle role and boundary showed:

- `ec2:CreateLaunchTemplate` with exact Project/RunId request tags: `allowed`;
- `ec2:CreateLaunchTemplateVersion` on the exact template: `implicitDeny`;
- `ec2:ModifyLaunchTemplate` on the exact run-tagged template: `allowed`;
- `ec2:DeleteLaunchTemplate` on the exact run-tagged template: `allowed`;
- `ec2:DeleteLaunchTemplateVersions` on the exact run-tagged template:
  `allowed`.

The required precondition therefore failed before the new `RunInstances`
statement was simulated or applied. Removing or denying these existing
lifecycle permissions is outside the authorized correction and could impair
Terraform reconciliation or automatic teardown. No IAM document changed;
boundary `v12` and the prior inline-policy hash remain current. The additional
START retry was not consumed. At `2026-09-14T23:09:00Z`, there were zero active
builds, running START executions, Terraform locks, or EKS node groups, and the
8:00 PM PT backup stop remained `ENABLED`.

The smallest next decision is whether to accept the role's existing run-tagged
template lifecycle permissions and authorize the exact supported
launch-template `RunInstances` grant plus one retry. The safer but larger
alternative is a separately reviewed permission-phase design that preserves
teardown while preventing pre-launch template mutation.

## Authorized autonomous continuation

Subsequent explicit authorization permitted bounded correction and autonomous
continuation within account `269624229733`, region `us-west-2`, and run
`usrse26r1`. The lifecycle role received the run-scoped recovery managed policy
`osc-usrse26-usrse26r1-runinstances-recovery`; it remains attached only to the
run lifecycle role. The successful node-group retry used exact launch template
`lt-06f5c124f20ed5cc8`, exact frozen AMI/network resources, `m7i.large`, and
IMDSv2-required metadata. The node group reached `ACTIVE` with exactly three
nodes and Terraform completed 13 creates and two in-place changes.

The current recovery policy default version is `v10` (4,750 characters,
SHA-256 `dbaa6e20aecf594db4b3e8ecca60b1ad9cd6abbdbd77d4bb739e8c85d8dae33c`).
The runtime boundary default version is `v13` (5,951 characters, SHA-256
`be3ca5c88471630772fa848502bebf6a42af114c0bd64c3c9b5d54e8106dac2c`).
IAM simulation and a real VPC CodeBuild preflight proved the exact allowed path
and denied wrong subnet/service combinations.

The observed IAM failure sequence was:

1. EKS security-group bootstrap `CreateTags` and `tag:GetResources` action-name
   mismatch;
2. `RunInstances` evaluation on `instance/*`;
3. `RunInstances` evaluation on exact launch template
   `lt-06f5c124f20ed5cc8`;
4. CodeBuild `DeleteNetworkInterface` preflight on
   `arn:aws:ec2:us-west-2:269624229733:*/*`;
5. `CreateNetworkInterface` on exact private subnet
   `subnet-092527e5361159593` and runner security group
   `sg-0a15444edc22b8bc8`;
6. boundary denial for `CreateNetworkInterfacePermission` on
   `eni-07aa9c3c68bd3c81c`.

The final CodeBuild ENI grant permits object creation only in `us-west-2`, use
only in VPC `vpc-0e4f91e5f95ba26f9` with the exact three private subnets and
runner security group, and interface-permission delegation only to
`codebuild.amazonaws.com`. Build
`osc-usrse26-usrse26r1-lifecycle:c2e43fbb-9b8e-4d06-bf1c-456183040485`
proved ENI create, permission, attach, build, and cleanup end to end.

## Runtime phase recovery

START retry 8 reached an `ACTIVE` node group but Fabric PVCs remained pending
because lifecycle `deploy_runtime()` omitted the reviewed `gp3-osc`
StorageClass. Helper build
`00bdba0f-a5c0-4ad2-81eb-fe3445312215` applied that exact manifest. The parent
START was stopped before its same-build cleanup could destroy the now-valid
infrastructure. START retry 9 then failed safely because the fresh-create plan
checker found no creates; its Terraform output contained no destructive plan
actions.

The recovery therefore reused the existing Terraform state and resumed frozen
runtime phases without creating a second environment. The first Fabric resume
created the channel and joined peers but exposed a certificate-data readiness
race during chaincode packaging. Isolated build
`96c78f71-e1ef-40c5-afac-8ba5a50c8880` proved the package valid after the
Secret became ready. Repeated network-up attempts also exposed a two-minute
peer rollout timing race; a traced retry completed successfully with all three
orderers and four peers healthy. Build
`a25af95f-e6c5-44b4-b069-b123bbb931ed` then preserved the existing channel,
completed chaincode deployment and application profiles, and uploaded both
organization identities.

At `2026-09-15T00:57:00Z`, the independent safety schedule was intentionally
updated by the coordinating task to `2026-09-14 22:00:00
America/Los_Angeles`. It remains `ENABLED`, targets only the exact STOP state
machine, retains two retries, a 3,600-second maximum event age, the exact
scheduler DLQ, and `ActionAfterCompletion=DELETE`. Its firing is not teardown
completion; final evidence still requires `DESTROYED_AND_VERIFIED`, zero
remaining tagged resources, a detached runtime origin, and a healthy static
fallback.

The first GitOps resume then exposed that the lifecycle image's Python runtime
does not accept `Path.write_text(..., newline=...)` in
`render_gitops_bootstrap.py`. The portable byte-write equivalent was applied
only in the ephemeral runner and recorded in the worktree. Argo CD itself
recovered from transient `quay.io` HTTP 502 image-pull responses before the
render step.

GitOps reconciliation also showed that both run-scoped Fabric identity secret
objects had no versions, so their CSI mounts correctly failed closed. The
earlier helper had placed multiple operations in one non-fail-fast shell
command: its final success marker hid an application-connection failure and a
malformed empty wallet. A secret-safe diagnostic confirmed correct MSP IDs but
zero-length certificate and private-key fields. The recovery container was
ephemeral, so it lacked the admin enrollments originally produced by channel
creation. The repair re-enrolled only the already-registered org admins,
validated certificate/private-key markers without logging values, created the
two wallet documents, and ran the frozen uploader. External read-only
verification found exactly one `AWSCURRENT` version for each of
`osc-usrse26-usrse26r1/fabric/nsg` and
`osc-usrse26-usrse26r1/fabric/citizen-science`. The helper's final terminal
status was caused only by its extra `ListSecretVersionIds` assertion, an action
the tightly scoped lifecycle role intentionally lacks; `PutSecretValue` had
already succeeded.

## Application reconciliation and edge attachment

Build `433996dc-0297-4451-b0b7-a8dc4bc93001` observed the repaired identity
secrets and recovered every application workload, but its 15-minute Argo gate
expired on one immutable-object mismatch. All 21 `osc-apps` pods were Running
and ready, both organization auth Secrets existed, and the internal ALB was
active. Argo was `Healthy` but `OutOfSync` because the recovery-created
`gp3-osc` StorageClass serialized its `ExpiresAt` parameter as
`2026-09-15T03:00:00Z`, while the frozen Git repository stored the equivalent
instant as `2026-09-15T03:00:00.0000000+00:00`. Kubernetes correctly forbids
in-place StorageClass parameter updates.

Build `ba0c62f8-8c10-4851-bf13-a3468455aa32` first asserted that every
application and Fabric PVC was Bound, deleted only the StorageClass object,
and preserved all PVCs, PVs, volumes, and pods. Build
`6e780d56-3450-4ea8-857f-f736d1d5fc5d` recreated `gp3-osc` from the exact
frozen manifest. Build `6283e9a1-1754-4847-8f45-d7b18147320c` forced one
bounded sync at baseline revision `27d66cda9513f176f92bfef81e36d5a8ea536c6d`;
Argo reached `Synced` and `Healthy`, and all 21 application pods remained
ready. The local `tests/usrse26` suite also passed 57 tests, with only the
host-dependent symlink test skipped.

Build `6e751cee-9396-4d90-b2c1-0afae7e52434` then completed deterministic
application seeding and kept the public state at `PREPARING`, but failed closed
when CloudFront evaluated `cloudfront:TagResource` as a dependent authorization
for tagged VPC-origin creation. The existing identity statement and permissions
boundary allowed only `cloudfront:CreateVpcOrigin`. The exact request-tag
condition was preserved and `cloudfront:TagResource` was added to that existing
statement in both documents. The updated inline policy is 10,199 characters
(SHA-256 `699b452307944e5f2aa822037085539886cf24587785331a8a9260a4e2d10886`);
permissions-boundary default version `v14` is 5,976 characters (SHA-256
`84edcf1c312286ed10f1978306026828ec175a899b6c93677d50604a0f724e61`).
Simulation permits the exact `usrse26r1` request tag and denies a wrong run
tag. Non-default boundary version `v9` was pruned to remain within IAM's
five-version limit. Post-deploy build
`685ed0ac-01a6-4d7a-8258-6cd864e91f7a` created exact VPC origin
`vo_JwlVpK48cN0CjiCEb544JZ`; it was still deploying at the last checkpoint.

## Edge completion, chaincode repair, and OPEN evidence

The VPC origin reached `Deployed` at `2026-09-15T02:03:40.334Z` and points
only to internal ALB
`arn:aws:elasticloadbalancing:us-west-2:269624229733:loadbalancer/app/k8s-oscapps-oscdemoa-ce1b201649/d85b3eb88707d4cb`.
CloudFront distribution `E26XTII1H57RTX` reached `Deployed` with the frozen
static origin plus a `/api/*` behavior targeting that exact runtime origin.
Build `92de6fd6-256e-45d3-b1eb-d11e22d9aa80` wrote start evidence at
`evidence/usrse26r1/start.json`, recording `vpcOriginAttached=true` and
completion at `2026-09-15T02:06:33Z`.

The first official CANARY build
`625a95bb-c375-40b0-b37c-a808a28286e1` failed closed and restored public
`READ_ONLY`. Ledger Gateway logs showed Fabric discovery had no metadata for
`osc-provenance` on `osc-channel`. A cluster inventory then proved that all
four peers were healthy but all four expected CCAAS Deployments and Services
were absent. This supersedes the earlier inference that build
`a25af95f-e6c5-44b4-b069-b123bbb931ed` completed chaincode deployment: its
single non-fail-fast command advanced after the chaincode helper exited.

The exact helper failure was reproduced in build
`ed540f41-c199-4cff-8449-cafcacd1ba62`: the CodeBuild recovery image provides
`sha256sum`, while the generated Fabric helper hard-coded unavailable command
`shasum`. No chaincode package had been installed, approved, or committed.
Build `65d201c6-ae8f-4ec4-8cca-3cad9da4ea13` used the equivalent available
SHA-256 calculation and then:

- launched and rolled out all four `*-ccaas-osc-provenance` Deployments and
  Services;
- installed package ID
  `osc-provenance:30bb66c67920839f3637e05849884dfa21ce5a439854c135c7d96b4edd54ebca`
  on all four peers;
- approved sequence 1 for both organizations; and
- committed sequence 1 through three transactions reported `VALID`.

That build's terminal status was `FAILED` only because its post-commit jq
assertion looked for the approved package ID at the wrong JSON path; the
logged lifecycle operations and four peer queries had already succeeded. The
generator now selects `sha256sum` when available and falls back to `shasum`;
the focused contract suite passes 37 tests.

Official CANARY build
`f8d02526-c94f-4258-8e91-cc70270e2ae4` then succeeded. Durable evidence
`evidence/usrse26r1/canary.json` records completion at
`2026-09-15T02:38:29Z`, artifact transaction
`df9672d0f76278d9157283d96f63c66519e09683cb6a3fa7684d9dfd30e3ead8`,
workflow transaction
`c847d31ab077f85c81af47d4524e234e95729725ed4754686c01f8b2549fc23d`,
zero duplicate ledger revisions, and successful cross-organization denial.
DynamoDB and public `status.json` both report `OPEN`; public API health returns
HTTP 200. A background in-app browser rendered the OPEN banner, organization
controls, anonymous counters, and the canary artifact/workflow with no console
warnings or errors.

The backup stop was subsequently updated by the coordinating task and remains
`ENABLED` for `at(2026-09-15T01:00:00)` in `America/Los_Angeles`, with two
retries, maximum event age 3,600 seconds, the exact scheduler DLQ, the exact
STOP state machine, and `ActionAfterCompletion=DELETE`. A direct AWS read at
`2026-09-15T04:21:40Z` verified every one of those fields, plus the unchanged
exact account/region/run input and scheduler role.

## Teardown freshness guard

The versioned control bucket contains teardown evidence from the earlier
September 11 attempt, so object existence alone cannot satisfy the pending
STOP gate. Before the current teardown, the current
`runtime-teardown-proof.json` version is
`A8neQaYiAaeTh8eU7P_LhDsic7lOBHny`, last modified
`2026-09-12T02:24:06Z`, with `checkedAt=2026-09-12T02:24:04Z`. The current
`destroy.json` version is `2XVLTyRZ6x.Up8pa5NK7DNRrFnJ696Rx`, last modified
`2026-09-12T02:14:22Z`. Completion for this live recovery requires new object
versions written by the current STOP after `2026-09-15T08:00:00Z`.

The Terraform lock table contains one expected state digest row, not an active
lock: its `LockID` ends in `terraform.tfstate-md5` and its digest exactly
matches current runtime-state ETag `320f06b4f80827a98dd5391950d350cf`.
Current runtime state and `vpc-origin.json` are present, and the out-of-VPC
cleanup CodeBuild project has no VPC configuration.

## Contribution-window boundary

At `2026-09-15T03:00:07Z`, immediately after the exact `20:00:00`
America/Los_Angeles contribution-window boundary, the background browser was
reloaded without submitting any mutation. The public page visibly reported
`CLOSED`, stated that the interactive demonstration was closed and the
expensive runtime was off, and no longer rendered the organization or
contribution controls. Public counters and the confirmed canary artifact and
workflow remained browsable. The browser console reported no warnings or
errors.

This is the expected client-side window closure. The runtime remains live and
chargeable until the superseding `01:00:00` America/Los_Angeles safety
schedule invokes STOP. The coordinating task changed only the schedule time;
the public contribution window was not restored, and no early teardown was
performed.

## Retained-control cost estimate before teardown

The current control-plane footprint was inventoried separately from the
chargeable runtime. At current public pay-as-you-go list prices, a conservative
full-month estimate for the incremental retained demo controls is approximately
USD 10.77:

| Retained item | Current footprint | Conservative monthly estimate |
|---|---:|---:|
| AWS WAF | one web ACL and five rules | USD 10.00 |
| CloudWatch standard alarms | six alarms | USD 0.60 |
| Lifecycle-runner ECR images | 1.65 GiB | USD 0.17 |
| S3 and CloudWatch Logs storage | less than 0.20 GiB combined | less than USD 0.01 |

The existing public Route 53 hosted zone for `osc-staging.org` is a separate
USD 0.50/month account-level item and is not treated as an incremental demo
control. Request-driven charges remain separate: CloudFront and WAF traffic,
S3 requests, WAF/CloudFront log ingestion, DynamoDB requests, Step Functions
transitions, scheduler/SNS/SQS delivery, and CodeBuild only while a build is
running. CloudFront flat-rate plan enrollment is not asserted; the estimate
uses the deployed pay-as-you-go posture. Actual billed cost remains
`NOT_RECONCILED`.

Pricing references checked for this estimate:

- <https://aws.amazon.com/waf/pricing/>
- <https://aws.amazon.com/cloudwatch/pricing/>
- <https://aws.amazon.com/ecr/pricing/>
- <https://aws.amazon.com/s3/pricing/>
- <https://aws.amazon.com/route53/pricing/>
- <https://aws.amazon.com/cloudfront/pricing/>
- <https://aws.amazon.com/step-functions/pricing/>
- <https://aws.amazon.com/codebuild/pricing/>

The retained footprint and estimate must be recomputed from the actual
post-STOP inventory before final handoff.

## Final result: DESTROYED_AND_VERIFIED (September 15, 08:47 Pacific)

This section supersedes all earlier live, pending, and cost checkpoints.
The exact runtime in account `269624229733`, region `us-west-2`, run
`usrse26r1` is removed. The final out-of-VPC destroy build
`48d829ca-38ab-495c-92cc-718c97a291ef` succeeded at `2026-09-15T15:46:01Z`;
sweep build `48a7647d-3c90-4f21-acda-c79c69a042d9` succeeded at
`2026-09-15T15:47:06Z`.

Fresh control-bucket proof version `08nB1s6Dx4TALosYhKlvrZT6BvDFck4W`
was written at `15:47:05Z`, with `checkedAt=15:47:03Z`,
`status=DESTROYED_AND_VERIFIED`, `verified=true`, and
`remainingTaggedResources=0`. Its SHA-256 is
`dc9ab653c07d431c78c2a8e812cb6b524c78424623e70a7c850a537decd3eb09`.
Fresh `destroy.json` version `8uifKdzlV9o859XZVusN5bz25_3FD9xh` records
completion at `15:46:00Z`. Neither is the stale September 12 evidence.

Independent AWS inventory beginning at `15:47:17Z` confirmed no EKS cluster,
RabbitMQ broker, live EC2 instance, EBS volume, Elastic IP, VPC, subnet,
security group, ENI, launch template, runtime load balancer/target group,
application repository, or runtime secret. The exact RabbitMQ stack is
`DELETE_COMPLETE`. NAT `nat-0a3db594a1e76fd3e` reports `deleted`, and the
runtime Terraform state contains zero managed resources. No untagged ENIs
remain in the exact former VPC. The EKS runtime log group is absent.

The exact five-tag query is empty in `us-east-1`. In `us-west-2`, the tag index
still lists the deleted NAT and default security group
`sg-05ab2a7e798b1bd78`; direct EC2 reads confirm the NAT deleted and the group
absent. The sweep correctly excludes only verified deleted tombstones, so
the active exact-tag residual count is zero. The raw tag index is not claimed
to be instantly empty.

CloudFront distribution `E26XTII1H57RTX` is `Deployed`, contains only
`static-edge`, and has no runtime cache behavior or VPC origin. Public root
and `status.json` return HTTP 200. The public state is `READ_ONLY`,
`applicationUrl=null`, updated at `15:47:04Z`; the browser visibly says the
temporary runtime is removed, with no warnings/errors or contribution controls.
DynamoDB is `CLOSED` with `teardownVerifiedAt=15:47:03Z`. Both CodeBuild
projects have no VPC configuration, no builds or state-machine executions are
running, and the lock table contains only the expected state-digest row.

### Schedule delivery and recovery failures (not unattended success)

The exact 01:00 Pacific safety schedule fired at approximately `08:00:46Z`
and self-deleted. Its DLQ remains empty. Original STOP execution
`026aa8fb-0034-40d6-9b53-5c6f9fc1d643` failed at `08:18:21Z`: the successful
ReadOnly CodeBuild result replaced the whole execution input, so Export could
not resolve `$.runId`. The five STOP CodeBuild tasks were patched in source
and in the exact live state-machine definition to preserve their result under
dedicated paths. The definition SHA-256 changed from
`caf2fb009366330ecc5fe70fef705d3fe019b51702f311463d8387dae0753eee`
to `923a71aed46d82a475deb426829a279300626fffaf69e3a1504b150fd02e2c45`;
live revision is `24d5118d-22bf-4877-8efe-deff2b513b10`. Role, logging,
and tracing were preserved.

The bounded retry `autonomous-safe-retry-resultpath-20260915-0121`
successfully re-established read-only and exported evidence at `08:38:10Z`.
Its workload phase detached the runtime origin and restored the static page,
but the frozen runner's `vpcId=""` CodeBuild update was invalid. Source now
uses an empty VPC object `{}`; the exact live project was reset outside the
VPC. Subsequent private-cluster retries could no longer reach the private
endpoint; the final such build was stopped to allow out-of-VPC cleanup.

The retry ultimately failed at `09:45:56Z` with
`RuntimeTeardownIncomplete`. Operator recovery resumed around 08:34 Pacific
(`15:34Z`); this is not a claim of uninterrupted overnight supervision.
The following narrow corrections were necessary:

- ECR lifecycle-policy deletion was missing. Only
  `ecr:DeleteLifecyclePolicy` was added to the existing exact-run repository
  statement in both identity and boundary. Inline size is 10,227/10,240
  characters, SHA-256
  `ca76a29326d044d8efc98fa0a7398fba873e5647e1fd6e945b1d767ff25fc24e`.
  Boundary default `v15` is 6,004/6,144 characters, SHA-256
  `5390adc4bb8ee1b6df7b3e526d47f1c5b3740f779fbe4dd0b8ae461027f18694`.
  Previous default `v14` was retained; obsolete non-default `v10` was pruned
  for IAM's version limit. Exact-run simulation allowed the action; wrong-run
  simulation returned implicit deny.
- Independent tag-resource destroys had removed `Project` before the other
  Terraform tags, invalidating their own IAM tag condition. After validating
  the exact cluster and VPC, the operator removed only the remaining Terraform
  tags from cluster group `sg-08847ffcdf5a444f7`, preserving AWS/Name tags.
- Controller-owned backend group `sg-0043440574dd4a162` lacked the complete
  required runtime tags. Its exact name/VPC and empty ENI inventory were
  verified before deletion. No broad security-group cleanup was performed.
- The exact RabbitMQ stack was `DELETE_FAILED` because the lifecycle caller
  could not detach an MQ-managed ENI. Its ownership tags and stack ARN were
  verified before restarting deletion with the authorized operator session;
  no generalized ENI permission was added.
- Runtime destroy `3a7262a9-76ff-4957-9399-9ca177837ab8` removed EKS, MQ,
  repositories, subnets, and NAT but failed on a stale EIP association. Direct
  EC2 inspection then showed the IP unassociated. A fresh Terraform retry
  removed the remaining IP, internet gateway, and VPC without an IAM change.
- Frozen SWEEP attempted unscoped `ecr:DescribeRepositories`, which was
  correctly denied. The tested recovery override reads the eight explicit
  runtime repository names, treating only `RepositoryNotFoundException` as
  absence and all other failures as fatal. It also preserves final public
  `READ_ONLY` while recording lifecycle `CLOSED`. Bootstrap SHA-256:
  `f0f721371a653255da4522f01fc16e6b27ff9c3b7e5b1835a2b49c495d9b48ea`.

The historical failed STOP executions remain failed; a new success execution
was not fabricated. The cleanup-failure alarm still reflected a recent failed
build at the final inventory and was not manually reset. Existing future
START/STOP/backup/MONITOR schedules and all retained controls were preserved.

### Export byte-level verification

The 605-byte sanitized export version `ZL4M2MPK3oFNjOODh8i7zKpUCo3Ks.zD`
is unchanged. Its exact-byte SHA-256 is
`9907bdfa79bf8d347f51df38a8410a7cb062eb85ae5fe0b0961084feacb8e146`.
The frozen export code hashed spaced JSON, while `put_json` stored sorted,
compact JSON. Checksum version `GgEtR5i8pJIH2PEwYqoOTSsQ74aMUF8u`
therefore did not match. At `15:49:31Z`, an ETag-conditional checksum-only
repair produced version `2hSx344v4hEGHNOwULPbXBur.rjUwOml`; re-reading both
objects proved the checksum matches and the export version is preserved.
The old checksum remains recoverable through S3 version history.

Source now hashes the same canonical bytes used by `put_json` and writes
explicit UTF-8 bytes to prevent Windows CRLF translation. The regression
test captures actual upload bytes; it exposed the newline issue before the
final correction. Final `tests/usrse26`: 60 passed, one host-dependent test
skipped, 24 subtests passed. Terraform formatting and diff whitespace checks
pass. No frozen image was rebuilt, and nothing was pushed or merged.

### Final retained-control estimate and release boundary

The post-destroy inventory preserves three S3 buckets: control 7,434,470 bytes
in 152 versions, edge 160,419,307 bytes in 1,333 versions, and release
20,700,224 bytes in 13 versions (before the additional 154-byte checksum
version). Three lifecycle-runner images total 1,773,469,153 compressed bytes;
shared layers may make billed storage smaller. Retained logs report
12,255,825 bytes across lifecycle, Step Functions, and global WAF logs.
Log-size counters may lag. Two DynamoDB tables use pay-per-request billing.

Conservatively rounded incremental control/static-edge estimate:

| Item | Full-month estimate |
|---|---:|
| One WAF ACL, three custom rules, two AWS managed groups | USD 10.00 |
| Six standard CloudWatch alarms | USD 0.60 |
| Retained ECR image storage | approximately USD 0.18 |
| S3, logs, and tiny table storage | less than USD 0.01 |
| **Rounded total** | **approximately USD 10.80/month** |

This is approximately USD 0.36/day using a 30-day month, not a measured bill.
WAF accounts for about 93% of the fixed estimate. The existing public Route 53
zone is a separate USD 0.50/month, approximately USD 0.017/day, and was not
changed. Traffic, requests, new log ingestion, workflow executions, and any
future builds are additional. Actual billed cost remains `NOT_RECONCILED`.
Public list prices were rechecked against
[WAF](https://aws.amazon.com/waf/pricing/),
[CloudWatch](https://aws.amazon.com/cloudwatch/pricing/),
[ECR](https://aws.amazon.com/ecr/pricing/),
[S3](https://aws.amazon.com/s3/pricing/), and
[Route 53](https://aws.amazon.com/route53/pricing/).

The structured independent verification is
`RUNTIME-TEARDOWN-VERIFICATION-20260915.json`. Runtime teardown is complete;
fully unattended repeatability is not established. The implementation ledger
records remaining notification-result, tag-deletion ordering, MQ-managed ENI,
and controller-group cleanup gaps for a reviewed release/fault-path rehearsal.
The runtime data itself was intentionally removed; preserved aggregate evidence
is not a restorable copy of the live database or ledger.
