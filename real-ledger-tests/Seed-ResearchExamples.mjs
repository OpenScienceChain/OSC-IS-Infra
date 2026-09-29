import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '.generated');
const envFile = resolve(root, 'local.env');
const manifestFile = resolve(root, 'research-examples-manifest.json');
const reportFile = resolve(root, 'research-examples-seed-report.json');
const baseUrl = 'http://127.0.0.1:13388/api/v1';
const definitions = {
  'eeg-eye-state': {
    organizationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    curator: 'research-curator-nsg',
    curatorName: 'OSC Research Curator - Neuroscience Gateway',
    marker: 'osc-curated-eeg-eye-state',
    workflowTitle: 'EEG Eye State source provenance collection',
    workflowDescription: 'A provenance grouping for the published EEG Eye State recording, its SHA-256 fingerprint, and the original UCI citation. It documents registration of a source file; it does not claim that OSC ran an EEG analysis.',
    artifactDescriptions: {
      'eeg-recording': 'The original EEG Eye State ARFF file from UCI contains 14 channel readings and eye-state labels. OSC records the file fingerprint and citation only; the original measurement bytes remain with the publisher.',
    },
    keywords: ['EEG', 'eye state', 'neuroscience'],
    acknowledgements: 'Original dataset by Oliver Roesler. See the UCI record for attribution and reuse terms.',
  },
  'serengeti-reproduction': {
    organizationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    curator: 'research-curator-cs',
    curatorName: 'OSC Research Curator - Citizen Science',
    marker: 'osc-curated-serengeti-reproduction',
    workflowTitle: 'Snapshot Serengeti classification source collection',
    workflowDescription: 'A provenance grouping for the published Snapshot Serengeti volunteer and trained-observer classification table and its README. OSC records their fingerprints and citation; it does not claim to have run the study analysis.',
    artifactDescriptions: {
      classifications: 'The published classification table compares volunteer and trained-observer annotations of Snapshot Serengeti camera-trap sequences for a reproduction study. OSC records its SHA-256 fingerprint, not the CSV bytes.',
      readme: 'The published README explains fields and context for the Snapshot Serengeti reproduction-study classification table. OSC records this source document by SHA-256 without storing its original bytes.',
    },
    keywords: ['citizen science', 'camera traps', 'Snapshot Serengeti'],
    acknowledgements: 'Source data by Lucie Thel and coauthors. See the Zenodo record for full attribution and reuse terms.',
  },
};

for (const path of [envFile, manifestFile, reportFile]) {
  if (!path.startsWith(root + sep)) throw new Error('Seed files must remain inside .generated');
}
const env = Object.fromEntries(readFileSync(envFile, 'utf8').split(/\r?\n/)
  .filter((line) => /^[A-Z_]+=/.test(line))
  .map((line) => {
    const index = line.indexOf('=');
    return [line.slice(0, index), line.slice(index + 1)];
  }));
if (!env.LOCAL_ADMIN_PASSWORD || !env.LOCAL_MAGNETIC_CURATOR_PASSWORD) {
  throw new Error('Local administrator and curator secrets are required');
}
const prepared = JSON.parse(readFileSync(manifestFile, 'utf8'));
if (!Array.isArray(prepared.examples) || prepared.examples.length !== 2 ||
    prepared.examples.some((example) => !definitions[example.key] ||
      example.organizationId !== definitions[example.key].organizationId ||
      example.artifacts.length !== (example.key === 'eeg-eye-state' ? 1 : 2))) {
  throw new Error('The prepared examples do not match the reviewed sources');
}

async function api(path, { method = 'GET', token, body } = {}) {
  const response = await fetch(baseUrl + path, {
    method,
    headers: {
      accept: 'application/json',
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(`${method} ${path} failed with HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

async function curatorToken(example, definition) {
  const password = createHash('sha256')
    .update(`${env.LOCAL_MAGNETIC_CURATOR_PASSWORD}:${example.organizationId}`)
    .digest('hex');
  const login = () => api('/users/login', {
    method: 'POST',
    body: { username: definition.curator, password, organizationId: example.organizationId },
  });
  try {
    return (await login()).token;
  } catch (error) {
    if (error.status !== 401 && error.status !== 404) throw error;
  }
  const admin = await api('/users/login', {
    method: 'POST',
    body: { username: 'localadmin', password: env.LOCAL_ADMIN_PASSWORD },
  });
  await api('/users/register', {
    method: 'POST',
    token: admin.token,
    body: {
      name: definition.curatorName,
      email: `${definition.curator}@example.test`,
      username: definition.curator,
      password,
      role: 'pi',
      organizationId: example.organizationId,
    },
  });
  return (await login()).token;
}

function matchesManifest(actual, expected) {
  if (!Array.isArray(actual) || actual.length !== expected.length) return false;
  const hashes = new Map(actual.map((item) => [item.filename, item.hash]));
  return hashes.size === expected.length &&
    expected.every((item) => hashes.get(item.filename) === item.hash);
}

async function waitForLedger(key, type, id) {
  const path = `/showcase/examples/${key}/${type === 'artifact' ? 'artifacts' : 'workflows'}/${id}`;
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const record = await api(path);
    if (record.submissionState === 'FAILED') {
      throw new Error(`${type} ${id} failed ledger submission; inspect worker logs`);
    }
    if (record.submissionState === 'SUCCESS' && record.blockchainTxId) {
      try {
        const history = await api(`${path}/history`);
        if (history.items?.some((item) => item.txId === record.blockchainTxId)) return record;
      } catch (error) {
        if (error.status !== 502 && error.status !== 503) throw error;
      }
    }
    await new Promise((done) => setTimeout(done, 2000));
  }
  throw new Error(`${type} ${id} has no matching Fabric history after 180 seconds`);
}

async function seedExample(example) {
  const definition = definitions[example.key];
  const token = await curatorToken(example, definition);
  const catalog = (await api('/showcase/examples')).examples.find((item) => item.key === example.key);
  if (!catalog) throw new Error(`No showcase catalog for ${example.key}`);
  const artifacts = [];
  for (const source of example.artifacts) {
    const existing = catalog.artifacts.find((item) => item.title === source.title);
    if (existing && (existing.footprint !== source.footprint ||
        !matchesManifest(existing.manifest, source.manifest))) {
      throw new Error(`Existing ${source.code} does not match the reviewed source`);
    }
    const created = existing || await api('/artifacts', {
      method: 'POST',
      token,
      body: {
        title: source.title,
        description: definition.artifactDescriptions[source.code],
        visibility: 'public',
        keywords: [definition.marker, ...definition.keywords],
        links: [example.sourceUrl],
        dois: [example.sourceDoi],
        fundingAgencies: [],
        acknowledgements: definition.acknowledgements,
        manifest: source.manifest.map(({ filename, hash, algorithm }) => ({ filename, hash, algorithm })),
        footprint: source.footprint,
        submission_comment: 'OSC-curated registration of a cited external research source; no original file bytes were uploaded.',
      },
    });
    if (!created.id) throw new Error(`${source.code} returned no artifact ID`);
    const confirmed = await waitForLedger(example.key, 'artifact', created.id);
    if (confirmed.footprint !== source.footprint || !matchesManifest(confirmed.manifest, source.manifest)) {
      throw new Error(`Confirmed ${source.code} differs from the reviewed source`);
    }
    artifacts.push({ code: source.code, id: created.id, txId: confirmed.blockchainTxId });
  }
  const refreshed = (await api('/showcase/examples')).examples.find((item) => item.key === example.key);
  const existingWorkflow = refreshed.workflows.find((item) => item.title === definition.workflowTitle);
  const artifactIds = artifacts.map((item) => item.id);
  if (existingWorkflow && JSON.stringify([...existingWorkflow.artifactIds].sort()) !== JSON.stringify([...artifactIds].sort())) {
    throw new Error(`Existing ${example.key} workflow links a different artifact set`);
  }
  const workflow = existingWorkflow || await api('/workflows', {
    method: 'POST',
    token,
    body: {
      title: definition.workflowTitle,
      description: definition.workflowDescription,
      visibility: 'public',
      keywords: [definition.marker, ...definition.keywords],
      githubRepositories: [],
      artifactIds,
      submission_comment: 'OSC-curated provenance grouping for the cited source files; no analysis execution is claimed.',
    },
  });
  if (!workflow.id) throw new Error(`${example.key} returned no workflow ID`);
  const confirmedWorkflow = await waitForLedger(example.key, 'workflow', workflow.id);
  const finalCatalog = (await api('/showcase/examples')).examples.find((item) => item.key === example.key);
  if (!finalCatalog.ready || finalCatalog.artifacts.length !== artifacts.length) {
    throw new Error(`${example.key} catalog is not ready after ledger confirmation`);
  }
  return {
    key: example.key,
    organizationId: example.organizationId,
    sourceDoi: example.sourceDoi,
    artifacts,
    workflow: { id: workflow.id, txId: confirmedWorkflow.blockchainTxId },
  };
}

const report = { seededAt: new Date().toISOString(), examples: [] };
for (const example of prepared.examples) {
  report.examples.push(await seedExample(example));
  console.log(`Confirmed ${example.key} on the local Fabric network`);
}
writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n');
console.log(`Hash-only report: ${reportFile}`);
