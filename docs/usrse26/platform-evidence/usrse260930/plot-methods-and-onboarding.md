# Plot methods and third-organization onboarding ledger

Internal working notes for the US-RSE 2026 evidence deck. A chart is evidence only when its inputs, clock, sample size, and limitations are recorded here. Do not substitute a database-only organization for a Fabric peer organization.

## Existing two-organization plots

The 13-slide deck `OSC-IS-two-org-load-evidence-20260930.pptx` has 11 editable plots. The requested numbered plot ideas map as follows:

| Idea | Metric and current evidence | Why it matters |
| --- | --- | --- |
| 1 | Offered, API-accepted, and Fabric record-transaction-timestamp rates, five 5-second stages (slide 8). The last is **not** live commit throughput. | Separates fast intake from ledger work. |
| 3 | First observed API `SUCCESS` with transaction ID after POST, 45 sampled writes, 1-second polling (slide 9). | Shows when provenance becomes observable to users. |
| 4 | Pending API-state samples from 45 live-polled timing-run writes (slide 14). Peak 30/45 at 18 seconds, all later observed `SUCCESS`. Two-second grid and one-second polls. | Shows whether fast acceptance hides queued work. |
| 5 | Accepted-minus-Fabric-record-timestamp proxy and 158.6-second observed drain after the last normal-run POST (slide 10). | Shows whether the burst is eventually cleared. |
| 9 | NSG versus Citizen Science median latency by offered rate (slide 15), two to five samples per org per stage. At 30/s the medians were 43.400 and 43.413 seconds. Exploratory only. | Checks for an obvious organization-level imbalance. |
| 10 | Cross-org private-record HTTP 403 checks, 71/71 across normal/timing/fault runs (slide 11). | Shows the tenant boundary under stress. |
| 11 | Synthetic footprint versus API and Fabric history SHA-256, 575/575 matches (slide 12). | Supports hash-preserving provenance. |
| 12 | Fabric history revisions per write (slide 16): 575/575 had exactly one; zero duplicate histories in normal, fault, and timing runs. | Exposes duplicate ledger writes from retries. |
| 18 | Browser-selected synthetic files of 1 KiB, 1 MiB, 10 MiB, and 40 MiB produced intercepted JSON POSTs of 450, 453, 454, and 454 bytes (slide 17). API was mocked; no file contents or original filenames in requests. | Tests the local browser privacy boundary without conflating it with AWS hash-only probes. |
| 23 | Twelve kubelet `stats/summary` snapshots, 19:13:48-19:14:47 UTC, inside a separate 330-write run (slides 18-19). Per sample, sum pod use by service, then average. Fabric peers: 166.9 millicores/572.3 MiB; API: 235.2 millicores/205.2 MiB; PostgreSQL: 159.0 millicores/73.2 MiB. | Shows which services used resources during the burst without adding an agent or Metrics Server. |
| 27 | Cumulative accepted writes and later-verified Fabric record timestamps during an NSG gateway scale-down/up (slide 13). One API transaction pointer disagreed with Fabric history. | Shows recovery and reveals a correctness exception. |

The first 575 writes were short synthetic tests, not a sustained-capacity benchmark or SLA. The resource capture required an **additional** 330-write normal run from 19:13:45 to 19:16:49 UTC; it completed 330/330 confirmed and hash-matched, with 25/25 cross-org denials and no duplicate history. These extra writes are not folded into the original 575-write charts. Fabric transaction timestamps are proposal-time metadata, not wall-clock finality. One original fault-run API `blockchainTxId` disagreed with its Fabric history transaction ID (89/90 matched). Do not conceal this exception.

Sources: `two-org-metrics-20260930.json`, `two-org-load-metrics-20260930.json`, `upload-privacy-metrics-20260930.json`, `service-resources-20260930.json`. The underlying load and resource raw files remain in ignored local `platform/.generated/aws/usrse260930/evidence/metrics/`. The browser test is `OSC-WebApp/e2e/upload-privacy-evidence.spec.ts` in the WebApp worktree. The expanded two-org deck has 19 slides and 17 editable charts. Charts 14-19 add the previously missing ideas; the original 13-slide deck remains unchanged.

## Third-organization candidate plots

Candidate peer organization: the existing **Magnetic Arch Plasma Showcase** (`MagneticArchMSP`). This is an OSC-curated demonstration identity, not an assertion that the source researchers operate a Fabric organization. It is currently present as a database/application model only; promotion to a third peer organization requires a real CA/service identity, channel configuration update, peer(s), chaincode installation and approval, application routing, and end-to-end confirmation.

| Rank | Possible plot | Selected? | Measurement boundary |
| --- | --- | --- | --- |
| 1 | Milestone elapsed time from kickoff to CA/identity, channel update, peer ready, chaincode ready, app ready, first artifact, first workflow | Yes | UTC event stamps from controller and Fabric/API probes; no guessed duration. |
| 2 | Desired versus ready third-org pods over time, with Argo sync and health transitions | Yes | Kubernetes/Argo snapshots every 5-10 seconds. |
| 3 | Third peer ledger block-height catch-up relative to the orderer and existing peers | Yes | Repeated peer channel-info queries; block heights only, not record counts. |
| 4 | Before/after ready pod count, requested CPU and memory, node count, and estimated run rate | Yes | Same Kubernetes and cost definitions on both sides. |
| 5 | Original-org availability/confirmation during the addition, then all-org ownership and cross-org isolation checks | Yes | Small continuous sentinel probes and explicit authorization matrix. |
| 6 | Channel config block version/sequence over time | No | Useful audit point but low explanatory value as a standalone plot. |
| 7 | CA enrollment and identity readiness latency | No | Fold into the milestone chart. |
| 8 | Chaincode install, approval, and first evaluation times | No | Fold into the milestone chart. |
| 9 | First artifact and workflow confirmation latency by org after onboarding | No | Capture as values in continuity/validation evidence. |
| 10 | Storage/PVC growth by organization | No | Requires a longer stabilization window than this demonstration. |

## Onboarding acceptance criteria

1. Baseline: AWS account/region/context and Argo `Synced/Healthy` verified; original two orgs can still submit and read history.
2. Security: private EKS/API/Argo access retained; no new public load balancer, unpinned image, downloaded executable, or copied secret in evidence.
3. Fabric: a channel config block explicitly contains `MagneticArchMSP`; new peer is joined and catches up; chaincode is installed/approved and its service is ready.
4. Application: its own ledger gateway and history route use its own Fabric identity and token; a new artifact and linked workflow confirm with readable history on the third peer.
5. Existing orgs: post-addition submissions and histories still work; unauthorized cross-org reads/updates remain rejected.
6. Evidence: record each actual milestone and failure, recheck Argo and Kubernetes after the experiment, and update plots from measured data only.

## Results

Third-org work pending. Do not claim third-organization onboarding time before criterion 4 is met. The two-org baseline and expanded deck are complete; no third-org milestones or plots should be fabricated from these sources.
