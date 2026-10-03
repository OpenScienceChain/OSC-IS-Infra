# ADR 0003: Active Membership Authorization

- Status: Accepted for implementation
- Date: 2026-09-01

## Context

The current API model assigns one organization and global roles directly to a
user. This cannot represent a cross-organization contributor safely and makes a
JWT organization claim too authoritative.

## Decision

Model `User`, `Organization`, and `OrganizationMembership`. A membership has an
organization-scoped role set, active/inactive status, and audit timestamps. A
request token identifies a user and selected active organization, but the API
reloads the active membership before authorization. Caller-provided organization,
role, MSP, or Fabric identity values cannot override server context.

Organizations are deactivated or archived. They are not hard-deleted when doing
so could remove users, artifacts, workflows, audit entries, or provenance links.

## Visibility rules

- Public artifacts and workflows are discoverable across organizations.
- Private records and histories are visible only to an active authorized member
  of the owner organization.
- Creation and mutation use roles in the active membership only.
- A cross-organization user must explicitly select an active organization and
  receives no union of roles from other memberships.
- Organization administration is separate from provenance submission.
- Every accepted mutation records actor user, active organization, request ID,
  operation, and server timestamp.

## Role scenarios

- NSG administrator: memberships and organization settings plus submission.
- NSG principal investigator or submitter: create and update permitted records.
- NSG collaborator: read and collaborate; cannot create users or alter roles.
- Citizen Science administrator: administration within Citizen Science only.
- Citizen Science contributor: create/update within Citizen Science only.
- Cross-organization member: one role set at a time according to active context.

## Consequences

Existing single-organization users require a data migration that creates one
membership from their current organization and roles. Tokens created before the
migration are invalidated through a token-version or migration cutoff. API tests
must cover inactive memberships, cross-org switching, forged claims, and
visibility at controller and repository boundaries.

