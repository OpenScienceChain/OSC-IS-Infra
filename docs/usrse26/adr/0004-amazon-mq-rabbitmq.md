# ADR 0004: Amazon MQ for RabbitMQ in AWS

- Status: Accepted for implementation
- Date: 2026-09-01

## Context

The historical broker runs on EC2 and requires manual VM configuration. The
experiment needs to test managed messaging while preserving existing AMQP event
contracts.

## Decision

Use a private, TLS-only, single-instance Amazon MQ for RabbitMQ broker for the
short AWS evidence run. Credentials are generated, stored in Secrets Manager,
and supplied only to the Gateway and messaging workers through workload identity.
Security groups permit AMQPS only from EKS workloads through the selected VPC
path. The management endpoint is not publicly exposed.

Use durable exchanges and queues, persistent messages, publisher confirms,
manual acknowledgements, bounded exponential retry, dead-letter queues, and
idempotent consumers. Redelivery after an uncertain ledger result reconciles the
idempotency key before retrying a commit.

Local Kind uses RabbitMQ with the same topology and TLS behavior where practical.
Environment-specific endpoints do not change routing names or application
semantics.

## Consequences

Single-instance Amazon MQ is cheaper and sufficient for an ephemeral failure
experiment, but it is not an HA design. A production candidate would use a
multi-AZ RabbitMQ cluster, quorum queues, tested broker replacement, backups,
alarms, and capacity/load evidence. The AWS run tests a temporary client or peer
failure; it does not deliberately destroy the managed broker.

