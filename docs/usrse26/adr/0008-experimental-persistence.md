# ADR 0008: Disposable PostgreSQL for the Evidence Run

- Status: Accepted for implementation
- Date: 2026-09-01

## Context

The experiment needs PostgreSQL to exercise membership, outbox, and application
state. It does not need durable researcher data, long-term backup, or a database
migration service-level objective.

## Decision

Run one PostgreSQL instance inside Kind and EKS with an ephemeral or encrypted
disposable volume. In AWS, the password originates in Secrets Manager and the
volume is encrypted. Test data is deterministic and contains no real user data.
The database and volume are deleted at teardown.

## Consequences

This reduces cost and setup time while preserving the application behavior under
test. It is not a production database architecture and does not test RDS failover,
backup, point-in-time recovery, multi-AZ availability, or database operations.

A production candidate should use private Amazon RDS for PostgreSQL or Aurora,
multi-AZ where required, automated backups, tested restore, monitoring, patch
management, and a migration policy. The historical Terraform's snapshot-based
hibernation pattern remains relevant evidence but is separate from this run.

