# ADR 0004: Amazon MQ for RabbitMQ in AWS

- Status: Accepted for the interactive demonstration
- Date: 2026-09-10

## Context

The historical broker runs on EC2 and requires manual VM configuration. The
experiment needs to test managed messaging while preserving existing AMQP event
contracts.

## Decision

Use a private, TLS-only, three-broker Multi-AZ Amazon MQ for RabbitMQ cluster
for the 72-hour interactive demonstration. Credentials are generated, stored in Secrets Manager,
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

The Multi-AZ broker removes the previous single-instance limitation and permits
a controlled broker-path recovery observation. It still does not establish
product high availability: the database remains single-AZ, the environment is
short-lived, and no disaster-recovery claim is in scope. Quorum policy,
idempotency, load behavior, alarms, and teardown must be evidenced during the
authorized rehearsal.

