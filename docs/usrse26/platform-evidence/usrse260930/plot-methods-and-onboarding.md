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

Peer organization: **Magnetic Arch Plasma Showcase** (`MagneticArchMSP`). This is an OSC-curated demonstration identity, not an assertion that the source researchers operate a Fabric organization. Before this experiment it existed only in the database/application model. The experiment added its own CA and Fabric identity, peer, channel membership, chaincode approval/service, application routing, and confirmed transactions.

| Rank | Possible plot | Selected? | Measurement boundary |
| --- | --- | --- | --- |
| 1 | Milestone elapsed time from kickoff to CA/identity, channel update, peer ready, chaincode ready, app ready, first artifact, first workflow | Yes | UTC event stamps from controller and Fabric/API probes; no guessed duration. |
| 2 | Ready third-org Fabric/application pods over time, with Argo sync and health | Yes | 154 Kubernetes/Argo snapshots, roughly 10-14 seconds apart. |
| 3 | Third peer block-height catch-up relative to existing peers | No | Only join/readability and later block continuation were measured; no repeated height series. Do not plot an invented curve. |
| 4 | First third-org public artifact: API acceptance, Fabric confirmation, history, catalog; linked workflow | Yes | One client-timed synthetic probe and direct third-peer ledger history verification. |
| 5 | All-org post-addition confirmation and cross-org ownership checks | Yes | One artifact per org after the change, plus nine exact expected-status checks. No continuous sentinel was running throughout the addition. |
| 6 | Before/after Fabric/app/other ready pods and node count | Yes | Two read-only snapshots; 71/71 then 76/76 ready pods, three nodes both times. |
| 7 | Channel config sequence/block and endorsement membership | No | The config change is verified but is an audit fact, not a meaningful time series. |
| 8 | CA enrollment, secret rotation, and chaincode approval intervals | No | Included as operational steps/milestones, not separately plotted. |
| 9 | Third-org CPU/memory and billed cost delta | No | No matched quiet-window usage samples or billing readout; same nodes does not mean zero added cost. |
| 10 | Storage/PVC growth by organization | No | Requires a longer stabilization window than this demonstration. |

## Onboarding acceptance criteria

1. Baseline: AWS account/region/context and Argo `Synced/Healthy` verified; original two orgs can still submit and read history.
2. Security: private EKS/API/Argo access retained; no new public load balancer, unpinned image, downloaded executable, or copied secret in evidence.
3. Fabric: a channel config block explicitly contains `MagneticArchMSP`; new peer is joined and catches up; chaincode is installed/approved and its service is ready.
4. Application: its own ledger gateway and history route use its own Fabric identity and token; a new artifact and linked workflow confirm with readable history on the third peer.
5. Existing orgs: post-addition submissions and histories still work; unauthorized cross-org reads/updates remain rejected.
6. Evidence: record each actual milestone and failure, recheck Argo and Kubernetes after the experiment, and update plots from measured data only.

## Measured third-org results and five selected plots

Slides 20-24 of `OSC-IS-three-org-evidence-20260930.pptx` add **five** native editable charts to the 19-slide baseline. The 24-slide deck has 22 charts total. The chart-ready source is `third-org-onboarding-metrics-20260930.json`; raw snapshots, milestones, and E2E request-level details remain ignored under `platform/.generated/aws/usrse260930/evidence/metrics/`. `third-org-ledger-history-20260930.json` records the independent direct-ledger checks.

| Slide | Parameters and result | Why it matters; limits |
| --- | --- | --- |
| 20, operator-led milestones | First sampler snapshot 19:22:36 UTC; identity 19:27:18; channel config committed 19:32:20; peer joined/readable 19:34:00; chaincode ready 19:35:12; app ready first observed 19:48:09; first artifact 19:51:21; first workflow 19:51:24. Last milestone 28.8 minutes from kickoff. | Shows what "adding an organization" actually entails beyond a pod appearing. This includes operator verification, pauses, and a corrected peer-join command; **not** an automated provisioning benchmark. |
| 21, readiness/GitOps | 154 snapshots from 19:22:36 to about 19:52 UTC, roughly every 10-14 seconds. Third Fabric CA/peer/chaincode reached 3/3 ready; ledger gateway/history worker 2/2; Argo first observed `Synced/Healthy` on revision `88c34a5` at 19:48:19. | Makes the infrastructure/application sequence visible. First observed state can lag the actual transition by one sample; it does not certify a working write. |
| 22, first provenance path | One public synthetic Magnetic Arch artifact: API accepted 79 ms, confirmed with Fabric transaction ID 3,334 ms, history readable 3,689 ms, public catalog visible 3,740 ms. Linked private workflow accepted 64 ms and confirmed 2,253 ms. Direct gateway history found the API transaction ID for **both** records (2/2). | Demonstrates the application-to-ledger-to-history path, not just pod health. One probe with one-second polling is not a latency distribution. No research bytes were uploaded. |
| 23, continuity and isolation | One post-addition artifact per org: NSG 3,331 ms; Citizen Science 2,270 ms; Magnetic Arch 3,334 ms to first observed confirmation. All three histories had one item. Nine own-org/cross-org checks passed, including rejected reads and updates. | Shows the two original orgs still worked after onboarding and tenant boundaries held. Sequential, n=1 per org; no claim of uninterrupted availability *during* all 29 minutes or equal long-run performance. |
| 24, footprint | Before: 71/71 ready pods, 14 Fabric, 21 app, 36 other, three nodes. After: 76/76 ready pods, 17 Fabric, 23 app, 36 other, three nodes. | Shows the added deployment surface without a fourth worker. It is **not** a cost estimate: added Secrets Manager entries, a 1 GiB gp3 PVC, and resource consumption still cost money; colocating org3 with Citizen Science weakens node-failure isolation. |

The channel configuration advanced from sequence 0 to 1 and explicitly contains `MagneticArchMSP`; the third peer joined, saw the committed chaincode definition, and later committed blocks carrying the smoke transactions. The first join attempt used a config block and failed. Retrying with genesis block 0 succeeded. No block-height *time series* was collected, so none is plotted.

The new CA generated random enrollment secrets. Two registration secrets appeared in local tool output during the initial enrollment and were immediately rotated before the application was enabled; the CA root secret was not printed. New application credentials are held in AWS Secrets Manager and mounted via pod identity/CSI; no values are in the deck or sanitized JSON. The test user reuses the existing private E2E password hash for a bounded smoke test. Existing Fabric sample internal credentials and missing `osc-fabric` NetworkPolicy remain limitations. The application ALB is still internal, Fabric ingress is ClusterIP-only, and the EKS public control endpoint is restricted to the operator IP. Images are pinned to existing digests; the GitOps repository image uses the existing pinned BusyBox base.

The exact newly built GitOps image passed a pinned Trivy 0.74.0 High/Critical scan with zero findings and a fresh database (the mirror failed, then the primary database downloaded). A targeted ACL audit of 29 third-org credential paths found no unexpected principals. The broader ACL helper refused to traverse an existing generated Node junction, so do not claim that helper re-audited the entire runtime after this addition.

One pre-existing two-org fault-run API transaction pointer differed from its Fabric history transaction ID (89/90 matched). The new direct third-peer artifact/workflow checks were 2/2 matches; they do **not** erase that older discrepancy. AWS remains running at the operator's request; expiry tags are not teardown automation.
