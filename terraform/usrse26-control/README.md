# US-RSE 2026 persistent demo control plane

This root creates the low-cost resources that survive disposable EKS runtime
teardown: private S3 status content, CloudFront, WAF, ACM validation, the exact
Route 53 record, lifecycle state, one-time schedules, Step Functions,
CodeBuild, notifications, evidence storage, and the $200 budget ceiling.

The application runtime remains in `../usrse26-eks`. The lifecycle runner must
attach the internal ALB as a CloudFront VPC origin only after the public canary
passes, then detach that origin before runtime destroy. Until then, and after
destroy, CloudFront serves the static status/fallback page.

Do not apply this root directly. Use `platform/aws/prepare-demo-control.ps1`
and `apply-demo-control.ps1`; both fail closed on the AWS identity. The
us-east-1 provider is limited to the service-required CloudFront ACM and WAF
control planes. Runtime and lifecycle resources remain in `us-west-2`.

Required external inputs are deliberately not defaulted: the existing hosted
zone ID, a reviewed lifecycle runner image digest, a versioned deployment
manifest URI and checksum, and one trusted EKS administrator `/32`.
