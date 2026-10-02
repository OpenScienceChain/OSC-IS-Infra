# US-RSE 2026 Interactive Demo Rehearsal

This directory contains sanitized engineering evidence from the disposable
OSC-IS interactive-demo rehearsal in AWS account `269624229733`, region
`us-west-2`, under run ID `usrse26r1`.

The successful rehearsal used the existing OSC-IS product components. It did
not create a replacement application. The public WebApp called the API Gateway,
which accepted asynchronous work through RabbitMQ and the submission workers;
the Ledger Gateway then submitted provenance operations to a two-organization
Hyperledger Fabric network. The environment ran on EKS 1.35 with three fixed
`m7i.large` nodes and a private, three-broker Amazon MQ deployment.

## What the rehearsal demonstrated

- A public browser could enter the bounded conference mode without an account,
  choose one of two organizations, submit an artifact, create a workflow, and
  inspect confirmed provenance.
- The public canary produced one confirmed artifact and one confirmed workflow,
  each with an exact Fabric transaction identifier and no duplicate ledger
  revision. A cross-organization read was denied.
- The broader API and Fabric scenario covered organization selection, rejected
  caller-supplied tenancy, cross-organization read and write denials, role
  denial, create/update/history, and direct Fabric organization isolation.
- Accepted work recovered after controlled Ledger Gateway, RabbitMQ plus worker,
  and peer interruptions. Each observed artifact had one ledger revision.
- Argo CD corrected deliberate drift, deployed a controlled revision, and
  restored the known-good immutable revision. The post-rollback product journey
  passed.
- The runtime was closed to writes, sanitized aggregate evidence was exported,
  and the disposable AWS resources were removed. The independent teardown
  inventory is retained under `aws/`.

## Measured observations

| Observation | Result |
|---|---:|
| Public artifact confirmation | 2,391 ms |
| Public workflow confirmation | 2,656 ms |
| Ledger Gateway interruption recovery | 71 seconds |
| RabbitMQ interruption plus worker restart recovery | 224 seconds |
| Peer interruption, alternate peer accepted work | 5 seconds |
| GitOps drift self-heal | 156 seconds |
| Controlled rollout | 21 seconds |
| Known-good rollback | 20 seconds |

The captured Kubernetes validation snapshot contained three Ready nodes and 71
Running pods across system, GitOps, application, and Fabric namespaces. This is
an observed rehearsal snapshot, not a capacity or scale result.

## Public interaction evidence

Before closure, the aggregate export recorded six anonymous browser sessions,
two accepted and confirmed artifacts, one accepted and confirmed workflow, and
three provenance-history views. The survey had no responses. These counters
include rehearsal activity and are a self-selected convenience sample; they do
not measure unique people, usability improvement, adoption, or community
acceptance.

The screenshots in `screenshots/` show the public conference-mode entry and
provenance overview. They contain only synthetic demonstration data.

## Cost boundary

The direct six-hour planning estimate was USD 5.66. The more conservative
planning figure, including a fixed rehearsal/control allowance and 25 percent
contingency, was USD 27.07. The approved 72-hour bounded-exposure estimate was
USD 104.83 under a USD 200 planning ceiling. These are planning estimates, not
reconciled provider billing.

## Boundaries

This is evidence from one controlled rehearsal. It does not establish
production readiness, high availability, disaster recovery, sustained load,
performance targets, researcher adoption, or measured research impact. The
private three-broker RabbitMQ topology and three EKS nodes should not be treated
as a production design or availability result.

The October conference schedules and persistent control plane remain present,
but the scheduled launch is intentionally gated on a near-event release refresh.
The rehearsal artifact manifest expires before the event, and disposable ECR
repositories are removed during teardown. Immutable application archives remain
available locally for a reviewed republish. No claim of unattended October
readiness is made by this package.

The retained files omit credentials, secret values, private keys, certificates,
Terraform state, raw IAM identity output, and private endpoint details.
