# Disposable US-RSE 2026 EKS environment

This root module creates one isolated OSC-IS evidence environment, capped at
72 hours,
in AWS account `269624229733`, region `us-west-2`. It does not import or modify
the historical OSC infrastructure.

The topology is deliberately experimental: one EKS 1.35 control plane, three
on-demand `m7i.large` workers, one NAT gateway, one private three-broker
Multi-AZ Amazon MQ for RabbitMQ 4.2 cluster, disposable encrypted volumes, eight
experiment-specific ECR repositories, and workload-scoped Secrets Manager
values exposed through EKS Pod Identity and the Secrets Store CSI driver.

The persistent control root creates every runtime IAM role, trust policy,
managed-policy attachment, and permissions boundary before a run starts.
Runtime Terraform receives only the exact role ARNs and can associate or pass
them to EKS; its lifecycle runner cannot create roles, attach policies, add
inline policies, or change trust policies.

Amazon MQ's Terraform resource persists its broker password in raw state. This
module avoids that behavior: Terraform creates the secret, a local provisioner
generates and uploads the value without logging it, and a Terraform-managed
CloudFormation stack resolves the value directly from Secrets Manager. API,
listener, demo-control, organization Ledger Gateway, database, broker, and
Fabric identity values are separate secrets with per-workload read policies.
Secret values are absent from configuration, variables, plans, and Terraform
state.

Never apply this module directly. Use the account-guarded scripts under
`platform/aws`, which create a unique local state directory, record a baseline
inventory and the approved pre-deployment planning estimate, and require
same-session destruction. Runtime automation does not use billing APIs.
