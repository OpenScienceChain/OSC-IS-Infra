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

Prepare the credential-free artifact set only after those revisions are clean
and frozen. The controller reference must be the reviewed digest, never its
readable tag:

```powershell
./platform/aws/prepare-aws-artifacts.ps1 `
  -RunId usrse26demo `
  -AlbControllerImage 'public.ecr.aws/eks/aws-load-balancer-controller@sha256:REVIEWED'
```

The release manifest consumed by the lifecycle runner must additionally carry
the reviewed WebApp bundle's source revision, S3 URI, and SHA-256. `START`
copies that bundle to the private edge bucket; the product UI remains a release
owner input and is not synthesized by infrastructure.

## Prepare and apply the persistent shell

The commands below are authorized-run instructions, not evidence that they
were executed in this implementation task:

```powershell
./platform/aws/prepare-demo-control.ps1 `
  -RunId usrse26demo `
  -HostedZoneId ZREVIEWED `
  -AdminCidr 203.0.113.10/32 `
  -LifecycleRunnerImage 'REPOSITORY@sha256:REVIEWED' `
  -LifecyclePermissionsBoundaryArn 'arn:aws:iam::269624229733:policy/REVIEWED' `
  -ArtifactManifestS3Uri 's3://RELEASE-BUCKET/releases/usrse26demo/manifest.json' `
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
and age, pod readiness, ALB target health, WAF actions, Fabric state, and cost.
At persistent service error or unsafe queue state, set `READ_ONLY`. At $150,
the monitor must set read-only and start stop; $200 is an absolute no-provision
boundary.

## Stop and teardown

The stop state machine writes `READ_ONLY`, drains for 15 minutes, exports only
allowlisted evidence, detaches the CloudFront VPC origin, destroys runtime,
and performs an all-tag sweep. The static page remains. Treat any remaining
resource as a failed teardown and use the backup stop; never broaden the sweep
to pre-existing or partially tagged resources.

After billing settles for 48 hours, fill `cost-report-template.json`. After the
30-day retention window and only with `runtime-teardown-proof.json` showing
zero tagged resources:

```powershell
./platform/aws/destroy-demo-control.ps1 -RunId usrse26demo
```

The hosted zone is an input and is never deleted by either Terraform root.
