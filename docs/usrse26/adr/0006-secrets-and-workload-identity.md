# ADR 0006: Secrets and Workload Identity

- Status: Accepted for implementation
- Date: 2026-09-01

## Decision

AWS Secrets Manager stores database credentials, Amazon MQ credentials, and the
two organization Fabric client credential bundles. Separate secrets and IAM
policies prevent one workload from reading another organization's Fabric key.

EKS Pod Identity or IRSA provides short-lived AWS authorization to dedicated
Kubernetes service accounts. Automatic service-account token mounting is
disabled for workloads that do not call Kubernetes or AWS APIs. Secret values
are mounted at runtime with the Secrets Store CSI driver or an equivalently
narrow, reviewed mechanism; they are not copied into Kubernetes manifests,
container layers, Terraform variable values, logs, or retained evidence.

Local Kind generates non-production secrets at setup time, records only their
checksums and expiration, and removes them with the cluster.

## Policy boundaries

- Gateway: database and its own token-signing material; no Fabric key.
- Outbox/worker: broker credential and internal Ledger Gateway credential; no
  direct Fabric key unless it is the Ledger Gateway process.
- NSG Ledger Gateway: NSG Fabric client secret only.
- Citizen Science Ledger Gateway: Citizen Science Fabric client secret only.
- Deployment automation: permission to update verified image digests and
  declarative revisions; no application secret read.

## Rotation and evidence

Rotation is versioned and followed by a controlled workload rollout. Evidence
records secret identifiers only after sanitization, never values, certificates,
or sensitive resource paths. A repository and image scan must confirm that no
private key or wallet is embedded.

