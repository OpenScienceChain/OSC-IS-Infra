# US-RSE'26 Interactive OSC-IS Demonstration

Status: Approved implementation plan  
Owner: `OSC IS SR26 - Interactive Web Site`  
Target AWS account: `269624229733`  
Target region: `us-west-2`  
Public URL: `https://demo.osc-staging.org`

## Purpose and Evidence Boundary

Build a temporary, isolated OSC-IS environment that conference attendees can
open from a QR code, use without creating an account, and explore through the
real Web App, API Gateway, asynchronous services, Ledger Gateway, and
Hyperledger Fabric implementation.

The demonstration is intended to collect formative usability and operational
evidence. It does not establish community adoption, production readiness,
high availability, disaster recovery, or a general performance claim.

The live window is:

- Start: October 20, 2026 at 8:00 AM Pacific time.
- End: October 23, 2026 at 8:00 AM Pacific time.
- Maximum active duration: 72 hours.
- Planned capacity: 100 concurrent browser sessions and 300 total sessions.

The environment must start and stop without manual intervention. Any retained
AWS resources must have an explicit expiration policy and must not keep the
expensive runtime alive after the demonstration.

## Attendee Experience

1. A QR code opens the stable demo URL before, during, and after the event.
2. The status page shows `SCHEDULED`, `PREPARING`, `OPEN`, `READ_ONLY`, or
   `CLOSED`, with the relevant time and a clear nontechnical explanation.
3. During `OPEN`, the attendee selects either `Neuroscience Gateway` or
   `Citizen Science`.
4. The server creates a random, short-lived guest identity bound to that
   organization. The attendee does not enter a username, password, name, or
   email address.
5. The attendee may select a local file of at most 10 MiB. SHA-256 is computed
   in the browser. File contents and the original filename never leave the
   device. The application submits only the fingerprint, size, extension, a
   generated manifest name, and controlled research-context selections.
6. Public artifact fields use controlled selections. Do not allow links, HTML,
   original filenames, or arbitrary artifact descriptions.
7. The attendee can inspect confirmation status, transaction identifier,
   organization, contributor alias, file-verification result, and provenance
   history.
8. The attendee can create a workflow linking one to three artifacts from the
   selected organization and inspect its resulting history.
9. A public counter may show anonymous browser sessions, confirmed artifacts,
   confirmed workflows, and history views.
10. An optional three-question survey is offered, with one private free-text
    comment of at most 300 characters.

Both organizations are public demonstration spaces. Anyone may browse both.
Writes remain bound to the organization selected when the guest session was
created.

## Identity and Authorization

Preserve the existing authenticated product path. Do not remove or weaken
normal authentication. Add a narrowly scoped `DEMO_CONTRIBUTOR` role that may:

- create an artifact in its assigned demonstration organization;
- create a workflow in that same organization; and
- inspect public artifact, workflow, and provenance history.

It may not update or delete records, administer users, change roles, select a
different organization after session creation, invoke internal endpoints, or
perform operations outside the public demonstration contract.

Use a 30-minute session token in a `Secure`, `HttpOnly`, `SameSite=Strict`,
`__Host-` cookie. Require an explicit CSRF header for mutations and exact-origin
CORS. Silent renewal is allowed only while the demonstration is open and must
never extend a session beyond the configured closing time. The server, not the
browser, is authoritative for organization membership and capability checks.

Required interfaces:

- `GET /demo/status`
- `POST /demo/session`
- `POST /demo/session/refresh`
- `GET /demo/counters`
- `POST /demo/events`
- `POST /demo/feedback`

`POST /demo/session` accepts only the two allowlisted organization identifiers.
`POST /demo/events` accepts only an allowlisted event schema. Feedback ratings
and the optional comment may be submitted once per session.

The EKS implementation uses organization-scoped Ledger Gateways. Do not
reintroduce the VM-oriented OSC-API adapter, OSC-Docker runtime, or an on-prem
network dependency into this demonstration.

## AWS Architecture

Keep a low-cost edge shell available around the live window:

- private S3 origin;
- CloudFront;
- AWS WAF;
- ACM certificate;
- Route 53 record; and
- strict browser security headers and a static status/fallback page.

Create a separate, consistently tagged demonstration runtime with its own VPC,
Terraform state, EKS resources, secrets, database, message broker, Fabric
network, logs, and reports. Reuse the existing hosted zone but never delete it.
Do not reuse the earlier VM route, credentials, or network path.

The live topology is expected to include:

- three private EKS worker nodes;
- three-broker Multi-AZ Amazon MQ for RabbitMQ;
- three Fabric orderers;
- two Fabric peers per organization;
- at least two replicas of the API Gateway, submission workers, submission
  listeners, history workers, and organization-scoped Ledger Gateways; and
- a single-AZ PostgreSQL database, clearly documented as non-production and
  outside any high-availability claim.

Replace the earlier NodePort/NLB single-healthy-target path with an internal
Application Load Balancer managed by AWS Load Balancer Controller using pod IP
targets. Apply topology spread or anti-affinity, readiness gates, and Pod
Disruption Budgets where appropriate.

## Automated Lifecycle

Use one-time EventBridge Scheduler invocations, Step Functions, and synchronous
CodeBuild jobs. The workflow must be idempotent and preserve a machine-readable
run ID.

### Start

1. Verify AWS account `269624229733` and region `us-west-2` before every write.
2. Apply the tagged Terraform stack.
3. Deploy pinned images through Argo CD.
4. Seed the two public demonstration organizations and controlled field values.
5. Execute a real artifact and workflow canary through the public application
   path.
6. Change the status to `OPEN` only when all gates pass.

On start failure, retry at most twice, keep the static fallback available, send
the configured notification, and tear down an incomplete runtime when it cannot
be made healthy safely.

### Active Window

Run browser canaries and monitor request failures, queue depth, queue age,
end-to-end confirmation time, pod readiness, ALB target health, WAF actions,
and the state of the Fabric network. Switch to `READ_ONLY` when a configured
global limit, safety threshold, or persistent service error is reached.

### Stop

1. Change the site to `READ_ONLY`.
2. Allow a 15-minute queue and transaction drain.
3. Export metrics, sanitized survey data, logs required for the report, resource
   inventory, and final Terraform state evidence.
4. Destroy the tagged runtime.
5. Verify that no tagged runtime resource remains.

Schedule an independent backup stop two hours later. The runtime does not query
billing data. Record actual billed cost only if a human later reconciles a
CloudBank or account billing record, and never block teardown on that optional
reconciliation. Retain security logs for seven days. Retain
sanitized telemetry, reports, the static edge shell, and control-plane evidence
for no more than 30 days unless a later decision explicitly extends them.

## Abuse, Privacy, and Safety Controls

- Apply AWS managed WAF rules, request-size limits, silent Challenge actions,
  per-session throttles, and a deliberately higher IP-based fallback threshold
  because a conference audience may share NAT addresses.
- Limit each session to three artifacts, two workflows, and one survey.
- Limit the full event to 1,000 artifacts and 500 workflows.
- Change to `READ_ONLY` automatically when limits, persistent errors, or unsafe
  queue conditions occur.
- Do not expose administrator, update, or delete operations.
- Never collect file bytes, original filenames, names, email addresses, or
  demographic information.
- HMAC-hash session identifiers in analytics data.
- Security logs may contain IP addresses only where operationally necessary and
  must expire after seven days.
- Escape, length-limit, and privately store the optional feedback comment. Do
  not write feedback to the ledger or display it publicly.
- Apply least privilege to IAM roles, Kubernetes service accounts, secrets,
  CI/CD credentials, and teardown automation. Do not place static AWS
  credentials in source, images, logs, browser code, or task prompts.

## Metrics and Survey

Collect server-side funnel and reliability evidence:

- anonymous browser sessions by selected organization;
- accepted and confirmed artifact submissions;
- confirmed workflow creations;
- provenance history views;
- p50 and p95 request and end-to-end confirmation times;
- failures, retries, queue depth, and queue age;
- pod readiness, ALB health, WAF actions, and recovery observations; and
- teardown completion and post-destroy resource inventory.

Use the term `anonymous browser sessions`, not `people`, `users`, or `unique
attendees`, unless a later measurement can support those claims.

Survey statements:

1. It was easy to submit an artifact or create a workflow.
2. Provenance information was easy to understand.
3. I can imagine this being useful in a research workflow.

Use a consistent small response scale and allow one optional private comment.
Report the survey as a self-selected convenience sample from a conference
demonstration. Do not describe it as community acceptance.

## TIME_BOUNDED Cost Control

Prior evidence observed about `$3.77` for a six-hour disposable run. A direct
72-hour extrapolation is `$45.24`; two additional RabbitMQ brokers add roughly
`$19.68`, giving a preliminary live-runtime estimate near `$65`. With edge,
telemetry, lifecycle jobs, data transfer, and one compressed rehearsal, use a
planning range of `$90-$120`.

`TIME_BOUNDED` is the only supported and default mode. The computed estimate,
including contingency, must be concrete and no greater than the USD 200
pre-deployment planning-estimate ceiling before any provisioning. USD 200 is
not a live-spend threshold and the estimate is never described as observed or
actual spend.

Runtime exposure is bounded by fixed capacity, small quotas, a persisted
`expiresAt`, a 72-hour maximum, an idempotent primary stop, an independently
scheduled backup stop, outside-VPC cleanup, an exact-tag sweeper, and zero
inventory verification in `us-west-2`, `us-east-1`, and run-scoped global
resources. The runtime and control plane do not create or query AWS Budgets and
do not call Cost Explorer, EstimatedCharges, billing-portal, or Billing APIs.
SNS reports start failure, primary stop failure, backup-stop activation, and an
incomplete sweep. Actual billed cost is a separate, optional human CloudBank or
account reconciliation after teardown.

## Git and Delivery Ownership

The task `OSC IS SR26 - Interactive Web Site` is the release owner. It must use
GitFlow in every repository it changes and must not write into another task's
dirty working copy.

After branch-governance work identifies the reviewed `develop` baseline, create
isolated worktrees and a `feature/usrse26-interactive-demo` branch in each
repository that needs changes, expected to include:

- `OSC-WebApp`
- `OSC-APIGateway`
- `OSC-Artifact-Submission`
- `OSC-IS-Infra`

Treat `OSC-Chaincode` as test-only unless a verified incompatibility requires a
minimal, reviewed change. Preserve unrelated work and do not force-push, bypass
branch protection, or publish an unreviewed merge.

The implementation task may reuse these existing tasks for bounded work:

- `OSC IS SR26 AWS/Infra Agent` for Terraform and lifecycle implementation;
- `OSC IS SR26 E2E` for an independent rehearsal and evidence package; and
- `OSC IS SR26 Review Agent` for one read-only security and release audit.

The release owner integrates their frozen outputs, records dispositions, and
performs one focused correction pass. Detailed status and evidence belong in
durable repository reports; chat handoffs should remain concise.

## Verification Gates

Complete tests in this order, expanding only after the cheaper gates pass:

1. Unit and contract tests for the guest role, organization binding, CSRF,
   expiry, quotas, lifecycle states, counters, events, and feedback.
2. Browser tests for QR/status, organization selection, artifact submission,
   confirmation/history, workflow creation, survey, and organization switching.
3. Negative tests for cross-organization writes and every forbidden capability.
4. CSP, dependency, secret, container, SBOM, and targeted dynamic security
   checks.
5. A complete local Kind deployment and E2E run before AWS.
6. An isolated AWS load rehearsal modeling 300 sessions, up to 100 concurrent
   sessions, 300 artifact submissions, and 120 workflow submissions.
7. Acceptance thresholds: less than 1% unexpected API failures, no duplicate
   ledger revisions, and every accepted operation reaching a terminal state
   within five minutes.
8. Controlled recovery of an API Gateway pod/node, worker, Ledger Gateway,
   RabbitMQ path, and Argo CD drift; verify `READ_ONLY` fail-safe behavior.
9. One compressed full lifecycle rehearsal: scheduled start, canary-open,
   interaction, drain, export, teardown, backup-stop, and empty tagged-resource
   inventory.
10. Real QR testing on a mobile device over both venue-style Wi-Fi and cellular
    connectivity.
11. Verification that the static status/fallback page remains useful before
    start, during a failed start, in read-only mode, and after teardown.

## Required Deliverables

- Implemented, tested feature branches and pull requests for every changed
  repository.
- Deployment and teardown runbooks.
- Exact configuration and lifecycle schedule with timezone documented.
- Threat model and least-privilege IAM/Kubernetes authorization review.
- Data dictionary, retention table, and privacy statement for all telemetry.
- Reproducible local and AWS test commands.
- Rehearsal report with exact revisions, timings, failures, fixes, planning
  estimate, bounded-exposure evidence, and actual billed cost marked
  `NOT_RECONCILED` unless supported by a later human billing record.
- Final event report with bounded claims, funnel metrics, survey caveats,
  planning estimate, bounded exposure, separately sourced actual billed cost,
  teardown evidence, and unresolved work.
- A concise release-owner handoff identifying commits, PRs, deployed revision,
  URLs, AWS run ID, evidence paths, blockers, and anything not tested.

## Stop Conditions

Do not declare the goal complete until the implementation, local verification,
AWS rehearsal, independent review, scheduled lifecycle validation, and evidence
handoff are complete, and no expensive demonstration runtime remains deployed.

Stop and request a user decision before:

- changing the event dates, public hostname, organizations, or USD 200
  planning-estimate ceiling;
- changing the agreed privacy boundary;
- weakening an authentication, authorization, WAF, network, or teardown control;
- deleting pre-existing or untagged AWS resources;
- merging to a protected long-lived branch when required approvals are absent;
  or
- making a public claim broader than the evidence in this plan supports.

## References

- [EventBridge Scheduler and Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/using-eventbridge-scheduler.html)
- [Step Functions and CodeBuild](https://docs.aws.amazon.com/step-functions/latest/dg/connect-codebuild.html)
- [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
- [EKS load balancing](https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html)
- [AWS WAF Challenge](https://docs.aws.amazon.com/waf/latest/developerguide/waf-captcha-and-challenge-actions.html)
- [Amazon EKS pricing](https://aws.amazon.com/eks/pricing/)
- [US-RSE'26 program](https://us-rse.org/usrse26/program/)
