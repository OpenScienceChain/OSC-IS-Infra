# US-RSE 2026 Platform Risk Register

Status values: open, mitigated, accepted, or blocked.

| ID | Risk | Likelihood | Impact | Planned control | Exit evidence | Status |
|---|---|---|---|---|---|---|
| R01 | Existing work is overwritten or based on stale history | Low | High | Isolated worktrees, branch audit, preserved hardening commits, no force push | revision manifest and clean base audit | Mitigated |
| R02 | Portal role or organization claims are forged | Medium | High | Resolve active membership server-side; ignore caller MSP and role fields | authorization tests | Open |
| R03 | One organization mutates another organization's private record | Medium | High | org-scoped repository queries plus chaincode MSP checks | negative NSG/Citizen Science tests | Open |
| R04 | Service identity makes individual attribution misleading | High | Medium | record trusted Gateway user metadata; state limitation explicitly | ADR, transaction and audit evidence | Accepted |
| R05 | Fabric private keys leak through images, logs, state, or evidence | Medium | Critical | Secrets Manager, workload identity, tmpfs/read-only mounts, sanitizer | image scan and evidence scan | Open |
| R06 | Bridge accepts insecure or unauthenticated traffic | High | High | mandatory TLS to Fabric; authenticated internal boundary; private NetworkPolicy | connection and denial tests | Open |
| R07 | Completion event is lost during transient API failure | Medium | High | publisher confirms, durable/quorum policy as applicable, bounded retry, DLQ, idempotent consumer | failure/recovery test | Open |
| R08 | Worker redelivery duplicates a ledger operation | Medium | High | deterministic idempotency key and committed-state reconciliation | restart/redelivery test | Open |
| R09 | A mutable dependency or lifecycle script compromises a build | Medium | Critical | preserve secure installers, locks, scanners, SHA/digest pins, SBOMs | supply-chain gates | Mitigated |
| R10 | Build code executes after AWS credentials are issued | Medium | Critical | separate build and deploy jobs; deploy only verified digests | workflow policy test | Open |
| R11 | Public network exposure reaches a data or admin plane | Medium | Critical | private subnets/services, restricted EKS API CIDR, no public MQ/Fabric/Postgres | Terraform and reachability checks | Open |
| R12 | Upstream Fabric sample drift breaks reproducibility | Medium | High | exact commit pin, checksum, deterministic overlay, copied run manifest | local rebuild from empty state | Open |
| R13 | Argo CD demonstrates sync but cannot reproduce rollback | Medium | Medium | immutable revisions and recorded known-good commit/digest | drift/rollout/rollback evidence | Open |
| R14 | EKS demonstration exceeds the authorized cost | Low | High | estimate before apply, $75/$125 notices, $150 read-only/stop, $200 no-provision ceiling, 72-hour deadline | estimate, monitor decisions, final cost | Open |
| R15 | Terraform destroy damages pre-existing resources | Low | Critical | dedicated state and VPC, baseline inventory, no imports, RunId tags | before/after inventory parity | Open |
| R16 | Billable resources survive the event window | Medium | Critical | scheduled stop, backup stop two hours later, expiry tags, all-tag sweeper, static fallback independent of runtime | empty tagged inventory and teardown proof | Open |
| R17 | In-cluster PostgreSQL is mistaken for a production design | Medium | Medium | label as disposable single-replica storage; document RDS alternative | ADR and claim matrix | Accepted |
| R18 | Three-broker Amazon MQ is overstated as product HA | Medium | Medium | use Multi-AZ broker for the demo but prohibit production-availability claims | topology evidence and claim matrix | Mitigated |
| R19 | EKS results are presented as production readiness or user adoption | Medium | High | claim/evidence matrix and talk wording guardrails | reviewed evidence package | Open |
| R20 | Scope expands beyond a ten-day evidence campaign | High | High | prioritize one reference scenario and required negative/recovery tests | acceptance matrix | Open |
| R21 | Public guest mode weakens the authenticated product path | Medium | Critical | additive DEMO_CONTRIBUTOR role, server-owned organization binding, 30-minute hard-close session, no update/delete/admin | product contract and negative tests | Open |
| R22 | Conference shared NAT causes false abuse blocks | Medium | Medium | per-session quotas first, high IP fallback threshold, silent WAF Challenge | load rehearsal and WAF samples | Open |
| R23 | Lifecycle runner image behaves outside the reviewed contract | Low | Critical | mandatory digest, no source/dependency install in CodeBuild, IAM permissions boundary, action contract | image scan, SBOM, rehearsal logs | Open |

