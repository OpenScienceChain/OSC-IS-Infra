# AWS interactive-demo cost and teardown gate

## Reviewed topology

The disposable run uses one EKS 1.35 control plane, three on-demand
`m7i.large` nodes in three AZs, one NAT gateway and public IPv4 address, a
private three-broker Multi-AZ `mq.m7g.medium` RabbitMQ 4.2 cluster, encrypted
gp3 volumes, short-lived logs, and seven run-scoped ECR repositories. It
creates no RDS instance, public application load balancer, or standalone VM.
The static CloudFront/S3/WAF control shell is retained separately for at most
30 days.

## Cost ceiling

| Component | Estimated USD/hour |
| --- | ---: |
| EKS control plane | 0.1000 |
| Three `m7i.large` nodes | 0.3024 |
| Three Amazon MQ `mq.m7g.medium` brokers | 0.4101 |
| NAT gateway | 0.0450 |
| NAT public IPv4 | 0.0050 |
| EBS, logs, ECR, edge, lifecycle, and transfer allowance | 0.0800 |
| **Estimated total** | **0.9425** |

Seventy-two hours cost approximately **$67.86**. A 25 percent contingency plus
a $20 rehearsal/control allowance produces **$104.83**, within the approved
$90-$120 planning range. Notify at $75, warn and prepare read-only at $125,
force read-only and teardown at $150, and reject all provisioning at $200.
These are planning estimates based on the reviewed 2026-09-01 rates; actual
Cost Explorer data can lag and must be finalized 48 hours after stop.

## Teardown invariant

Every run records a complete relevant-resource inventory before apply. Runtime
destroy must first detach its CloudFront VPC origin, then remove the EKS cluster
and node group, Amazon MQ CloudFormation stack,
NAT gateway, Elastic IP, experiment VPC, EBS volumes and snapshots, ECR images
and repositories, Secrets Manager secrets, IAM roles, ALB, and CloudWatch log
groups. The all-tag sweep must report zero remaining runtime resources. The
static edge/control plane remains useful until its 30-day expiry and is removed
only after `runtime-teardown-proof.json` passes. The existing hosted zone is
never deleted. Any mismatch is a failed run, not a warning.
