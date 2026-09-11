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
