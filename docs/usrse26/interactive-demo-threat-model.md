# Interactive Demo Threat Model

Status: implemented controls require independent review and an AWS rehearsal.

## Protected assets

- AWS account `269624229733`, Terraform state, IAM roles, and teardown path.
- Fabric service identities, API secrets, guest session signing material, and
  private survey comments.
- Provenance integrity, organization binding, public counters, and retained
  evidence.
- The stable `demo.osc-staging.org` hostname and its fallback page.

## Trust boundaries and controls

| Boundary | Primary threats | Implemented infrastructure controls | Required product evidence |
| --- | --- | --- | --- |
| Browser to edge | abuse, oversized input, injection, shared-NAT false positives | CloudFront TLS, CLOUDFRONT-scope managed WAF rules, 11 MiB request ceiling, Challenge at a deliberately high IP rate, strict response headers | exact-origin CORS, CSRF header, controlled fields, per-session quotas |
| Edge to runtime | public access to data plane, dead origin during failure | private internal ALB, pod-IP targets, VPC origin attachment only after canary, static fallback | `/demo/status` and read-only behavior |
| API to data/services | lateral movement, secret exposure | default-deny NetworkPolicy, explicit ports, Secrets Store identities, non-root/read-only containers | server-authoritative role and organization checks |
| Worker to Fabric | forged organization, duplicate writes | organization-scoped Ledger Gateways and Fabric identities, TLS, separate MSPs | idempotency keys and negative cross-organization tests |
| Lifecycle automation | wrong account, excessive exposure, partial start, unsafe destroy | STS guard in state machines and CodeBuild, fixed region, run lock, max two start retries, canary-open gate, concrete estimate no greater than the USD 200 planning ceiling, 72-hour deadline, fixed capacity, independent backup stop, all-tag sweeper | reviewed runner image and rehearsal logs |
| Evidence retention | personal-data leakage, indefinite retention | separate prefixes, seven-day security logs, 30-day sanitized evidence expiry, cookie/authorization redaction | sanitizer and data-dictionary tests |

## Residual risks

- The lifecycle role necessarily creates and removes a wide set of ephemeral
  services. Its permissions must be constrained by an account-owned boundary
  and reviewed after a Terraform plan is available.
- The in-cluster PostgreSQL database is single-AZ and is not a production or
  disaster-recovery design.
- Three workers and three RabbitMQ brokers improve the demonstration failure
  surface, but no production-availability claim is permitted.
- Conference attendees may share an egress IP. IP rate limits are a fallback;
  product-owned session quotas remain the primary abuse control.
- No AWS behavior is proven by local static validation. AWS evidence begins
  only after the authorized rehearsal.
