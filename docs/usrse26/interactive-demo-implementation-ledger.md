# Interactive Demo Infrastructure Implementation Ledger

## Implemented locally

- Disposable runtime now spans three AZs, fixes the submission and history
  worker counts at four, and
  requests a three-broker Multi-AZ Amazon MQ RabbitMQ deployment.
- GitOps workloads use multiple replicas, node/zone spreading, disruption budgets,
  non-root containers, immutable image placeholders, narrowed network paths,
  two organization-scoped Ledger Gateways, and two history-worker paths.
- AWS Load Balancer Controller uses a dedicated EKS Pod Identity role; the
  application ingress is internal and uses pod-IP targets.
- A separate persistent Terraform root defines the private S3/CloudFront/WAF
  status shell, lifecycle state, one-time and backup schedules, Step Functions,
  synchronous CodeBuild, lifecycle-failure notifications, retention, and evidence
  stores. `TIME_BOUNDED` mode uses no AWS Budget or billing API.
- Guarded scripts prepare, policy-check, apply, and eventually remove the
  persistent control plane without touching the hosted zone.
- CloudWatch alarms notify on lifecycle build failures, failed start/stop/
  monitor executions, and exhausted scheduler invocations.
- The lifecycle contract requires a checksum-bound WebApp bundle for the S3
  edge and immutable digests for every runtime image before `START` may write.
- The control root owns every runtime role, trust policy, policy attachment,
  the lifecycle permissions boundary, and the exact lifecycle-runner ECR
  repository. Runtime Terraform can pass and associate fixed roles but cannot
  create or mutate IAM identities.

## Release-owner inputs still required

| Interface | Owner | Fail-closed behavior |
| --- | --- | --- |
| Lifecycle runner image digest | Infra release owner | CodeBuild cannot be planned without a digest |
| AWS LBC image digest | Infra release owner | runtime plan and GitOps render fail |
| Product image digests and source revisions | product release owner | artifact manifest render fails |
| Guest/demo API contracts and hard-close configuration | API Gateway owner | canary must fail; status cannot become OPEN |
| Public UI demo route/status behavior | WebApp owner | QR/browser gate fails |
| Artifact/workflow canary and organization-denial commands | E2E owner | start cleanup runs instead of OPEN |
| Hosted zone ID and notification endpoints | authorized operator | control plan is not created or notifications remain unconfirmed |
| Reviewed lifecycle IAM plan and Terraform-owned permissions boundary | Infra release owner | control plan policy and independent review must pass before apply |

## Evidence boundary

Terraform validation and local tests establish only `Implemented`. Kind can
establish `Locally validated` after product contracts are integrated. Nothing
in this branch establishes `AWS demonstrated`, production readiness, high
availability, disaster recovery, adoption, or measured researcher benefit.

No AWS resource or protected branch was changed while producing this ledger.

See `interactive-demo-local-verification.md` for the exact checks performed and
the product-interface blocker that prevents an honest end-to-end claim today.

## Live `usrse26r1` recovery findings (2026-09-14)

The first live AWS run demonstrated several deployment-contract gaps that the
next showtime rehearsal must close before claiming a repeatable START:

- the EKS-managed security group needs a narrowly bounded bootstrap-tag path;
- EKS `RunInstances` authorization is evaluated independently for the instance,
  launch template, AMI, subnet, security group, and volume resources;
- the correct inventory action is `tag:GetResources`;
- the lifecycle runner must apply `platform/gitops/aws/storage-class.yaml`
  before Fabric PVCs request `gp3-osc`;
- moving CodeBuild into the runtime VPC also requires the documented ENI
  create/use/permission/delete actions, including CodeBuild's wildcard-resource
  delete preflight while real subnet and service constraints remain enforced;
- the fresh-create Terraform plan policy correctly rejects a no-create retry,
  so a bounded phase-resume path is required after a partial successful apply;
- Fabric certificate data and peer/orderer rollouts require explicit readiness
  and timeout handling; retry must preserve an existing channel and resume at
  the first incomplete chaincode operation.
- recovery helpers must use fail-fast command boundaries so a trailing success
  marker cannot mask an earlier failed lifecycle phase;
- an ephemeral Fabric recovery runner must re-enroll the already-registered
  organization admins before rebuilding organization wallet documents;
- the lifecycle image's Python compatibility floor requires deterministic byte
  writes instead of `Path.write_text(..., newline=...)`;
- recovery-created immutable Kubernetes objects must use byte-for-byte frozen
  values (including the artifact's serialized `ExpiresAt` timestamp) before
  Argo CD can report `Synced`;
- `cloudfront:CreateVpcOrigin` with tags also evaluates the dependent
  `cloudfront:TagResource` action, which must remain bounded by the exact run
  request tag in both the lifecycle identity policy and permissions boundary.
- generated Fabric package-ID calculation must prefer the GNU/Linux
  `sha256sum` utility and use `shasum -a 256` only as a portable fallback;
- a recovery build must independently verify the presence of all four CCAAS
  Deployments/Services and committed discovery metadata before calling the
  official CANARY action.

The live recovery used only frozen artifact revisions and the existing exact
run resources. It did not build new application sources, create a replacement
runtime, push, or merge. The detailed event and IAM sequence is maintained in
`platform-evidence/20260911-usrse26r1/aws/LIVE-RESUME-STATUS-20260914.md`.

## Live teardown verified (2026-09-15)

The runtime is `DESTROYED_AND_VERIFIED` at `2026-09-15T15:47:03Z`, with zero
active residual resources and healthy static `READ_ONLY`. The final evidence
summary is `platform-evidence/20260911-usrse26r1/aws/RUNTIME-TEARDOWN-VERIFICATION-20260915.json`.
Scheduled STOP did not complete unattended; bounded operator recovery was
required. The frozen runner image was not rebuilt and these source changes
are not a new release claim.

Implemented/tested corrections: preserve the run input across the five STOP
CodeBuild results; reset CodeBuild VPC placement with `{}`; permit
`ecr:DeleteLifecyclePolicy` only on exact-run repositories in identity and
boundary; inventory the eight repositories by explicit name, treating only
not-found as absence; retain public `READ_ONLY` after marking lifecycle
`CLOSED`; and hash the exact canonical UTF-8 export bytes, with an explicit LF
write on every host. Final suite: 60 passed, one skipped, 24 subtests passed.

Remaining release blockers discovered but not generalized during teardown:
notification-success paths also need explicit result handling to preserve
input; individual `aws_ec2_tag` destruction must not remove the authorization
tags before dependent removals; MQ-managed ENI cleanup needs a reviewed exact
service-authority design; and controller-owned security-group cleanup must
be deterministic. NAT/EIP eventual consistency also required one fresh
Terraform retry. Close these under a reviewed fault-injection rehearsal,
without broadening runtime permissions or silently replacing frozen images.
