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
  synchronous CodeBuild, budget notifications, retention, and evidence stores.
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
