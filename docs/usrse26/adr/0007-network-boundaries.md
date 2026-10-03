# ADR 0007: Private Data and Administrative Planes

- Status: Accepted for implementation
- Date: 2026-09-01

## Decision

Keep PostgreSQL, RabbitMQ, Fabric peers, orderers, certificate authorities,
Ledger Gateways, and Argo CD private. Local access uses `kubectl port-forward` to
specific services. AWS evidence uses port forwarding or a narrowly controlled
temporary ingress only when a browser artifact is essential.

EKS nodes use private subnets. The EKS API enables its private endpoint and a
public endpoint restricted to the operator's current CIDR for the short run.
Amazon MQ has no public endpoint. Security groups allow only required source and
destination pairs. Kubernetes NetworkPolicies default-deny ingress and egress,
then permit DNS and explicit application paths.

TLS is mandatory for Amazon MQ and Fabric Gateway. PostgreSQL TLS is enabled in
AWS. Internal HTTP between tightly scoped local services may be allowed in Kind
only when the limitation is recorded; the AWS target uses authenticated service
traffic where supported.

## Required path inventory

- WebApp to Gateway API.
- Gateway to PostgreSQL and RabbitMQ.
- Worker to RabbitMQ and organization Ledger Gateway.
- Ledger Gateway to matching Fabric peer Gateway endpoint.
- Listener to RabbitMQ and Gateway internal endpoint.
- Argo CD to Git source and Kubernetes API.
- DNS and required AWS API endpoints from authorized workloads.

No broad namespace-to-namespace or `0.0.0.0/0` administrative ingress is
accepted. Temporary egress needed for bootstrap is removed or narrowly scoped
after installation where practical.

