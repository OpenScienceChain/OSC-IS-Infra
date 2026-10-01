import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '.generated');
const envFile = resolve(root, 'local.env');
const manifestFile = resolve(root, 'magnetic-arch-manifest.json');
const reportFile = resolve(root, process.env.OSC_SEED_REPORT_NAME || 'magnetic-arch-seed-report.json');
const organizationId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const marker = 'magnetic-arch-plasma-example';
const sourceUrl = 'https://zenodo.org/records/13987138';
const sourceDoi = '10.5281/zenodo.13987138';
const workflowTitle = 'Magnetic arch plasma RPA and FC measurement workflow';
const baseUrl = process.env.OSC_SEED_API_BASE_URL || 'http://127.0.0.1:13388/api/v1';
if (!/^http:\/\/127\.0\.0\.1:\d+\/api\/v1$/.test(baseUrl)) {
  throw new Error('Curator seeding requires a loopback-only Gateway URL');
}

for (const path of [envFile, manifestFile, reportFile]) {
  if (!path.startsWith(root + sep)) throw new Error('Showcase files must remain inside .generated');
}

const env = Object.fromEntries(
  readFileSync(envFile, 'utf8').split(/\r?\n/)
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const index = line.indexOf('=');
      return [line.slice(0, index), line.slice(index + 1)];
    }),
);
const source = JSON.parse(readFileSync(manifestFile, 'utf8'));
if (source.sourceUrl !== sourceUrl || source.sourceDoi !== sourceDoi ||
    source.fileCount !== 80 || source.artifacts?.length !== 5) {
  throw new Error('The prepared source manifest is not the reviewed magnetic arch dataset');
}
const curatorPassword = process.env.OSC_SEED_CURATOR_PASSWORD || env.LOCAL_MAGNETIC_CURATOR_PASSWORD;
const adminPassword = process.env.OSC_SEED_ADMIN_PASSWORD || env.LOCAL_ADMIN_PASSWORD;
const adminUsername = process.env.OSC_SEED_ADMIN_USERNAME || 'localadmin';
if (!curatorPassword || !adminPassword) {
  throw new Error('Curator and administrator passwords are required');
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
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; }
  catch { data = { message: 'Invalid JSON response' }; }
  if (!response.ok) {
    const error = new Error(`${method} ${path} failed with HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

async function login(username, password) {
  const response = await api('/users/login', {
    method: 'POST',
    body: { username, password, organizationId },
  });
  if (typeof response.token !== 'string') throw new Error('Login returned no token');
  return response.token;
}

async function curatorToken() {
  try {
    return await login('magnetic-curator', curatorPassword);
  } catch (error) {
    if (error.status !== 401 && error.status !== 404) throw error;
  }
  const admin = await api('/users/login', {
    method: 'POST',
    body: { username: adminUsername, password: adminPassword },
  });
  await api('/users/register', {
    method: 'POST',
    token: admin.token,
    body: {
      name: 'Magnetic Arch Curator',
      email: 'magnetic-curator@example.test',
      username: 'magnetic-curator',
      password: curatorPassword,
      role: 'pi',
      organizationId,
    },
  });
  return login('magnetic-curator', curatorPassword);
}

async function waitForConfirmation(type, id) {
  const path = type === 'artifact' ? `/showcase/artifacts/${id}` : `/showcase/workflows/${id}`;
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const record = await api(path);
    if (record.submissionState === 'FAILED') {
      throw new Error(`${type} ${id} failed ledger submission; inspect worker logs before retrying`);
    }
    if (record.submissionState === 'SUCCESS' && record.blockchainTxId) {
      try {
        const history = await api(`${path}/history`);
        if (history.items?.some((item) => item.txId === record.blockchainTxId)) {
          return record;
        }
      } catch (error) {
        if (error.status !== 502 && error.status !== 503) throw error;
      }
    }
    await new Promise((done) => setTimeout(done, 2000));
  }
  throw new Error(`${type} ${id} did not receive matching Fabric history in 180 seconds`);
}

function assertManifestMatches(actual, expected, code) {
  if (!Array.isArray(actual) || actual.length !== expected.length) {
    throw new Error(`Confirmed ${code} manifest has the wrong file count`);
  }
  const hashes = new Map(actual.map((item) => [item.filename, item.hash]));
  if (hashes.size !== expected.length ||
      expected.some((item) => hashes.get(item.filename) !== item.hash)) {
    throw new Error(`Confirmed ${code} manifest differs from the reviewed source`);
  }
}

async function main() {
  const curator = await curatorToken();
  const existing = await api('/showcase');
  const artifacts = [];
  for (const item of source.artifacts) {
    const found = existing.artifacts.find((record) => record.title === item.title);
    let id;
    if (found) {
      if (found.footprint && found.footprint !== item.footprint) {
        throw new Error(`Existing ${item.code} footprint differs from the reviewed dataset`);
      }
      assertManifestMatches(found.manifest, item.measurements, item.code);
      id = found.id;
    } else {
      const created = await api('/artifacts', {
        method: 'POST',
        token: curator,
        body: {
          title: item.title,
          description: `Public ${item.code} configuration from the magnetic arch plasma ECR-source study. Each named RPA or FC measurement is represented by its SHA-256 hash; the source files remain at Zenodo. Experimental collection occurred in 2023, not at this registration time.`,
          visibility: 'public',
          keywords: [marker, 'plasma', 'ECR', item.code, 'RPA'],
          links: [sourceUrl],
          dois: [sourceDoi],
          fundingAgencies: ['European Research Council (ERC), ZARATHUSTRA grant 950466'],
          acknowledgements: 'Source data by Celian Boye, Mario Merino, and Jaume Navarro Cavalle, Universidad Carlos III de Madrid. See Zenodo for the authoritative attribution and reuse terms.',
          manifest: item.measurements.map(({ filename, hash, algorithm }) => ({ filename, hash, algorithm })),
          footprint: item.footprint,
          submission_comment: 'Curated public provenance registration of the cited Zenodo measurement files.',
        },
      });
      id = created.id;
      if (!id) throw new Error(`Artifact ${item.code} returned no ID`);
    }
    const confirmed = await waitForConfirmation('artifact', id);
    if (confirmed.footprint !== item.footprint) throw new Error(`Confirmed ${item.code} footprint differs from the reviewed source`);
    assertManifestMatches(confirmed.manifest, item.measurements, item.code);
    artifacts.push({ code: item.code, id, txId: confirmed.blockchainTxId, footprint: item.footprint });
  }

  const current = await api('/showcase');
  const existingWorkflow = current.workflows.find((record) => record.title === workflowTitle);
  const artifactIds = artifacts.map((item) => item.id);
  let workflowId;
  if (existingWorkflow) {
    if (JSON.stringify([...existingWorkflow.artifactIds].sort()) !== JSON.stringify([...artifactIds].sort())) {
      throw new Error('Existing showcase workflow links a different artifact set');
    }
    workflowId = existingWorkflow.id;
  } else {
    const created = await api('/workflows', {
      method: 'POST',
      token: curator,
      body: {
        title: workflowTitle,
        description: 'A public provenance trail for the S0, S1, D0, DA, and DB plasma-source configurations. It links the SHA-256 manifests of all RPA measurements and the DA Faraday Cup data without transferring the underlying research files to OSC.',
        visibility: 'public',
        keywords: [marker, 'plasma', 'ECR', 'RPA', 'FC'],
        githubRepositories: [],
        artifactIds,
        submission_comment: 'Curated workflow connecting all five configurations from the cited Zenodo dataset.',
      },
    });
    workflowId = created.id;
    if (!workflowId) throw new Error('Workflow returned no ID');
  }
  const workflow = await waitForConfirmation('workflow', workflowId);
  const complete = await api('/showcase');
  if (!complete.ready || workflow.artifactIds.length !== 5) {
    throw new Error('The public showcase is not complete after ledger confirmation');
  }
  const report = {
    sourceDoi,
    organizationId,
    seededAt: new Date().toISOString(),
    artifacts,
    workflow: { id: workflowId, txId: workflow.blockchainTxId },
  };
  writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n');
  console.log(`Confirmed ${artifacts.length} artifacts and one workflow on Fabric.`);
  console.log(`Hash-only report: ${reportFile}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
