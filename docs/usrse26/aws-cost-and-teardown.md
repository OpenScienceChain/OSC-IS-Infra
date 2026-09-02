# AWS experiment cost and teardown gate

## Reviewed topology

The disposable run uses one EKS 1.35 control plane, three on-demand
`m7i.large` nodes, one NAT gateway and public IPv4 address, one private
single-instance `mq.m7g.medium` RabbitMQ 4.2 broker, encrypted gp3 volumes,
short-lived logs, and six run-scoped ECR repositories. It creates no RDS
instance, public load balancer, or standalone application VM.

## Cost ceiling

| Component | Estimated USD/hour |
| --- | ---: |
| EKS control plane | 0.1000 |
| Three `m7i.large` nodes | 0.3024 |
| Amazon MQ `mq.m7g.medium` | 0.1367 |
| NAT gateway | 0.0450 |
| NAT public IPv4 | 0.0050 |
| EBS, logs, ECR, and transfer allowance | 0.0400 |
| **Estimated total** | **0.6291** |

Eight hours cost approximately **$5.03**. A 25 percent contingency produces a
reviewed maximum of **$6.29**, below the $15 per-run ceiling. The campaign stops
before $75 and preserves a separate $75 rehearsal reserve. Prices are the
verified us-west-2 values as of 2026-09-01; actual Cost Explorer data can lag.

## Teardown invariant

Every run records a complete relevant-resource inventory before apply. Destroy
must remove the EKS cluster and node group, Amazon MQ CloudFormation stack,
NAT gateway, Elastic IP, experiment VPC, EBS volumes and snapshots, ECR images
and repositories, Secrets Manager secrets, IAM roles, and CloudWatch log group.
The final inventory must contain no resource absent from the baseline and no
identifier containing the run prefix. A mismatch is a failed run, not a warning.
