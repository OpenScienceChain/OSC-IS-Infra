# US-RSE 2026 Release Review Remediation

Date: 2026-09-11

Scope: release-review findings 1, 2, 3, 5, and 6. All work in this record was
implemented and tested locally. No AWS API, deployment, or resource mutation
was performed.

## Disposition

| Finding | Disposition | Evidence |
| --- | --- | --- |
| 1. Lifecycle IAM escalation | Remediated locally | Runtime roles, managed-policy attachments, trust policies, and boundaries are control-owned in `terraform/usrse26-control/runtime-roles.tf`. Runtime Terraform contains associations only. The lifecycle role has no `CreateRole`, `PutRolePolicy`, `AttachRolePolicy`, `UpdateAssumeRolePolicy`, or `AssumeRole`; it passes only exact roles to three approved services. S3, Secrets Manager, ECR, and other named services are scoped by exact run ARN or required run tags. See `iam-boundary-local-simulation.json`. |
| 2. Sensitive WAF logging and public control calls | Remediated locally | WAF redacts cookie, authorization, control-key, CSRF, and API-key headers. Lifecycle control, export, and metrics calls use `kubectl exec` to loopback-only internal endpoints. |
| 3. Cleanup can halt before destruction | Remediated locally | A permanently out-of-VPC cleanup CodeBuild project performs runtime destroy and sweep. State-machine catches continue through cleanup, and Python cleanup executes all steps plus network reset before propagating failures. See `local-cleanup-fault-injection.json`. |
| 5. Shared application secret | Remediated locally | API auth, listener auth, demo auth, two Ledger Gateway auth values, PostgreSQL, RabbitMQ, and Fabric identities are separate secrets. Exact per-workload IAM policies are created in the control plane. |
| 6. Credential-free build asserted, not enforced | Remediated locally | `assert_credential_free_build.py` runs before project-owned build code, fails closed on common credential sources, does not read or print values, and emits checksummed manifest evidence. The release and lifecycle scripts reject old boolean-only manifests. |

## Local verification

- Terraform validation: control and runtime modules pass.
- Checkov 3.3.9 pinned by digest: control `245 passed / 0 failed / 34 skipped`;
  runtime `70 passed / 0 failed / 35 skipped`.
- IAM local model: all 16 allow/deny cases pass, including unrelated S3 and
  Secrets Manager data, role/trust mutation, assume-role, and broad inline
  policy intersection scenarios.
- Complete US-RSE Python contract suite: 32 tests pass and one Windows-only
  symbolic-link case is skipped because this host cannot create symbolic links.
- AWS Kubernetes manifests pass client-side Kustomize rendering.

## Required live evidence

This remediation does not claim cloud validation. Before approving a real
rehearsal, repeat the IAM cases with AWS policy simulation, inspect WAF logs to
prove redaction, execute a failed-start and failed-stop teardown, and verify the
final exact-tag inventory is empty. A fresh isolated artifact build must emit
`ENFORCED_COMMON_AWS_SOURCES_ABSENT`; a workstation with local AWS credentials
is expected to fail that build preflight.
