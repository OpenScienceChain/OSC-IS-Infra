# Ephemeral Fabric test environment

This profile creates a short-lived EKS 1.35 cluster and deploys the canonical
`OSC-Chaincode` into a two-peer-organization Hyperledger Fabric 2.5.15 network
with three Raft orderers. It is for deployment rehearsal, compatibility tests,
multi-organization demonstrations, and evidence capture. It is not the
production network.

The Fabric topology comes from a pinned commit of Hyperledger's official
`fabric-samples/test-network-k8s`. The script installs current, pinned
cert-manager and the final ingress-nginx chart in ClusterIP mode. Ingress-nginx
was retired in 2026, so this dependency is acceptable only inside this
disposable test profile and must not become a production ingress decision.

No long-lived AWS credentials are written to a VM or container. GitHub Actions
assumes a deployment role through OIDC, limits the EKS API to the runner's
temporary `/32`, and receives cluster access through an EKS access entry.
Workload nodes use an EC2 instance role.

## Cost boundary

Prices checked in `us-west-2` on 2026-07-31:

| Item | Hourly estimate |
|---|---:|
| EKS standard-support control plane | $0.1000 |
| Three on-demand `t3.large` nodes | $0.2496 |
| Compute subtotal | $0.3496 |

An eight-hour rehearsal is about `$2.80` plus EBS, logs, and network traffic.
A full day is about `$8.39` plus those extras. The default operating rule is:
create, test, collect evidence, and destroy on the same day.

Amazon MQ is independent of this profile. A single `mq.m7g.medium` RabbitMQ
broker was `$0.1367/hour` on the same date, plus storage and traffic.

## Lifecycle

1. Run the manual EKS workflow with `plan`, then `apply` and environment approval.
2. Run the Fabric deployment workflow and retain its evidence artifact.
3. Run integration and multi-organization scenarios.
4. Destroy the Fabric namespace.
5. Run the EKS workflow with `destroy` before the recorded `ExpiresAt` time.

The hybrid OSC-DEV VM remains a supported ledger target through the adapter.
Switching the adapter URL/route configuration changes the target without
changing API Gateway business logic or moving Fabric identities into workers.
