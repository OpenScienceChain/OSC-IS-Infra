# Interactive Demo Deployment And Teardown Runbook

## Release inputs

The release owner must supply these reviewed values; operators must not infer
or substitute them:

- existing Route 53 hosted-zone ID for `osc-staging.org`;
- lifecycle runner OCI digest implementing `platform/lifecycle/runner-contract.json`;
- AWS Load Balancer Controller OCI digest;
- versioned cross-repository artifact manifest S3 URI and SHA-256;
- image digests for WebApp, API Gateway, Ledger Gateway, submission worker,
  submission listener, history worker, chaincode, and GitOps repository;
- one trusted administrator `/32`; and
- optional confirmed SNS email/Slack notification destinations.

The product release must also confirm `/demo/status`, guest-session, counters,
events, feedback, CSRF, exact-origin CORS, organization binding, quotas,
read-only, and hard-close contracts. Infrastructure does not invent their
environment-variable names or silently weaken the authenticated product path.

## Cheap gates

From the Infra repository:

```powershell
python -m unittest discover -s tests/usrse26 -p "test_*.py" -v
terraform -chdir=terraform/usrse26-eks init -backend=false -input=false
terraform -chdir=terraform/usrse26-eks validate
terraform -chdir=terraform/usrse26-control init -backend=false -input=false
terraform -chdir=terraform/usrse26-control validate
kubectl kustomize platform/gitops/aws
```

Run the existing clean-checkout and complete Kind E2E scripts only after the
release owner places all sibling repositories at the approved revisions.

Prepare the isolated artifact set only after those revisions are clean and
frozen. The controller reference must be the reviewed digest, never its
readable tag:

```powershell
./platform/aws/prepare-aws-artifacts.ps1 `
  -RunId usrse26demo `
  -AlbControllerImage 'public.ecr.aws/eks/aws-load-balancer-controller@sha256:REVIEWED' `
  -ExpiresAt '2026-10-23T15:00:00Z'
```

This command builds and scans the WebApp OCI image, extracts its production
files, injects the fixed demo runtime configuration, and creates a deterministic
static archive. It also builds the lifecycle runner from commit-pinned Fabric,
Fabric CA, Terraform, and Kubernetes sources against a content-addressed Amazon
Linux repository snapshot;
the build stops unless every source repository is clean and every image has zero
HIGH or CRITICAL findings. Before project-owned preparation or build code runs,
a dependency-free preflight rejects common AWS environment variables, local
AWS profiles and caches, CI OIDC variables, cloud SDK credential files, and
Kubernetes service-account tokens. Its machine-readable result and checksum
are bound into the artifact manifest. This is evidence of enforced common
credential-source isolation, not proof that an unknown source cannot exist;
the build job must also have no secrets and no `id-token` permission. After
reviewing the scan, SBOM, source revisions, isolation evidence, and estimated
expiry, publish the exact artifacts to an existing versioned release bucket:

```powershell
./platform/aws/push-aws-artifacts.ps1 `
  -RunId usrse26demo `
  -ReleaseBucket 'REVIEWED-VERSIONED-RELEASE-BUCKET' `
  -ExpiresAt '2026-10-23T15:00:00Z'
```

The resulting `ecr-deployment.json` supplies the versioned manifest URI and
SHA-256 for `prepare-demo-control.ps1`. `START` verifies both the manifest and
the WebApp archive before copying the site to the private edge bucket.

## Prepare and apply the persistent shell

The commands below are authorized-run instructions, not evidence that they
were executed in this implementation task:

```powershell
./platform/aws/prepare-demo-control.ps1 `
  -RunId usrse26demo `
  -HostedZoneId ZREVIEWED `
  -AdminCidr 203.0.113.10/32 `
  -LifecycleRunnerImage 'REPOSITORY@sha256:REVIEWED' `
  -ArtifactManifestS3Uri 's3://RELEASE-BUCKET/releases/usrse26demo/artifacts.json' `
  -ArtifactManifestSha256 'REVIEWED_SHA256'

./platform/aws/apply-demo-control.ps1 -RunId usrse26demo
```

Review and confirm the SNS subscription. Verify the static page and all five
status messages before enabling schedules. The start schedule runs at October
20, 2026 08:00 `America/Los_Angeles`; stop is October 23 at 08:00 and backup
stop is 10:00.

## Start and active checks

The start state machine verifies STS identity, reserves the run ID, permits
three total attempts (initial plus at most two retries), invokes the immutable
runner, and executes the public canary. `OPEN` is forbidden before the canary
confirms an artifact, workflow, history, and cross-organization denial.

During the window, inspect request failures, confirmation p50/p95, queue depth
and age, pod readiness, ALB target health, WAF actions, Fabric state, schedule
delivery, and the persisted deadline.
The runner records only aggregate application metrics behind the control-key
guard; it never records record/session identifiers or queue payloads. Two
consecutive service/readiness/queue/latency safety failures automatically start
the stop state machine. `TIME_BOUNDED` is the only mode: the USD 200 value is a
pre-deployment planning-estimate ceiling, not a live-spend threshold. Runtime
automation does not call Budgets, Cost Explorer, EstimatedCharges, or billing
APIs. Status and monitor evidence keep the planning estimate, bounded exposure,
and unreconciled actual billed cost as separate fields.

### Showtime preflight and one-page operator checklist

Begin the scheduled `START` at least two hours before the public session. The
schedule is a trigger, not proof of readiness: an operator must follow its Step
Functions execution, CodeBuild phase, Terraform state, Kubernetes readiness,
CloudFront deployment, and public canary to a terminal result. Never advertise
`OPEN` while the lifecycle row or static status is `PREPARING`.

Before the schedule fires, record one pass/fail row for each of these checks:

- frozen source revisions, clean product worktrees, immutable image digests,
  artifact-manifest checksum, and zero HIGH/CRITICAL image findings;
- lifecycle-role and permissions-boundary simulations for `PassRole`,
  `tag:GetResources`, EKS node-group creation/tagging, launch-template
  lifecycle, and every `RunInstances` resource evaluation: exact AMI, three
  private subnets, node security group, encrypted volume, instance, and exact
  launch template;
- CodeBuild VPC permissions for ENI create, exact subnet/security-group use,
  `CreateNetworkInterfacePermission` delegated only to CodeBuild, and ENI
  delete; then one short VPC build that proves create/attach/build/cleanup;
- empty Terraform lock table except a current checksum row, no running prior
  START/STOP/build, the exact EKS StorageClass applied before Fabric PVCs, and
  capacity for exactly three reviewed worker nodes;
- both scheduled STOPs enabled with the intended IANA timezone, exact STOP
  state-machine target, retry policy, DLQ, and delete-after-completion behavior;
- a real browser gate, both organization-scoped artifact/workflow paths,
  history confirmation, and a cross-organization denial. Only the successful
  public canary may transition the API and static shell to `OPEN`.

Treat `START` as fresh-create-only. Its Terraform plan policy intentionally
rejects an idempotent plan containing no creates. If a partial apply already
owns the reviewed runtime, use the reviewed recovery procedure at the first
incomplete phase; do not weaken the plan checker or start a second runtime.
Fabric recovery must apply `gp3-osc` before PVC creation, wait for certificate
Secrets to contain non-empty decoded material, give orderer/peer rollouts an
explicit bounded timeout, preserve an already-created channel, and resume at
the first uncommitted chaincode step. Chaincode package-ID calculation must
use an available SHA-256 utility (`sha256sum` on the Linux runner, with
`shasum -a 256` as a fallback). Before CANARY, independently require all four
CCAAS Deployments and Services, the same installed package ID on all four
peers, approvals from both organizations, and committed discovery metadata.

The showtime dashboard should display phase duration and terminal status for
schedule delivery, reservation, static sync, Terraform, EKS/node readiness,
Fabric, GitOps/apps, ALB/VPC origin, public canary, each STOP phase, and the
exact-tag sweep. Application monitoring remains aggregate-only: request/error
counts, confirmation p50/p95, queue depth/age, readiness, target health, WAF
actions, and Fabric health. Do not export participant identifiers, session
cookies, artifact payloads, comments, email addresses, IP addresses, or raw
queue messages.

## Stop and teardown

The stop state machine writes `READ_ONLY`, drains for 15 minutes, exports only
allowlisted evidence, detaches the CloudFront VPC origin, destroys runtime,
and performs an all-tag sweep using the exact Project, Purpose, Environment,
RunId, and runtime ExpiresAt values. The static page remains. Treat any remaining
resource as a failed teardown and use the backup stop; never broaden the sweep
to pre-existing or partially tagged resources.

Runtime removal uses two jobs: the in-VPC job deletes Kubernetes workloads and
resets future lifecycle jobs to public placement; after that job exits and its
network interface is released, a fresh out-of-VPC job destroys the Terraform
runtime. This ordering prevents the runner from trying to delete its own VPC.

Fill `cost-report-template.json` from the approved estimate and teardown
evidence. Leave `actualBilledCost.status` as `NOT_RECONCILED` unless a human
later provides a CloudBank or account billing record; that optional step is
outside runtime automation and never delays teardown. After the
30-day retention window and only with `runtime-teardown-proof.json` showing
zero tagged resources:

```powershell
./platform/aws/destroy-demo-control.ps1 -RunId usrse26demo
```

The final command downloads and validates the runtime proof before removing the
control plane, deletes every version under the exact `releases/<RunId>/` prefix,
checks both runtime and global-control regions for residual run-tagged resources,
and writes `control-plane-teardown-proof.json` locally. The hosted zone is an
input and is never deleted by either Terraform root.

Scheduled STOP has the same evidence rule as manual STOP: schedule delivery is
not completion. Continue following the execution through `READ_ONLY`, the
15-minute drain, allowlisted export, origin detach, workload deletion,
out-of-VPC Terraform destroy, exact-tag sweep, and fallback verification. A
successful run ends only when `runtime-teardown-proof.json` reports
`status=DESTROYED_AND_VERIFIED` and `remainingTaggedResources=0`. If the first
execution fails, diagnose the exact phase, preserve `READ_ONLY`, and retry the
same bounded STOP; never broaden tags or touch the hosted zone.

After runtime teardown, inventory the preserved control plane and static edge.
Report its current AWS list-price estimate separately as (1) incremental demo
control cost, (2) the pre-existing Route 53 hosted-zone fee, and (3)
request/traffic-dependent exposure. State which fixed line item dominates and
label Cost Explorer or billing totals `NOT_RECONCILED` unless an authorized
billing record is supplied. After the evidence-retention window, use
`destroy-demo-control.ps1` to remove the run-scoped state machines, schedules,
alarms, tables, logs, buckets/objects, ECR repository, IAM roles/policies, and
CloudFront/WAF/static-edge resources while preserving the hosted zone.

### Recovery lessons from the September 15 teardown

If runtime cleanup fails after workload deletion or after CodeBuild has left
the VPC, do not repeatedly rerun private-cluster phases. Identify the exact
remaining Terraform state, ensure no execution/build/lock is active, and use
the authorized out-of-VPC `DESTROY_RUNTIME` recovery on the same state, followed
by `SWEEP`. A failed original STOP remains failed in the audit history even
when the later recovery succeeds. Do not claim unattended completion.

Require new proof and destroy object versions from the current attempt,
matching the saved runtime ExpiresAt. Independently reconcile deleted EC2 tag
index tombstones against service state; never treat an access denial as
absence. ECR inventory must name each expected runtime repository explicitly.
Preserve the lifecycle-runner repository and retained control resources.
The final public page stays `READ_ONLY` with `applicationUrl=null`, while the
internal lifecycle row is `CLOSED` with a fresh verification timestamp.

Validate the sanitized-export checksum against downloaded object bytes, not
a reserialized approximation. The September 15 checksum required a versioned,
checksum-only repair because its formatting differed from `put_json`. Preserve
the export version and the superseded checksum history during such a repair.

Before another rehearsal, release the tested source fixes and close the
remaining input-preservation, tag-deletion ordering, controller-security-group,
and MQ-managed ENI authorization gaps identified in the implementation ledger.
The successful September 15 recovery used operator interventions and one
bounded sweep override; the frozen image by itself is not yet a repeatable
end-to-end release.
