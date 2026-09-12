# US-RSE 2026 Platform Engineering Work

This directory contains the design, implementation notes, and sanitized evidence
for the OSC-IS platform experiment supporting the US-RSE 2026 talk.

OSC-IS remains an experimental research software product. These documents must
not be used to claim production readiness, researcher adoption, or measured user
impact.

## Scope

- Run the application and a two-organization Hyperledger Fabric network locally
  on Kind.
- Reproduce the same deployment shape in a short-lived AWS EKS environment.
- Use Amazon MQ for RabbitMQ in AWS and an in-cluster broker locally.
- Manage application workloads through self-managed Argo CD.
- Demonstrate organization-scoped authorization, provenance, recovery, rollout,
  rollback, and complete teardown.
- Preserve all existing supply-chain security controls.

## Documents

- [Current state](current-state.md)
- [Risk register](risk-register.md)
- [Acceptance and evidence contract](acceptance-and-evidence.md)
- [ADR 0001: Disposable EKS experiment](adr/0001-disposable-eks-experiment.md)
- [ADR 0002: Fabric identity model](adr/0002-fabric-identity-model.md)
- [ADR 0003: Multi-organization authorization](adr/0003-multi-organization-authorization.md)
- [ADR 0004: Messaging topology](adr/0004-amazon-mq-rabbitmq.md)
- [ADR 0005: GitOps ownership](adr/0005-argocd-gitops.md)
- [ADR 0006: Secrets and workload identity](adr/0006-secrets-and-workload-identity.md)
- [ADR 0007: Network boundaries](adr/0007-network-boundaries.md)
- [ADR 0008: Experimental persistence](adr/0008-experimental-persistence.md)

## Evidence

- [2026-09-11 interactive-demo AWS rehearsal](platform-evidence/20260911-usrse26r1/README.md)

Evidence belongs under `platform-evidence/<run-id>/`. Each run must include its
environment, exact source revisions, test results, timings, planning estimate,
and teardown proof. Raw credentials, certificates, private keys, tokens, sensitive
Terraform state, and unsanitized AWS identity output are prohibited.

