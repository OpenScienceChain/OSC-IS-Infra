# ADR 0001: Disposable EKS Experiment

- Status: Accepted for implementation
- Date: 2026-09-01

## Context

The historical deployment combines ECS services, EC2 RabbitMQ, and an external
Fabric VM. A US-RSE evidence run needs a reproducible environment that can test
deployment, recovery, and rollback without claiming a production migration.

## Decision

Create a dedicated, short-lived VPC and EKS cluster in `us-west-2`, managed by a
dedicated Terraform state. Use two Availability Zones, private worker subnets,
one NAT gateway for the experiment, encrypted node disks, restricted EKS API
access, EKS control-plane logging, and immutable ECR image digests.

Use a small three-node topology initially because Fabric, Argo CD, and the
application need scheduling separation and enough memory to complete the
reference scenario. Nodes may use Spot only after a successful on-demand local
equivalent and when interruption does not invalidate the evidence objective.

Every resource receives the required experiment tags, including a unique RunId
and ExpiresAt value. No existing VPC, subnet, IAM role, broker, database, volume,
or application resource is imported or modified.

## Consequences

- The environment is reproducible and has an unambiguous ownership boundary.
- A NAT gateway and EKS control plane add hourly cost, so the run is limited to
  eight hours and destroyed in the same session.
- This topology tests platform behavior; it does not establish production scale,
  availability, operations staffing, backup, disaster recovery, or support.
- The historical VM path remains available as a rollback option outside this
  experiment.

## Rejected alternatives

- Reuse the historical VPC: lower setup cost but unsafe ownership and teardown.
- Reuse stopped RabbitMQ EC2 instances: preserves the operational burden being
  evaluated and creates ambiguous experiment ownership.
- Use a local-only demo: insufficient evidence for AWS deployment and teardown.
- Adopt a long-running cluster: incompatible with cost and cleanup boundaries.

