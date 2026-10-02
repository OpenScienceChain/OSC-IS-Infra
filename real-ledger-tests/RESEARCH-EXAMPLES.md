# Curated research examples (local Fabric)

The research page presents three external sources. The Magnetic Arch Plasma
example is described in `MAGNETIC-ARCH-SHOWCASE.md`. Two additional examples
are curated under the existing Neuroscience Gateway and Citizen Science
organizations. They do not replace or modify member-submitted records. The
dedicated curator accounts register cited source metadata, file names,
SHA-256 hashes, manifest footprints, and a provenance-grouping workflow.
OSC does not retain the downloaded research bytes.

| Organization | Published source | Registered files |
| --- | --- | --- |
| Neuroscience Gateway | [EEG Eye State, UCI](https://archive.ics.uci.edu/dataset/264/eeg+eye+state), DOI `10.24432/C57G7J` | Original `EEG Eye State.arff` |
| Citizen Science | [Thel et al., Snapshot Serengeti reproduction study, Zenodo](https://zenodo.org/records/4639695), DOI `10.5281/zenodo.4639695` | Classification CSV and README |

The Citizen Science example uses the open Zenodo deposit because the original
Dryad Snapshot Serengeti file API currently requires authentication. Do not
claim that the Zenodo files are the original full Snapshot Serengeti release.
The workflows group registered source records; they do not represent analysis
executed by OSC or the organizations. Source creators and license details are
shown on the research page.

## Reproduce locally

Use the existing three-organization local stack described in
`MAGNETIC-ARCH-SHOWCASE.md`; do not provision any cloud resources. Once the
Gateway and Fabric workers are healthy and both base organizations exist:

1. Run `node Prepare-ResearchExamples.mjs` from this directory. It streams
   the three published files, verifies pinned sizes and SHA-256 values (and
   Zenodo MD5 metadata/license), and writes only a hash manifest to ignored
   `.generated/research-examples-manifest.json`. It fails if source checksums
   change or the output already exists; inspect the source before updating
   pinned values.
2. Run `node Seed-ResearchExamples.mjs`. It uses the local bootstrap admin to
   create curator accounts if needed, then submits one EEG artifact, two
   Serengeti artifacts, and one linking workflow per example through the
   normal Gateway/outbox/Fabric path. It reuses exact matching existing
   records and rejects mismatches. Success requires each transaction ID to
   appear in live Fabric history. A hash-only report is written to ignored
   `.generated/research-examples-seed-report.json`.
3. Verify `GET /api/v1/showcase/examples` returns `ready: true` for all three
   examples, with artifact counts 5, 1, and 2. Verify artifact and workflow
   histories through the example-scoped routes. Run the WebApp's
   `e2e/showcase-live.spec.ts` with `LIVE_SHOWCASE=1` and
   `PLAYWRIGHT_BASE_URL=http://localhost:18088` for desktop/mobile and Axe.

Keep `.generated/local.env` and reports local. Never commit credentials,
downloaded source bytes, or generated manifests. The published source is the
authority for reuse terms and scientific interpretation.
