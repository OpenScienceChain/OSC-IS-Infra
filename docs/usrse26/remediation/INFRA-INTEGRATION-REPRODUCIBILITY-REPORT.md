# Infrastructure Integration and Reproducibility Remediation

Date: 2026-09-02
Scope: OSC-Artifact-Submission integration and OSC-IS-Infra clean-checkout behavior
Disposition: locally implemented and verified; not pushed, deployed, or merged

## Executive result

The two reported blockers are remediated on dedicated local feature branches.

1. `OSC-Artifact-Submission` now has a GitFlow-compatible reconciliation commit
   whose first parent is the latest fetched `origin/develop` and whose second
   parent is the preserved US-RSE platform-evidence branch. The merge contains
   all three previously missing remote commits and retains the newer
   organization-bound Ledger Gateway behavior.
2. `OSC-IS-Infra` now enforces LF checkout for every Bash script and
   `platform/versions.env`, including on a Windows checkout with
   `core.autocrlf=true`. Its local bootstrap and seed paths own a transient
   runtime-secret directory, enforce restrictive permissions, tolerate safe
   reruns, purge stale files, and remove local secret material on success and
   error exits.
3. Both changes were verified again from detached, newly created worktrees.
   No AWS command was run. No remote branch, tag, pull request, merge, or other
   remote state was created.

## Scope and preserved state

The following remotes were fetched and inspected before modification:

| Repository | Inspected local feature head | Result |
| --- | --- | --- |
| OSC-Artifact-Submission | `fcfdb3e6df9137509df84e012ac17de40bf2a706` | Preserved and reconciled on a new branch |
| OSC-IS-Infra | `d5975ce615104c85046af4a6d37999110e29f248` | Preserved; remediation added on a new branch |
| OSC-APIGateway | `b66cf12430fb086a83957950aeed5aa435fab42e` | Inspected only; untouched |
| OSC-Chaincode | `743df2d41a1ac845dc4600317aedf21cc0b0024e` | Inspected only; untouched |

The base `OSC-IS-Infra` checkout had unrelated untracked `docs/usrse26/`
content. It was not modified. All implementation work occurred in new worktrees
under `OSC-IS-worktrees/usrse26-remediation`.

The protected `OSC-API`, `OSC-Docker`, and `OSC-Network` repositories were
inspected for branch/worktree context only and were not modified. The canonical
claim-evidence matrix, accessibility work, WebApp, APIGateway, Chaincode, and
the historical AWS evidence files were not edited.

## Branches and commits

### OSC-Artifact-Submission

- Branch: `feature/usrse26-integration-remediation`
- Reconciliation commit:
  `9f167efdc95767f2fa16673923b28980a63adc43`
- First parent, latest fetched `origin/develop`:
  `87854edf950cec25da88d050a389f5b3d9231dbf`
- Second parent, preserved evidence work:
  `fcfdb3e6df9137509df84e012ac17de40bf2a706`
- Local safety tag:
  `backup/usrse26-platform-evidence-before-develop-reconcile-20260902`
- Safety tag target:
  `fcfdb3e6df9137509df84e012ac17de40bf2a706`
- Relationship to `origin/develop` after reconciliation: 55 ahead, 0 behind.

The branch was created directly from `origin/develop`, then merged with the
preserved evidence branch using a two-parent merge. This keeps the intended
feature-to-develop GitFlow relationship visible without rebasing or rewriting
either line of history.

### OSC-IS-Infra

- Branch: `feature/usrse26-clean-checkout-remediation`
- Implementation commit:
  `1231b9aa62f8b90b39e2a990b02bb245cf47c3fa`
- Policy-file follow-up:
  `c1f7da2b5c7936856ebb82c850e0d0501184e0bc`
- Windows ACL hardening:
  `2b094411ec55cc8104dd4e7ee24d4b96cefd3ba1`
- Starting evidence head:
  `d5975ce615104c85046af4a6d37999110e29f248`
- Relationship to `origin/develop` before this report commit: 18 ahead, 0 behind.

## Artifact Submission reconciliation

### Verified divergence

The merge base between the old evidence branch and `origin/develop` was
`5931d08949f97080ad56c386e35e613d41eb3229`. Before reconciliation, the
evidence branch was 54 commits ahead and three commits behind:

| Remote commit | Remote intent | Reconciliation decision |
| --- | --- | --- |
| `aeb952c9549fe3e73d3177d2fb7f210021013eea` | Introduce the original Fabric bridge, Get History Worker, and network-facing tests | Preserve the newer service set, contracts, locks, retries, and organization-bound Ledger Gateway that evolved from and superseded this implementation |
| `3e36f02a847768fcb99d39e02093af55f4a7f352` | Accept empty strings in optional artifact fields | Carry the compatibility behavior into the v3 organization-bound schema and add a focused regression test |
| `87854edf950cec25da88d050a389f5b3d9231dbf` | Add operation context and peer details to Fabric failures | Carry the intent into the newer Fabric client with a bounded `FabricOperationError` that preserves peer address, MSP, and message diagnostics without replacing the newer authorization mapping |

All three commits are ancestors of `9f167ef`. The raw ancestry and safety-tag
output is in
`docs/usrse26/remediation/evidence/artifact-git-reconciliation.txt`.

### Conflict decisions

The merge reported conflicts in the following groups. Each group was compared
against both branch tips before resolution.

| Paths | Decision and rationale |
| --- | --- |
| `.gitignore` | Keep the evidence branch exclusions for secure-install outputs, coverage, local wallets, and Python environments |
| `broker/definitions.json` | Keep the newer durable artifact and workflow queues, retry exchanges, and failure handling rather than the earlier artifact-only topology |
| `docker-compose.yml` | Keep the newer compatibility-adapter local topology; the initial remote bridge topology is represented by the dedicated Ledger Gateway deployment used by the platform manifests |
| `fabric-bridge/Dockerfile`, `package.json`, `package-lock.json`, `README.md` | Keep the reviewed lockfile, immutable base, secure lifecycle allowlist, non-root runtime, and current Ledger Gateway documentation |
| `fabric-bridge/src/server.ts`, `fabricClient.ts`, and tests | Keep v3 multi-organization envelopes, internal authentication, TLS-only real-mode configuration, artifact/workflow operations, and denial mapping; manually add remote optional-field and diagnostic behavior |
| `get_history_worker/*` conflicts | Keep the current implementation and hash-locked dependency set; retain its unit and 80% coverage gate in unified CI |
| `submission_listener/*` conflicts | Keep current v3 contracts, workflow completion handling, API authentication, and hash-locked runtime image |
| `submission_worker/*` conflicts | Keep current organization routing, bounded durable retries, workflow support, and Ledger Gateway client behavior |

The reconciliation also aligns `submission_listener/.python-version` and
`submission_worker/.python-version` with the Python 3.11 locks and CI runtime.
The lock policy now fails when a checked-in `.python-version` disagrees with the
Python major/minor version recorded by `pip-compile`.

### Legacy workflow coverage mapping

Two workflows introduced by `aeb952c` were removed only after comparing every
check with `.github/workflows/ci.yml`.

| Legacy check | Unified secure CI replacement | Coverage conclusion |
| --- | --- | --- |
| `actions/checkout@v4` | Checkout pinned to full SHA `d23441a...` | Same checkout purpose, immutable reference |
| `actions/setup-node@v4`, Node 20 | Setup Node pinned to full SHA `2499707...`, Node 20 | Same runtime, immutable reference |
| Broad npm cache keyed by lockfile | Package-manager cache disabled for the high-risk bridge job | Deliberate security improvement; avoids restoring unverified dependency trees |
| `npm ci || npm i` | Repository supply-chain scan, lifecycle-suppression test, then `secure-install.sh --ci` using `npm ci --ignore-scripts` | Stronger and fail-closed; no unlocked fallback |
| Fabric Bridge Jest tests with coverage | `npm test -- --coverage --runInBand` | Same tests plus the v3 organization, schema, authorization, and error suites |
| Claimed Fabric Bridge 80% threshold | Jest configuration enforces 80% statements/functions/lines and 70% branches | Preserved; clean result was 90.57% statements and 94.61% lines |
| Setup Python 3.11 | Setup Python pinned to full SHA, Python 3.11 | Same runtime, immutable reference |
| Pip cache keyed by `requirements.txt` | Pip cache keyed by `requirements.lock` | Same optimization with a reviewed transitive lock |
| `pip install -r requirements.txt` | `pip install --require-hashes --only-binary=:all: -r requirements.lock` | Stronger reproducibility and supply-chain control |
| Get History tests and XML coverage | Matrix job runs `pytest`, emits XML, and uploads a component-specific artifact | Preserved |
| `coverage report --fail-under=80` | Component-aware unified command enforces 80% for Get History Worker | Initially found at 70%; explicitly restored to 80% in this remediation |

Unique schema and error behavior is not lost: the current Fabric tests exercise
missing footprint rejection, empty optional values, malformed IDs, internal
authentication, organization mismatch, Fabric failures, and authorization
denials. The Get History Worker still executes its complete `test_main.py`
suite in the matrix job.

## Infrastructure clean-checkout remediation

### Reproduced failure

A newly created detached Windows worktree at pre-fix commit `d5975ce` used the
repository's normal `core.autocrlf=true` setting. `prepare-local.sh` contained
71 carriage-return bytes. WSL `bash -n` failed at the first function definition,
and sourcing `platform/versions.env` emitted carriage-return command errors.
The transcript is
`docs/usrse26/remediation/evidence/infra-pre-fix-reproduction.txt`.

### Line-ending contract

Root `.gitattributes` now enforces:

```gitattributes
/.gitattributes text eol=lf
*.sh text eol=lf
platform/versions.env text eol=lf
```

The regression harness checks the policy lines, scans every Bash file and the
version file for carriage-return bytes, runs `bash -n` on every Bash file, and
sources `versions.env` in an isolated shell.

### Transient runtime secrets

`platform/scripts/runtime-secrets.sh` is now the shared local secret lifecycle
helper used by `deploy-local-apps.sh` and `seed-local-data.sh`.

It implements these controls:

- Creates `platform/.generated/runtime-secrets` itself with `umask 077`.
- Rejects a symlink used as the secret directory and rejects unexpected
  symlink or directory entries inside it.
- Enforces directory mode `0700` and file mode `0600` on POSIX filesystems.
- On a Windows-mounted WSL checkout where POSIX modes are unavailable, removes
  inherited ACLs and grants access only to the current Windows identity.
- Purges stale regular files before a new bootstrap.
- Truncates and removes regular secret files, then removes the directory on
  normal and error exits.
- Never prints secret values.
- Leaves durable values only in namespace-scoped Kubernetes Secrets.
- Does not rotate existing application credential Secrets during an idempotent
  deployment rerun. Fabric identity Secrets are refreshed from the current
  generated network because those identities legitimately follow the network.
- Rotates the deterministic E2E user's test-only password when reseeding, while
  updating both the database hash and Kubernetes Secret in the same seed run.

The new `validate-clean-checkout.sh` verifies initial creation, restrictive
permissions, stale-file removal on a second initialization, normal cleanup,
and trap-driven cleanup after an intentional failure. Terraform CI now runs
this test before infrastructure validation.

## Verification results

All dependency installation used reviewed repository controls. No static
credential was introduced and no test held AWS credentials.

SHA-256 hashes for every raw transcript are recorded in
`docs/usrse26/remediation/evidence/checksums.sha256`.

| Check | Environment and result | Raw result |
| --- | --- | --- |
| npm pre/post install malware scans | Detached Artifact checkout; 462 locked packages checked against 443 blocked package names | `evidence/artifact-secure-install.txt` |
| npm registry signatures | 462 package signatures and 41 attestations verified | `evidence/artifact-secure-install.txt` |
| Reviewed lifecycle execution | Only `pkcs11js@2.1.7` and `protobufjs@7.6.5` rebuilt after scripts-disabled install | `evidence/artifact-secure-install.txt` |
| Ledger Gateway unit/API tests | 24 passed; 90.57% statements, 72.28% branches, 90.9% functions, 94.61% lines | `evidence/artifact-ledger-gateway-tests.txt` |
| TypeScript build | `tsc -p tsconfig.json` passed | `evidence/artifact-ledger-gateway-tests.txt` |
| Adapter tests | 76 passed; 89.81% total coverage | `evidence/artifact-python-tests.txt` |
| Submission Listener tests | 25 passed; 91.58% total coverage | `evidence/artifact-python-tests.txt` |
| Submission Worker tests | 28 passed; 89.11% total coverage | `evidence/artifact-python-tests.txt` |
| Get History Worker tests | 13 passed; 97.65% coverage, above restored 80% gate | `evidence/artifact-python-tests.txt` |
| Python lock-policy tests | 7 passed, including matching and mismatching interpreter selectors | Executed in the reconciliation worktree; policy is also exercised by unified CI |
| Clean Windows checkout | 22 policy/Linux inputs contained no carriage returns; Git attributes reported LF | `evidence/infra-clean-checkout-validation.txt` |
| WSL syntax and secret lifecycle | All Bash files parsed, versions loaded, restrictive permission model and cleanup tests passed | `evidence/infra-clean-checkout-validation.txt` |
| Terraform formatting | Root, `usrse26-eks`, and `fabric-test` passed | `evidence/terraform-validation.txt` |
| Terraform initialization/validation | Locked providers initialized locally; all three configurations validated | `evidence/terraform-validation.txt` |
| Ledger Gateway image build | Digest-pinned Node base, secure install, TypeScript build, production prune passed | `evidence/artifact-container-build.txt` |
| Hardened container smoke | Healthy in simulation mode as UID `10001:10001`, read-only root, all capabilities dropped, `no-new-privileges` | `evidence/artifact-container-smoke.txt` |

The four Python component suites total 142 passing tests. The Get History
Worker emitted one upstream Starlette pending-deprecation warning; it did not
affect behavior or coverage.

The production npm audit reports three moderate `qs`/Express-chain findings.
The configured critical-severity gate passes. Resolving the moderate findings
requires an Express 5 breaking upgrade and is intentionally deferred rather
than applying `npm audit fix --force` during integration remediation.

ShellCheck was not installed in the available WSL distribution, so the durable
regression uses Bash parsing and behavior tests rather than claiming a
ShellCheck result.

## Docker and cloud state

Docker Desktop's Linux engine was initially stopped. Following the manager's
one-attempt guardrail, Docker Desktop was started once and became ready within
the bounded wait. The image build and smoke test then passed.

The exact test container and image were removed after the smoke test:

- Container `osc-remediation-ledger-9f167ef`: absent.
- Image `osc-remediation-fabric-bridge:9f167ef`: absent.

No Kind cluster was created for this narrow remediation. No AWS CLI, Terraform
plan against AWS, apply, deployment, credential request, or AWS API call was
performed.

## Impact on existing AWS evidence

The historical run at
`docs/usrse26/platform-evidence/20260902a` remains valid as an immutable record
of what was tested on 2026-09-02. Its source manifest correctly records:

- OSC-IS-Infra validated source:
  `d82693ae962f089c0c1ede97312c1c81030a0e3a`
- OSC-Artifact-Submission validated source:
  `fcfdb3e6df9137509df84e012ac17de40bf2a706`
- Teardown verification source: `3425333`

This remediation does not rewrite those blobs or claim that the new commits
were part of that AWS run. The Infrastructure changes affect Windows/WSL local
checkout and transient local bootstrap behavior, not the recorded AWS
manifests or teardown proof. The Artifact reconciliation contains the exact
previously validated Artifact commit as its second parent, but its additional
compatibility changes require a new local E2E run before they can be added to
any canonical claim-evidence matrix.

Therefore:

- Previous AWS evidence is not invalidated.
- Previous AWS evidence must not be relabeled as evidence for `9f167ef` or the
  remediation branch.
- A later run should record new source revisions in a new evidence directory.

## Remaining risks and deferred verification

1. A full Kind deployment with real Fabric, PostgreSQL, RabbitMQ, both Ledger
   Gateways, workers, listener, and APIGateway was not repeated in this narrow
   remediation. Existing historical evidence covers the prior parent commits,
   not the reconciliation commit.
2. Real-mode Fabric peer diagnostics were covered by unit tests and error
   mapping tests, but the reconciled commit has not been exercised against a
   live peer.
3. The idempotent credential-preservation branch in `deploy-local-apps.sh`
   needs one full-stack rerun that compares Kubernetes Secret data before and
   after a second deployment.
4. GitHub Actions were reviewed and parsed locally but were not executed because
   no branch was pushed. The CI consolidation must receive normal pull-request
   review before remote use.
5. The three moderate npm advisories remain a documented dependency-upgrade
   item. Do not bypass them with an automatic forced major upgrade.
6. Windows ACL enforcement was exercised through WSL on this workstation. A
   second Windows host with a different WSL mount policy remains useful
   portability evidence.

## Handoff to the E2E agent

Use these exact local inputs:

- OSC-Artifact-Submission:
  `feature/usrse26-integration-remediation` at
  `9f167efdc95767f2fa16673923b28980a63adc43`
- OSC-IS-Infra:
  `feature/usrse26-clean-checkout-remediation` at this report's branch tip
- APIGateway: preserve `b66cf12430fb086a83957950aeed5aa435fab42e`
- Chaincode: preserve `743df2d41a1ac845dc4600317aedf21cc0b0024e`

Run the next gate in a new worktree, with no AWS access:

1. Run `bash platform/scripts/validate-clean-checkout.sh` before downloads or
   cluster creation.
2. Install Artifact bridge dependencies only through the secure installer and
   install Python dependencies only from the platform-specific hash locks.
3. Build all changed images by immutable source commit and record their local
   digests.
4. Bring up the isolated `osc-usrse26-infra` Kind cluster and run the existing
   Fabric, stack, recovery, and GitOps validations.
5. Run `deploy-local-apps.sh` twice. Hash the data of the seven application
   credential Secrets before and after the second run and prove that it is
   unchanged. Prove `platform/.generated/runtime-secrets` is absent after each
   successful run and after one controlled failing run.
6. Submit artifacts with empty optional strings and confirm the v3 Gateway
   accepts them without weakening required title, footprint, envelope,
   organization, or correlation validation.
7. Exercise a real NSG denial and a Citizen Science cross-organization denial;
   verify a non-retryable 403 classification and useful sanitized server-side
   diagnostics.
8. Repeat artifact/workflow creation, update, history, durable retry, worker
   restart, peer failure, GitOps rollout, rollback, and complete local teardown.
9. Store results in a new remediation-specific evidence directory. Do not edit
   the canonical claim-evidence matrix until this E2E gate passes.
10. Confirm no remediation container, image, cluster, registry, volume, or
    background port-forward remains.

## Reviewer handoff

Nothing has been pushed. A reviewer can inspect the exact local worktrees:

- `C:\Users\ofgar\Projects\GithubProjects\OSC-IS-worktrees\usrse26-remediation\OSC-Artifact-Submission`
- `C:\Users\ofgar\Projects\GithubProjects\OSC-IS-worktrees\usrse26-remediation\OSC-IS-Infra`

Review order:

1. Confirm the two parents of Artifact commit `9f167ef`.
2. Review the three-commit intent table and focused compatibility tests.
3. Review the old-to-unified workflow mapping before accepting workflow
   deletions.
4. Review the runtime secret helper, especially the Windows ACL fallback and
   existing-Kubernetes-Secret preservation behavior.
5. Re-run the clean-checkout harness from a new Windows/WSL checkout.
6. Require the local Kind E2E gate before considering either branch ready for a
   remote pull request.
