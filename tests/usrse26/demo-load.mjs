import { createHash, randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const API_BASE_URL = process.env.DEMO_API_BASE_URL || 'http://127.0.0.1:13000/api/v1';
const ORIGIN = process.env.DEMO_ORIGIN || 'https://demo.localho.st:18443';
const CONCURRENCY = 100;
const SESSION_COUNT = 300;
const ARTIFACT_COUNT = 300;
const WORKFLOW_COUNT = 120;
const TERMINAL_TIMEOUT_MS = 300_000;
const POLL_MS = 2_000;
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const EVIDENCE_PATH = process.env.DEMO_LOAD_EVIDENCE ||
  resolve(ROOT, 'platform', '.generated', 'evidence', 'demo-load', 'summary.json');

async function mapLimit(values, limit, operation) {
  const results = new Array(values.length);
  let next = 0;
  async function worker() {
    while (true) {
      const index = next++;
      if (index >= values.length) return;
      results[index] = await operation(values[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, values.length) }, worker));
  return results;
}

async function api(path, options = {}) {
  const response = await fetch(`${API_BASE_URL}${path}`, options);
  const text = await response.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!response.ok) {
    const error = new Error(`${options.method || 'GET'} ${path} returned ${response.status}`);
    error.status = response.status;
    error.body = body;
    throw error;
  }
  return { body, headers: response.headers, status: response.status };
}

function mutationHeaders(guest, requestId) {
  return {
    'Content-Type': 'application/json',
    Origin: ORIGIN,
    Cookie: guest.cookie,
    'X-Demo-CSRF': guest.csrfToken,
    'X-Correlation-Id': requestId,
  };
}

async function createSession(index) {
  const organization = index % 2 === 0 ? 'neuroscience-gateway' : 'citizen-science';
  const response = await api('/demo/session', {
    method: 'POST',
    headers: {'Content-Type': 'application/json', Origin: ORIGIN},
    body: JSON.stringify({ organization }),
  });
  const setCookie = response.headers.get('set-cookie');
  if (!setCookie?.startsWith('__Host-osc_demo=')) {
    throw new Error('Guest response did not contain the host-only demo cookie');
  }
  return {
    organization,
    cookie: setCookie.split(';', 1)[0],
    csrfToken: response.body.csrfToken,
    alias: response.body.contributorAlias,
    artifacts: [],
  };
}

function artifactRequest(sessionIndex, artifactIndex) {
  const requestId = randomUUID();
  return {
    requestId,
    fingerprint: createHash('sha256')
      .update(`usrse26:${sessionIndex}:${artifactIndex}`)
      .digest('hex'),
    sizeBytes: 128 + artifactIndex,
    extension: ['csv', 'json', 'txt'][artifactIndex % 3],
    researchContext: ['RESEARCH_DATASET', 'SOFTWARE_RELEASE', 'METHODS_NOTE'][artifactIndex % 3],
  };
}

async function createArtifact(guest, sessionIndex, artifactIndex) {
  const body = artifactRequest(sessionIndex, artifactIndex);
  const response = await api('/demo/artifacts', {
    method: 'POST',
    headers: mutationHeaders(guest, body.requestId),
    body: JSON.stringify(body),
  });
  if (JSON.stringify(response.body).includes('usrse26:')) {
    throw new Error('Artifact response exposed private hash input material');
  }
  return { id: response.body.id, body, acceptedAt: Date.now() };
}

async function waitForTerminal(guest, resource, record) {
  const started = record.acceptedAt;
  while (Date.now() - started < TERMINAL_TIMEOUT_MS) {
    const { body } = await api(`/demo/${resource}/${record.id}`, {
      headers: { Cookie: guest.cookie },
    });
    if (body.submissionState === 'SUCCESS') {
      if (!body.blockchainTxId) throw new Error(`${resource}/${record.id} has no transaction id`);
      return { ...body, confirmationMs: Date.now() - started };
    }
    if (body.submissionState === 'FAILED') {
      throw new Error(`${resource}/${record.id} reached FAILED: ${body.submissionError || 'unknown'}`);
    }
    await new Promise(resolveDelay => setTimeout(resolveDelay, POLL_MS));
  }
  throw new Error(`${resource}/${record.id} did not confirm within five minutes`);
}

function percentile(values, percentileValue) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * percentileValue))];
}

const startedAt = new Date();
const baselineCounters = (await api('/demo/counters')).body;
const sessions = await mapLimit(
  Array.from({ length: SESSION_COUNT }, (_, index) => index),
  CONCURRENCY,
  createSession,
);

const artifactJobs = [];
for (let sessionIndex = 0; sessionIndex < WORKFLOW_COUNT; sessionIndex += 1) {
  const perSession = sessionIndex < 60 ? 3 : 2;
  for (let artifactIndex = 0; artifactIndex < perSession; artifactIndex += 1) {
    artifactJobs.push({ sessionIndex, artifactIndex });
  }
}
if (artifactJobs.length !== ARTIFACT_COUNT) throw new Error('Artifact load shape is incorrect');

const artifacts = await mapLimit(artifactJobs, CONCURRENCY, async job => {
  const guest = sessions[job.sessionIndex];
  const artifact = await createArtifact(guest, job.sessionIndex, job.artifactIndex);
  guest.artifacts.push(artifact);
  return { guest, artifact };
});

for (const { guest, artifact } of artifacts.slice(0, 30)) {
  const retry = await api('/demo/artifacts', {
    method: 'POST',
    headers: mutationHeaders(guest, artifact.body.requestId),
    body: JSON.stringify(artifact.body),
  });
  if (retry.body.id !== artifact.id) throw new Error('Idempotent artifact retry changed the record id');
}

const confirmedArtifacts = await mapLimit(artifacts, CONCURRENCY, ({ guest, artifact }) =>
  waitForTerminal(guest, 'artifacts', artifact),
);

const workflows = await mapLimit(sessions.slice(0, WORKFLOW_COUNT), CONCURRENCY, async guest => {
  const requestId = randomUUID();
  const body = {
    requestId,
    artifactIds: guest.artifacts.map(artifact => artifact.id),
    researchContext: 'REPRODUCIBLE_ANALYSIS',
  };
  const response = await api('/demo/workflows', {
    method: 'POST',
    headers: mutationHeaders(guest, requestId),
    body: JSON.stringify(body),
  });
  return { guest, workflow: { id: response.body.id, body, acceptedAt: Date.now() } };
});

const confirmedWorkflows = await mapLimit(workflows, CONCURRENCY, ({ guest, workflow }) =>
  waitForTerminal(guest, 'workflows', workflow),
);

const artifactHistories = await mapLimit(artifacts, CONCURRENCY, async ({ guest, artifact }) => {
  const { body } = await api(`/demo/artifacts/${artifact.id}/history`, {
    headers: { Cookie: guest.cookie, 'X-Correlation-Id': randomUUID() },
  });
  if (body.total !== 1 || body.items?.length !== 1) {
    throw new Error(`Artifact ${artifact.id} has ${body.total} ledger revisions`);
  }
  return body;
});

const workflowHistories = await mapLimit(workflows, CONCURRENCY, async ({ guest, workflow }) => {
  const { body } = await api(`/demo/workflows/${workflow.id}/history`, {
    headers: { Cookie: guest.cookie, 'X-Correlation-Id': randomUUID() },
  });
  if (body.total !== 1 || body.items?.length !== 1) {
    throw new Error(`Workflow ${workflow.id} has ${body.total} ledger revisions`);
  }
  return body;
});

const crossOrganization = await fetch(
  `${API_BASE_URL}/demo/artifacts/${artifacts[0].artifact.id}`,
  { headers: { Cookie: sessions[1].cookie } },
);
if (crossOrganization.status !== 403) {
  throw new Error(`Cross-organization guest read returned ${crossOrganization.status}, expected 403`);
}

const finalCounters = (await api('/demo/counters')).body;
const counterDeltas = Object.fromEntries(
  Object.keys(finalCounters).map(key => [key, finalCounters[key] - (baselineCounters[key] || 0)]),
);
const expectedDeltas = {
  anonymousBrowserSessions: SESSION_COUNT,
  acceptedArtifacts: ARTIFACT_COUNT,
  confirmedArtifacts: ARTIFACT_COUNT,
  acceptedWorkflows: WORKFLOW_COUNT,
  confirmedWorkflows: WORKFLOW_COUNT,
  provenanceHistoryViews: ARTIFACT_COUNT + WORKFLOW_COUNT,
};
for (const [key, expected] of Object.entries(expectedDeltas)) {
  if (counterDeltas[key] !== expected) {
    throw new Error(`Counter ${key} changed by ${counterDeltas[key]}, expected ${expected}`);
  }
}

const artifactLatencies = confirmedArtifacts.map(item => item.confirmationMs);
const workflowLatencies = confirmedWorkflows.map(item => item.confirmationMs);
const summary = {
  schemaVersion: 1,
  startedAt: startedAt.toISOString(),
  completedAt: new Date().toISOString(),
  concurrency: CONCURRENCY,
  sessions: SESSION_COUNT,
  artifacts: ARTIFACT_COUNT,
  workflows: WORKFLOW_COUNT,
  unexpectedFailures: 0,
  unexpectedFailureRate: 0,
  duplicateLedgerRevisions: 0,
  terminalUnderFiveMinutes: true,
  crossOrganizationReadDenied: true,
  counters: { baseline: baselineCounters, final: finalCounters, deltas: counterDeltas },
  confirmationLatencyMs: {
    artifacts: { p50: percentile(artifactLatencies, 0.5), p95: percentile(artifactLatencies, 0.95), max: Math.max(...artifactLatencies) },
    workflows: { p50: percentile(workflowLatencies, 0.5), p95: percentile(workflowLatencies, 0.95), max: Math.max(...workflowLatencies) },
  },
  historiesChecked: artifactHistories.length + workflowHistories.length,
};
await mkdir(dirname(EVIDENCE_PATH), { recursive: true });
await writeFile(EVIDENCE_PATH, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
console.log(JSON.stringify(summary, null, 2));
