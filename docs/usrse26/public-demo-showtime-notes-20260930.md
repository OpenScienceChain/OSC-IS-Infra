# Public demo showtime notes (September 30, 2026)

This is the fast path for a future operator, not an instruction to redeploy tonight. The operator requested that AWS, Fabric, Argo CD, and the site remain running. Read [the cutover and rollback record](public-demo-cutover-20260930.md) before a change. Do not paste credentials, Terraform state, Fabric wallets, raw logs, or an unredacted Postman export into a public report.

## What is live

| Item | Exact identity | Important distinction |
| --- | --- | --- |
| Public site | `https://demo.osc-staging.org/` | Interactive Angular app; `osc-staging.org` is a different site. |
| CloudFront | `E26XTII1H57RTX`, WAF in `us-east-1` | Static S3 plus `/api/*` to a private VPC origin. |
| AWS account/runtime | `269624229733`, `us-west-2`, EKS run `usrse260930` | Three Fabric organizations; leave running until authorized shutdown. |
| Control state | `usrse26r1` in ignored `platform/.generated/control/usrse26r1/terraform.tfstate` | Different run ID from the EKS runtime. Only the `feature/usrse26-interactive-demo` Infra checkout owns this state. |
| Argo CD | `osc-is-aws`, GitOps revision `ecdd21dc838b3fe1bd7173967af688bbdf489fdc` | Argo manages application workloads; Fabric bootstrap is a separate step. |
| S3 site | Bucket `osc-usrse26-usrse26r1-edge-269624229733`; index version `uZ47vAujigzxltXTiNAP5a05p61S40wI` | The read-only fallback index is version `xy7pb.aweej8vRyRwgqW5VahGKuVeCha`. Keep both. |
| Runtime config | `assets/runtime-config.json` version `cQvwWL46CEPrYgOkysnrn4.t3UBHbnXK` | Git-ignored, `API_BASE_URL=/api/v1`, `MOCK_PREVIEW=false`, uploaded separately with `no-store`. |
| WebApp source | `feature/magnetic-arch-showcase` at `81c43c4` | Public catalog integration and the live E2E race fix are pushed. |
| Curator seed source | Infra `feature/magnetic-arch-showcase` at `28c80a6` | Loopback-only EKS seeding support; do not stage unrelated files in that checkout. |

The public viewer connection is HTTPS. CloudFront reaches the internal ALB over HTTP within the VPC; this is not end-to-end TLS. The ALB and Argo UI are not public. The EKS control endpoint has a restricted operator `/32`, which may need a deliberate update if the laptop's public IP changes. The public demo permits self-created 4-6 digit PIN accounts and self-declared organization selection; it is not a production identity system.

## Ten-minute preflight if everything is still running

Use the **owner** Infra checkout at `C:\Users\ofgar\Projects\GithubProjects\OSC-IS\.codex-interactive-demo-worktrees\OSC-IS-Infra`. Check identity before any AWS operation. The commands below are read-only:

```powershell
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
aws cloudfront get-distribution --id E26XTII1H57RTX --query 'Distribution.{Status:Status,Aliases:DistributionConfig.Aliases.Items,Origins:DistributionConfig.Origins.Items[].Id,Behaviors:DistributionConfig.CacheBehaviors.Items[].PathPattern}' --output json
kubectl --context osc-usrse26-usrse260930 -n argocd get application osc-is-aws -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}'
kubectl --context osc-usrse26-usrse260930 -n osc-apps get pods
Invoke-WebRequest https://demo.osc-staging.org/ -SkipHttpErrorCheck | Select-Object StatusCode
Invoke-WebRequest https://demo.osc-staging.org/api/v1/health -SkipHttpErrorCheck | Select-Object StatusCode
```

Expected: account `269624229733`; distribution `Deployed` with `static-edge`, `private-demo-api-usrse260930`, and `/api/*`; Argo `Synced Healthy`; site/API HTTP 200. Also open `/list-artifacts`, `/list-workflows`, and `/research-example` in a fresh browser session. Confirm real curated examples appear and that sign-in, own-record update, history, and sign-out work. Do not use real research bytes or personal information for the canary.

Argo is available only through a localhost port-forward. Start this in a separate terminal and leave that terminal open while exploring:

```powershell
kubectl --context osc-usrse26-usrse260930 -n argocd port-forward service/argocd-server 18980:443 --address 127.0.0.1
```

Open `https://127.0.0.1:18980/` and accept the local self-signed certificate. Administrator credentials are in the Kubernetes `argocd-initial-admin-secret`; retrieve them privately, never into this file, screenshots, or command-line arguments. Argo's node-grouped view showed three **worker nodes**, not one control-plane pod plus two organization pods. Use the application tree/pod names to show the third organization's CA, peer, gateway, and worker. The EKS control plane is AWS-managed and not one of those three node cards.

## Browser and API release gates

From `.codex-showcase-worktrees\OSC-WebApp` (the WebApp branch is `feature/magnetic-arch-showcase`), run against the public domain:

```powershell
$env:PLAYWRIGHT_BASE_URL = 'https://demo.osc-staging.org'
$env:PLAYWRIGHT_LIVE = '1'
$env:LIVE_SHOWCASE = '1'
$env:PLAYWRIGHT_AWS_PRIVATE = '1'
npx playwright test e2e/live-local.spec.ts --project=desktop --workers=1
npx playwright test e2e/showcase-live.spec.ts e2e/aws-private.spec.ts --workers=2
```

On September 30, the first command passed 2/2 (account ownership and revisions; 500-file/50-MiB manifest confirmed on Fabric). The second passed 20/20 across desktop, tablet, mobile, and small-mobile, with axe checks and research/catalog assertions. `aws-private.spec.ts` is an old filename; with `PLAYWRIGHT_BASE_URL` it tests the public domain. The WebApp unit suite passed 256 tests, and app/spec TypeScript checks passed. These tests create synthetic persistent demo records and accounts; use them sparingly on show day.

The file-size limit refers to **local browser hashing**: up to 500 files and 50 MiB of source bytes. The bytes and original paths are not uploaded. The 500-entry JSON manifest is roughly 57 KiB, which is why the original WAF policy blocked it. OSC records generated names, file hashes, sizes/types, metadata, and ledger provenance. Never claim that the 50 MiB is stored on-chain or transferred to the API.

The public WAF policy now has these tested boundaries:

- `POST /api/v1/demo/artifacts` and `PATCH /api/v1/demo/artifacts/{UUID}` with **exact** `Content-Type: application/json` may send up to 64 KiB of uncompressed request body. Other routes or MIME values remain capped at 8 KiB. All API requests with nonempty `Content-Encoding` are rejected with 415 before Nest; bodies over 64 KiB get 413.
- `AWSManagedRulesCommonRuleSet` still runs. Only its `SizeRestrictions_BODY` subrule is set to `Count`, not `Allow`; the explicit WAF size rules enforce our bounds. Other managed checks, rate limits, and private/legacy-route blocks remain active.
- Verified negatives: invalid large method/path/MIME and oversized body 413; gzip and duplicate `Content-Encoding` variants 415; legacy/internal/session/unlisted API paths 410; encoded/dot-segment paths 403; wrong Origin or missing CSRF 403; cross-account artifact/workflow revision 404. WAF logs identified the exact terminating rules.
- WAF rules propagate after apply. A 401 or 403 immediately after a rule change may reflect an old edge location; wait and repeat, then confirm CloudWatch WAF logs in `us-east-1`. Do not infer a decoded-body invariant from the 64-KiB WAF inspection ceiling.

## Lessons that saved time

1. **Use the owner worktree and state.** There is a similarly named `terraform/usrse26-control` in the showcase Infra checkout. It is not the control owner; applying it would be unsafe. The public edge is Terraform-owned in `feature/usrse26-interactive-demo`. Verify the AWS account and exact `E26XTII1H57RTX` before a plan.
2. **Treat saved Terraform plans as single-use.** The attach and WAF plans were reviewed and applied. WAF updates advanced Terraform state, so the earlier inverse detach binary is historical. For rollback, restore the read-only S3 index first; then regenerate a fresh distribution-only detach plan from current owner state with `external_demo_api_attached=false`, run `check_external_demo_edge_plan.py detach` on its JSON, and apply only the reviewed plan. Do not use `terraform apply` without an exact guarded plan.
3. **Keep the route boundary explicit.** The old status page and old portal catalogs used legacy `/api/v1/artifacts` and `/api/v1/workflows`; those public routes are blocked. The live site uses `/api/v1/demo` plus `/api/v1/showcase` for public catalogs and curated research. The current index and runtime config have separate S3 versions; upload assets/config before index, and publish index last. Do not overwrite the fallback index version or use a blind `s3 sync --delete`.
4. **Seed against the right API.** Existing seed scripts in `.codex-showcase-worktrees\OSC-IS-Infra\real-ledger-tests` default to local Fabric. For EKS they were pointed to the localhost-only `kubectl port-forward` of `service/api-gateway` in `osc-apps` (port `18989:3000`) with `OSC_SEED_API_BASE_URL=http://127.0.0.1:18989/api/v1`. The scripts also accept `OSC_SEED_ADMIN_USERNAME`, `OSC_SEED_ADMIN_PASSWORD`, `OSC_SEED_CURATOR_PASSWORD`, and `OSC_SEED_REPORT_NAME`; the URL is restricted to loopback and report output to the ignored `.generated` folder. Supply passwords privately from Kubernetes, not in a checked-in file or shell history. `osc-usrse26-curator-seed` is the curator Secret name, not a value to publish. Verify `/api/v1/showcase/examples` is ready before judging the research page. Do not invent ledger block numbers or upload source measurement files.
5. **Poll ledger history rather than read it once.** API acceptance, Fabric confirmation, indexed history, and public catalog visibility are separate milestones. A history read briefly returned revision 1 immediately after a successful revision-2 poll, then returned both revisions. The E2E test now retains the successful poll's transaction ID rather than racing a second read. HTTP 201 is not ledger confirmation.
6. **Security checks must use the deployed origin.** A private port-forward passing does not prove CloudFront/WAF behavior. We verified public account/CSRF/ownership, exact WAF rules, WAF logs, and the 500-file browser path. A failed browser page can be a missing seed or stale bundle, not a Fabric failure; distinguish UI, edge, API, and ledger layers.
7. **Dependency evidence is bounded.** The promoted gateway image was pinned by digest and had zero High/Critical findings in the recorded offline Trivy scan and zero production npm audit findings. That is a point-in-time scan, not a promise of zero future vulnerabilities. Do not run unreviewed installs or expose sample Fabric services to the internet. The public endpoint reaches only the API through CloudFront/WAF; the Fabric test-network's sample credentials and absent namespace NetworkPolicy remain internal-demo limitations.

## Evidence and presentation caveats

The sanitized AWS evidence handoff, metrics, plots, and decks are in `.codex-showcase-worktrees\OSC-IS-Infra\docs\usrse26\platform-evidence\usrse260930\README.md` and sibling files. The third organization was genuinely joined to Fabric; it added five ready pods but no fourth EKS worker node. Its 28.8-minute observation includes operator preparation and a corrected peer-join command, not automated onboarding time. The 30/s load stage measured short API acceptance, not sustained confirmed throughput. One of 90 fault-run API transaction pointers differed from direct Fabric history; keep that caveat in the talk. Estimated cost is not reconciled billing. Argo drift and recovery numbers are small samples, not SLAs.

For the demo narrative, show a public research card, its source and hash, the OSC artifact and linked workflow, then history/transaction evidence. The Magnetic Arch configuration cards are curated external research records, not data authored by the named demo organizations. Argo shows desired-versus-live application state; it does not by itself prove a Fabric transaction or a fully operational new organization.

## When it is time to change or stop

Keep the infrastructure up until the operator explicitly authorizes shutdown. Resources accrue cost while running; `ExpiresAt` tags and prior run metadata are **not** teardown automation. Before any future deploy, recheck account, region, source branches, pinned digests, image scans, Argo revision, Terraform state owner, current S3 versions, and the public canary. Do not replay today's saved plans against a later state.

For a public incident, use the rollback order in [the cutover record](public-demo-cutover-20260930.md): read-only index first, then a newly planned and guarded API detach. This leaves EKS/Fabric up for investigation. For later infrastructure shutdown, consult the exact-name teardown notes in the sanitized `usrse260930` evidence README; first detach and remove the staged VPC origin so the destroy guard can proceed. Do not delete worktrees or ignored run-state directories before teardown and evidence preservation.
