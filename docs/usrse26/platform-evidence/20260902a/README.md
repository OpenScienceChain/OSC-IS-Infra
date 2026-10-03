# AWS EKS Evidence Run 20260902a

This directory contains sanitized engineering evidence from the disposable
OSC-IS AWS experiment in account `269624229733`, region `us-west-2`. The run
used EKS 1.35, private Amazon MQ for RabbitMQ, PostgreSQL on encrypted EBS,
self-managed Argo CD, and a two-organization Hyperledger Fabric network for
NSG and Citizen Science.

The environment was prepared at `2026-09-02T02:30:36Z`, the integrated
validation completed at `2026-09-02T04:27:08Z`, and verified teardown completed
at `2026-09-02T04:45:31Z`. The full guarded session lasted 2.25 hours. At the
reviewed hourly estimate, the run's conservative upper-bound cost was USD 1.41;
provider billing data was not yet available in real time.

## Demonstrated behavior

- Deterministic artifact and workflow creation, updates, and history.
- Organization-scoped API authorization and direct Fabric cross-organization
  denial using separate NSG and Citizen Science service identities.
- Transactional-outbox recovery after a private RabbitMQ outage, including an
  API degraded start and worker restart, with no duplicate ledger revision.
- Ledger Gateway recovery and alternate-peer transaction processing.
- Argo CD drift detection/self-healing, controlled rollout, and rollback to a
  known-good immutable revision.
- Digest-addressed OSC workloads, runtime digest resolution for AWS-managed
  add-ons, private data-plane services, and no Kubernetes LoadBalancer.

## Measured results

| Experiment | Result |
|---|---:|
| Ledger Gateway interruption | recovered in 46 seconds |
| RabbitMQ isolation plus worker restart | recovered in 223 seconds |
| NSG peer interruption | alternate peer accepted work in 6 seconds |
| GitOps drift self-heal | 3 seconds in the retained integrated run |
| Controlled rollout | 13 seconds |
| Known-good rollback | 13 seconds |

Every recovered artifact had exactly one ledger revision. The post-rollback
artifact and workflow scenario also passed.

## Boundaries

This is experimental evidence, not a claim of production readiness, researcher
adoption, measured user impact, high availability, performance, or a completed
disaster-recovery design. The experiment used a single-instance Amazon MQ
broker and three EKS worker nodes. No real researcher data was used.

The retained files omit credentials, secret values, certificates, private
keys, Terraform state, raw IAM identity output, and private endpoint details.

Terraform destroyed 73 managed resources. The final authoritative AWS
inventory exactly matched the baseline, with no added resource and no RunId
remnant. Three Amazon MQ log groups left outside the broker's CloudFormation
stack were identified by the parity gate and explicitly deleted before the
final proof was accepted.
