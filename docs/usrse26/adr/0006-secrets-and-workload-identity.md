# ADR 0006: Secrets and Workload Identity

- Status: Accepted for implementation
- Date: 2026-09-01

## Decision

AWS Secrets Manager stores separate API authentication, listener callback,
internal demo-control, NSG Ledger Gateway, Citizen Science Ledger Gateway,
database, Amazon MQ, and organization Fabric identity values. No shared
`application` secret exists. Separate secrets and exact IAM policies prevent a
workload from reading unrelated service credentials or another organization's
Fabric key.

EKS Pod Identity or IRSA provides short-lived AWS authorization to dedicated
Kubernetes service accounts. Automatic service-account token mounting is
disabled for workloads that do not call Kubernetes or AWS APIs. Secret values
are mounted at runtime with the Secrets Store CSI driver or an equivalently
narrow, reviewed mechanism; they are not copied into Kubernetes manifests,
container layers, Terraform variable values, logs, or retained evidence.

Local Kind generates non-production secrets at setup time, records only their
checksums and expiration, and removes them with the cluster.

## Policy boundaries

- Gateway: API authentication, listener callback, internal demo-control,
  database, and broker values; no Ledger Gateway token or Fabric key.
- Submission worker: broker credential and both organization-scoped Ledger
  Gateway tokens; no Fabric key.
- Submission listener: broker credential and listener callback value only.
- NSG Ledger Gateway: NSG Ledger token and NSG Fabric identity only.
- Citizen Science Ledger Gateway: Citizen Science Ledger token and Fabric
  identity only.
- Deployment automation: permission to update verified image digests and
  declarative revisions; no workload secret read outside exact run-scoped
  creation, population, and teardown operations.

The control plane owns all IAM roles and trust policies. Runtime Terraform is
given exact control-owned role ARNs and cannot create or mutate roles. Pod
Identity replaces the prior ALB-controller web-identity trust policy, removing
the runtime OIDC-provider and trust-policy mutation path.

## Rotation and evidence

Rotation is versioned and followed by a controlled workload rollout. Evidence
records secret identifiers only after sanitization, never values, certificates,
or sensitive resource paths. A repository and image scan must confirm that no
private key or wallet is embedded.

