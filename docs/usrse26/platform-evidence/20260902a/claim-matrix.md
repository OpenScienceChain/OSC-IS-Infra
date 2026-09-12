# Claim-to-Evidence Matrix

| Claim | Level | Evidence and limitation |
|---|---|---|
| Portal IAM is separated from ledger invariants | AWS demonstrated | API membership/RBAC denials and Fabric organization denial passed; Fabric uses organization service identities, so individual attribution depends on the trusted Gateway audit trail. |
| NSG and Citizen Science are isolated across API and ledger boundaries | AWS demonstrated | Active-organization claims, caller-tenancy rejection, cross-org read/write denial, and direct Fabric denial passed. |
| Artifact and workflow provenance is deterministic and traceable | AWS demonstrated | Create, update, read, and history passed before and after rollback with transaction IDs and expected revision counts. |
| Accepted work survives temporary dependency failures | AWS demonstrated | Gateway, RabbitMQ, worker restart, and peer scenarios recovered with one ledger revision and no observed duplicate write. |
| GitOps detects drift and supports controlled rollback | AWS demonstrated | Argo self-heal, rollout, and rollback passed using immutable repository and application image revisions. |
| The deployment is reproducible from reviewed source and immutable artifacts | AWS demonstrated | Six non-root images were built, SBOMed, scanned, pushed, and deployed by digest; the authorization defect was rebuilt and redeployed through a new immutable GitOps baseline. |
| The AWS experiment is cost-conscious and disposable | AWS demonstrated | The reviewed eight-hour ceiling was USD 5.03; actual run duration and exact inventory parity are in the teardown proof. Provider billing data was not yet available in real time. |
| OSC-IS is production-ready | Not tested | Prohibited claim; HA, load, SLO, operations, and disaster recovery remain incomplete. |
| Researchers have adopted OSC-IS or experienced measured improvement | Not tested | Prohibited claim; no researcher deployment or usage study has occurred. |
