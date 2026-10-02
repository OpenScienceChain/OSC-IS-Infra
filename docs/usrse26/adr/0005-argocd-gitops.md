# ADR 0005: Argo CD Owns Application Reconciliation

- Status: Accepted for implementation
- Date: 2026-09-01

## Decision

Run self-managed Argo CD in local Kind and EKS. Argo CD owns declarative
application workloads, configuration references, service accounts, policies,
and ingress-free internal services. Images are referenced by immutable digest.

Terraform owns AWS and EKS infrastructure. A pinned Fabric bootstrap process
owns the experimental Fabric network because the upstream test-network lifecycle
includes certificate generation and channel operations that are not safely
converted into ordinary Kubernetes reconciliation during this campaign. Argo CD
owns the OSC application workloads that communicate with Fabric.

The evidence scenario records:

1. known-good Git revision and image digest;
2. initial synchronized and healthy state;
3. a controlled declarative drift and Argo correction;
4. a new immutable application revision rollout;
5. health verification;
6. rollback to the known-good Git revision and digest;
7. measured convergence and rollback timings.

## Local source

Before any remote branch is pushed, local Argo CD reads a read-only temporary Git
endpoint backed by the isolated worktree. The endpoint contains no credentials
and is removed during local teardown. AWS Argo CD uses the reviewed feature
branch only after local gates pass and a draft pull request is opened.

## Consequences

This demonstrates GitOps control for the OSC application, not a claim that every
Fabric lifecycle command is declarative. Drift outside Argo's ownership remains
Terraform or bootstrap-script responsibility and is documented in evidence.

