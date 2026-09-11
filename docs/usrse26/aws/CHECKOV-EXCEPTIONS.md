# US-RSE'26 Checkov exception register

Status: approved implementation exceptions for the disposable US-RSE'26 control and runtime Terraform roots only.

The CI policy scans `terraform/usrse26-control` and `terraform/usrse26-eks` with checksum-pinned Checkov 3.3.9. Exceptions are attached to the exact Terraform resource with `checkov:skip` comments. New findings on resources without an inline exception still fail CI. The repository's legacy Terraform roots are validated separately and are outside this release's AWS deployment boundary.

## Zero-residual encryption trade-off

Checks `CKV_AWS_119`, `CKV_AWS_136`, `CKV_AWS_145`, `CKV_AWS_149`, `CKV_AWS_158`, `CKV_AWS_297`, and `CKV_AWS_58` prefer customer-managed KMS keys. This experiment uses AWS-owned or service-managed encryption at rest. A customer-managed key has a mandatory pending-deletion period that would contradict the exact zero-residual teardown requirement. The run is restricted to account `269624229733`, region `us-west-2`, an exact run ID and ownership tags, and an expiry no more than 72 hours after creation.

## Single-region disposable topology

- `CKV_AWS_144`: S3 cross-region replication would exceed the authorized `us-west-2` scope and create teardown residuals.
- `CKV_AWS_310`: the static status page is the failure fallback; a second CloudFront origin would add retained infrastructure without protecting the interactive runtime.
- `CKV_AWS_374`: the conference guest experience is intentionally public and not country-restricted.
- `CKV_AWS_39`: the EKS private endpoint is enabled. Public access is additionally required for rehearsal and is limited to the exact admin and lifecycle-runner CIDRs.

## Data minimization and bounded retention

- `CKV_AWS_18` and `CKV_AWS_86`: private S3 origins do not receive direct public requests. WAF and control-plane logs provide the necessary audit trail, with cookie and authorization headers redacted. Duplicate S3/CloudFront access-log sinks are not retained.
- `CKV_AWS_285`: Step Functions log every transition at `ALL`, use X-Ray, and deliberately set `include_execution_data = false` so guest request payloads cannot enter logs.
- `CKV_AWS_338`: WAF, lifecycle, Step Functions, and EKS logs expire after seven days; one-year retention is disproportionate to a run capped at 72 hours.
- `CKV2_AWS_11`: full VPC flow logs are not retained. Control-plane, WAF, aggregate application, authorization-denial, cost, and teardown evidence is exported instead.
- `CKV2_AWS_57`: generated application, database, broker, and Fabric credentials are destroyed within 72 hours, before a rotation interval can elapse.
- `CKV2_AWS_62`: the two buckets contain static status, explicit lifecycle state, and sanitized evidence; they do not implement object-created event processing.

## Static-analysis limitations and exact runtime controls

- `CKV_AWS_260`: port 80 reaches the private ALB only through the AWS-managed CloudFront origin-facing prefix list, never `0.0.0.0/0`.
- `CKV2_AWS_5`: the CloudFront-origin group is attached through a Kubernetes ALB annotation, and the lifecycle-runner group is attached when the control-plane CodeBuild project consumes the EKS output. Checkov cannot resolve either cross-system attachment.
- `CKV2_AWS_47`: `AWSManagedRulesKnownBadInputsRuleSet` is explicitly attached to the WAF; the graph check does not resolve the managed group.
- `CKV_AWS_300`: every control-bucket lifecycle rule aborts incomplete multipart uploads after one day; Checkov 3.3.9 misreports the third rule.
- `CKV_AWS_124`: lifecycle alarms and the independent backup-stop workflow are the notification path; the nested RabbitMQ CloudFormation stack does not add a second SNS channel.

## Lifecycle IAM boundary

Checks `CKV_AWS_286` through `CKV_AWS_290` and `CKV_AWS_355` cannot model the combined guard. The permissions boundary defines the maximum service surface needed to provision, observe, stop, destroy, and sweep the experiment. The attached policy is narrower, and the lifecycle runner fails closed unless the caller account, region, run ID, expiry, and full ownership-tag set match. It mutates or destroys only exact run-tagged resources. The Step Functions role uses `Resource = "*"` only for STS identity and AWS logging/tracing APIs that do not support resource-level scoping; all provisioner, table, topic, and scheduler targets use exact ARNs.

Any scope expansion, longer retention, different AWS account or region, reusable environment, or removal of the exact-tag teardown guard invalidates these exceptions and requires a new security review.
