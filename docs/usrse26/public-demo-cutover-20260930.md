# Public demo cutover and rollback

Run date: 2026-09-30. Account: `269624229733`; region: `us-west-2` (CloudFront WAF is in `us-east-1`). The user wants EKS and Fabric left running until a separately authorized shutdown.

## Live handoff (September 30, 20:10 PDT)

- `https://demo.osc-staging.org/` serves the interactive Angular site, not the old read-only status page. CloudFront distribution `E26XTII1H57RTX` has `static-edge` and `private-demo-api-usrse260930` origins, with `/api/*` routed to the internal ALB. The static index is S3 version `uZ47vAujigzxltXTiNAP5a05p61S40wI`; `assets/runtime-config.json` is version `cQvwWL46CEPrYgOkysnrn4.t3UBHbnXK` and sets `API_BASE_URL` to `/api/v1`, `MOCK_PREVIEW` to `false`. Both are `no-store`. The runtime config is intentionally Git-ignored; deployment must upload it separately.
- Argo CD application `osc-is-aws` is `Synced/Healthy` at `ecdd21dc838b3fe1bd7173967af688bbdf489fdc`. The three Fabric organizations and API remain running. Do not shut them down or detach the API merely because the web rollout is complete.
- `https://demo.osc-staging.org/api/v1/health` returns 200. The 500-file/50-MiB manifest, account ownership, artifact/workflow revisions, and history passed public-origin browser E2E. Research examples and public catalogs passed 20 Playwright/axe checks across desktop, tablet, mobile, and small-mobile. The WebApp unit suite passed 256 tests; app and spec TypeScript checks passed.
- The WAF permits an 8-64 KiB JSON body only for `POST /api/v1/demo/artifacts` and `PATCH /api/v1/demo/artifacts/{UUID}`. All other bodies above 8 KiB and all bodies above 64 KiB receive 413. Any nonempty `Content-Encoding` on `/api/*` receives 415. The managed Common rule's `SizeRestrictions_BODY` is overridden to **Count only**; its other protections and the other managed rule groups remain active. The WAF body limit is on inspected request bytes, not a general claim about decompressed JSON; blocking encoded API requests closes the tested gzip path. Duplicate `Content-Encoding` variants returned 415. WAF logs confirmed `RejectLargeNonManifestBody`, `RejectOversizeBody`, and `RejectEncodedApiBodies` as terminating rules.
- Negative checks: missing CSRF 403; cross-account revisions 404; wrong Origin 403; invalid large method/path/MIME 413; legacy/internal/session/unlisted routes 410; encoded and dot-segment paths 403. Valid uncompressed 500-file submissions still confirm on Fabric after the final WAF change.
- OSC-curated records of external research are seeded into the EKS ledger: Magnetic Arch Plasma (five configuration artifacts and one workflow), EEG (one artifact and one workflow), Serengeti (two artifacts and one workflow). They appear in the public catalogs and research-example pages. The curator account is backed by Kubernetes Secret `osc-usrse26-curator-seed` in `osc-apps`; never publish its value. The seed reports and source manifests remain in ignored local `.generated` files. These records are curated references, not claims that the organizations authored the external research.

The cutover gate below records how this state was reached; it is not a pending instruction to repeat the attachment or upload. The earlier inverse detach plan is now **historical** because the Terraform state changed during WAF hardening. Regenerate and guard a fresh detach plan against the current owner state before any rollback.

## Ownership

- `demo.osc-staging.org` is CloudFront distribution `E26XTII1H57RTX`, owned by Terraform state `platform/.generated/control/usrse26r1/terraform.tfstate` in the `feature/usrse26-interactive-demo` Infra checkout. Do not apply the similarly named, nonowner control configuration from `feature/magnetic-arch-showcase`.
- The API is run `usrse260930` behind an internal ALB. The staged CloudFront VPC origin is `vo_1dVcvRCbxX9E8K13wIJGhs`. Before cutover, the distribution has only `static-edge` and no `/api/*` behavior.
- Argo CD's `osc-is-aws` application is `Synced/Healthy` at Git revision `ecdd21dc838b3fe1bd7173967af688bbdf489fdc`. The packaged repository image is `sha256:2dcc6da5f30223747ce724a74f355592a5318cd2b6f6305300e6ad4ef4e2228b`. The previous private revision/image were `e7e5352967bc5759f5af0697b0aacdf08bf478e6` and `sha256:f67aaf768ded506e0e80f3dc497772aaad571271c511f7f6f680361fc0ad1ac8`.
- The read-only S3 `index.html` fallback is version `xy7pb.aweej8vRyRwgqW5VahGKuVeCha` in `osc-usrse26-usrse26r1-edge-269624229733`. Keep this version available.

## Verified before attachment

- CloudFront static hardening removed distribution-wide 403/404-to-200 rewrites. A viewer-request function rewrites only static SPA routes. WAF blocks internal, session, unlisted and malformed paths. Dot-segment requests return WAF-managed 403; other negatives return 410. WAF logs confirmed the terminating rule. Account entry blocks at 100/5 minutes per IP and 600/5 minutes globally; history blocks at 300/minute per IP.
- API tests: 19 suites, 273 tests; gateway tests: 27. The patched gateway image `sha256:273036257dac55b1a8c855adcc3a2fd11c2924dda351c41e75796b14c1c09dd1` runs in all three organizations. Its production npm audit has zero findings; offline Trivy reports zero High/Critical vulnerabilities in the runtime image. A private post-rollout canary confirmed an artifact and workflow on Fabric, with public API transaction IDs matching their history.
- Private account canary: register 201, secure cookie and CSRF token issued; missing CSRF 403, wrong PIN 401, untrusted Origin 403. Local browser E2E covered account ownership, artifact/workflow revisions and the 500-file/50-MiB boundary. The patched web bundle passed 96 browser checks over four viewport projects, including accessibility and hostile metadata rendering.

## Cutover gate

1. Confirm independent reviewer approval of the saved `api-attach-review.tfplan` and its `api-attach-review.plan.json`. Run `python platform/aws/check_external_demo_edge_plan.py attach ...plan.json`; it must report one distribution update only. Confirm AWS account, live distribution ID, `Deployed` VPC origin and Argo `Synced/Healthy` at the exact revision above.
2. Apply **only** the reviewed saved plan using the owner state. Wait for CloudFront `Deployed`. The S3 status page must remain the public index. Confirm `/api/v1/health` reaches the private API, normal JSON error codes are not rewritten to HTML, and WAF negatives are still blocked.
3. Before uploading the Angular index, create and review the inverse Terraform plan with the same approved ALB ARN and `external_demo_api_attached=false`, targeted to `aws_cloudfront_distribution.edge`; run `check_external_demo_edge_plan.py detach` against its JSON. Keep the plan file and state backup in the ignored run directory. If it includes any other change, stop. The attachment flag defaults to `false`; every future owner-state plan must opt in explicitly to expose the API.
4. Run a public-origin synthetic account, artifact, workflow, ownership, history and CSRF canary. Only then upload the production `index.html` with `text/html` MIME and `no-store` cache policy, invalidate the CloudFront paths, and run desktop/mobile Playwright and axe checks against `https://demo.osc-staging.org/`.

## Rollback

First restore the read-only index, then detach the API. Use a narrowly scoped S3 version copy of `index.html` version `xy7pb.aweej8vRyRwgqW5VahGKuVeCha` to the same bucket/key and invalidate `/*`. Confirm the status page loads. **Regenerate** the inverse Terraform plan against the current owner state, run the `detach` guard, and apply only that newly checked plan. Wait for distribution `Deployed`, confirm the origin set is only `static-edge`, `/api/v1/health` is unavailable, and blocked API paths remain blocked. Keep EKS/Fabric running. Remove the staged VPC origin before a separately authorized EKS teardown; the current destroy guard refuses teardown while it exists.

From the owner Infra worktree root, after checking the AWS account is `269624229733`:

```powershell
$bucket = 'osc-usrse26-usrse26r1-edge-269624229733'
$source = "$bucket/index.html?versionId=xy7pb.aweej8vRyRwgqW5VahGKuVeCha"
aws s3api copy-object --bucket $bucket --key index.html --copy-source $source --metadata-directive COPY --region us-west-2
aws cloudfront create-invalidation --distribution-id E26XTII1H57RTX --paths '/*'
```

Generate and inspect the inverse plan after attachment; do not apply it if the guard fails. The staged VPC origin remains in Terraform state so rollback changes only the distribution:

```powershell
Push-Location terraform/usrse26-control
$run = '../../platform/.generated/control/usrse26r1'
$apiArn = 'arn:aws:elasticloadbalancing:us-west-2:269624229733:loadbalancer/app/k8s-oscapps-oscdemoa-5938afeb16/f59ddecd5a4a24ef'
terraform plan -input=false -refresh=false "-state=$run/terraform.tfstate" "-var-file=$run/control.tfvars" "-var=external_demo_api_alb_arn=$apiArn" '-var=external_demo_api_attached=false' '-target=aws_cloudfront_distribution.edge' "-out=$run/api-detach.tfplan"
terraform show -json "$run/api-detach.tfplan" | Set-Content -LiteralPath "$run/api-detach.plan.json" -Encoding utf8
Pop-Location
python platform/aws/check_external_demo_edge_plan.py detach platform/.generated/control/usrse26r1/api-detach.plan.json
```

## Residual risk and scope

- The CloudFront viewer connection is HTTPS, but the CloudFront VPC-origin to internal ALB hop is HTTP within the private VPC. This is accepted only for a time-bounded synthetic-data demonstration; it is not end-to-end TLS.
- Accounts use user-selected 4-6-digit PINs, per-account lockout and edge rate limits. Organization choice is self-declared. These are demo accounts, not verified researcher identities. Do not invite real confidential data or describe this as a production identity system.
- OSC stores metadata and file fingerprints, not uploaded research file bytes. Public submissions are bounded by per-account and event quotas, but abuse can still consume demo capacity. AWS resources continue to accrue cost while left running.
- The WAF 64-KiB limit is a request-inspection boundary, not an application-decoded-body invariant. The demo now rejects nonempty `Content-Encoding` headers on API paths, but do not present this as a universal guarantee about every possible upstream transfer encoding. Large JSON with `application/json; charset=utf-8` is deliberately rejected by the narrow WAF exception; the browser sends exact `application/json`.
- The research-example data is synthetic ledger metadata tied to independently sourced public research; no source measurement bytes were uploaded. Do not enter sensitive data or real personal information into the public demo. Test-created accounts and synthetic records will persist until the separately authorized cleanup.
