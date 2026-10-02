# ADR 0002: Organization-Scoped Fabric Service Identities

- Status: Accepted for implementation
- Date: 2026-09-01

## Threat model

Protected assets are Fabric private keys, the ability to submit endorsed ledger
transactions, organization-confidential records, immutable provenance metadata,
and the attribution trail connecting a portal user to a Fabric transaction.

Relevant threats include a forged portal claim, a compromised worker or bridge,
cross-organization identity use, leaked wallet files, a revoked user retaining
ledger access, replayed submissions, and a misleading claim that one service
certificate proves an individual user's cryptographic authorship.

## Alternatives

| Model | Strength | Cost and limitation |
|---|---|---|
| One Fabric identity per portal user | strongest individual ledger signature and revocation | certificate lifecycle, wallet delivery, Kubernetes secret count, and migration complexity are high |
| One narrow service identity per organization | simple private secret boundary and clear MSP isolation | individual attribution relies on trusted Gateway metadata and audit records |
| Hybrid | per-user signatures for selected sensitive operations | two authorization paths and policy complexity without a demonstrated requirement |

## Decision

Use one narrowly scoped Fabric client service identity per organization for this
experiment: `NSGMSP` and `CitizenScienceMSP`. The API Gateway authenticates the
portal user, revalidates the active membership and organization-scoped roles,
and creates signed-internal request metadata containing user ID, organization
ID, request correlation ID, operation, and timestamp.

The Ledger Gateway selects identity from trusted organization context, never
from a caller-provided MSP, certificate path, role, or identity label. Chaincode
derives the submitting MSP from Fabric client identity and enforces ownership,
allowed transitions, stable keys, and idempotency. Metadata organization and the
Fabric MSP must agree.

This proves organization-level ledger submission. It does not prove that the
individual portal user personally controlled the Fabric private key.

## Credential lifecycle

- Fabric CAs issue separate short-lived client certificates for each org service.
- AWS stores keys and certificates in Secrets Manager and exposes each only to
  the matching Ledger Gateway workload identity.
- Local Kind uses generated test certificates in ephemeral Kubernetes secrets.
- Images, source, Terraform inputs, logs, and evidence never contain private keys.
- Rotation creates a new secret version, rolls the one organization workload,
  verifies connectivity, and retires the previous certificate.
- Revocation updates the CA CRL and restarts affected clients before accepting
  new work. The queue is paused or drained during emergency revocation.

## Authorization matrix

| Operation | Gateway authorization | Fabric identity | Chaincode rule |
|---|---|---|---|
| Create artifact/workflow | active submitter or admin membership | active org service | MSP equals record org; ID unused or idempotent match |
| Update owned private record | authorized member for active org | active org service | MSP equals owner org; transition valid |
| Read private record/history | active authorized membership | owner org service | MSP equals owner org |
| Read public record/history | authenticated discovery policy | requesting org service | visibility is public |
| Manage portal memberships | org admin in Gateway only | none | not a ledger operation |

## Migration path

Add a certificate reference to selected memberships, enroll per-user identities
for operations that require personal cryptographic signatures, and extend
chaincode metadata to distinguish service and individual assurance levels. The
organization service path remains available for automated ingestion.

