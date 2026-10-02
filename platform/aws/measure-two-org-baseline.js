#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');

const [runId, reportPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !reportPath) {
  throw new Error('Usage: measure-two-org-baseline <run-id> <report-path>');
}

const expectedContext = `osc-usrse26-${runId}`;
const context = execFileSync('kubectl', ['config', 'current-context'], { encoding: 'utf8' }).trim();
if (context !== expectedContext) throw new Error(`Refusing Kubernetes context ${context}`);
const account = JSON.parse(execFileSync('aws', ['sts', 'get-caller-identity', '--output', 'json'], { encoding: 'utf8' })).Account;
if (account !== '269624229733') throw new Error(`Refusing AWS account ${account}`);

const secret = JSON.parse(execFileSync('kubectl', [
  '-n', 'osc-apps', 'get', 'secret', 'e2e-user-credentials', '-o', 'json',
], { encoding: 'utf8' }));
const password = Buffer.from(secret.data.password, 'base64').toString('utf8');
if (password.length < 20) throw new Error('Seeded test password is missing');

const baseUrl = 'http://127.0.0.1:18989/api/v1';
const startedAt = new Date().toISOString();
const report = {
  runId, account, region: 'us-west-2', context, startedAt,
  method: {
    sequentialArtifactsPerOrg: 8,
    pairedArtifactWaves: 4,
    workflowsPerOrg: 2,
    publicCatalogArtifactsPerOrg: 1,
    pollIntervalMs: 1000,
    timeoutMs: 120000,
    measurement: 'Client monotonic elapsed time from POST start to API acceptance, detail SUCCESS plus transaction ID, history item, or public catalog listing.',
    data: 'Synthetic metadata and deterministic SHA-256 fingerprints; no research file bytes were submitted.',
  },
  submissions: [], isolationChecks: [], credentialsRetained: false,
};

function save() {
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
}

async function request(method, route, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const started = performance.now();
  const response = await fetch(baseUrl + route, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  const elapsedMs = Math.round(performance.now() - started);
  const raw = await response.text();
  let data;
  try { data = raw ? JSON.parse(raw) : null; } catch { data = null; }
  return { status: response.status, elapsedMs, data };
}

function requireStatus(result, statuses, label) {
  if (!statuses.includes(result.status)) {
    throw new Error(`${label} returned HTTP ${result.status}`);
  }
  return result;
}

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const rounded = (start) => Math.round(performance.now() - start);
const slug = () => crypto.randomUUID().slice(0, 8);
const hash = label => crypto.createHash('sha256').update(label).digest('hex');

async function until(deadline, probe) {
  while (performance.now() < deadline) {
    const value = await probe();
    if (value) return value;
    await pause(1000);
  }
  return null;
}

async function submitArtifact(org, phase, visibility) {
  const label = `${runId}-${org.key}-${phase}-${slug()}`;
  const row = { type: 'artifact', organization: org.key, phase, visibility, label };
  report.submissions.push(row);
  const start = performance.now();
  const body = {
    title: `AWS evidence probe ${label}`,
    description: 'Synthetic private evidence probe used to measure submission and provenance timing on the two-organization AWS demonstration. No research file was uploaded.',
    visibility, keywords: ['aws-evidence-probe'], links: [], dois: [],
    fundingAgencies: [], acknowledgements: '', manifest: [],
    footprint: hash(label), submission_comment: 'Controlled timing probe for the US-RSE 2026 presentation.',
  };
  try {
    const created = requireStatus(await request('POST', '/artifacts', body, org.token), [200, 201], label);
    row.id = created.data?.id;
    row.acceptedMs = rounded(start);
    row.acceptedAt = new Date().toISOString();
    if (!row.id) throw new Error('POST did not return an artifact ID');
    const deadline = performance.now() + 120000;
    const detail = await until(deadline, async () => {
      const response = await request('GET', `/artifacts/${row.id}`, undefined, org.token);
      if (response.status !== 200) return null;
      if (response.data?.submissionState === 'FAILED') throw new Error('Artifact entered FAILED state');
      return response.data?.submissionState === 'SUCCESS' && response.data?.blockchainTxId ? response.data : null;
    });
    if (!detail) throw new Error('Artifact did not confirm within 120 seconds');
    row.confirmedMs = rounded(start);
    row.confirmedAt = new Date().toISOString();
    row.transactionId = detail.blockchainTxId;
    const history = await until(deadline, async () => {
      const response = await request('GET', `/artifacts/${row.id}/history?limit=1&includeValue=false`, undefined, org.token);
      return response.status === 200 && Number(response.data?.total) >= 1 ? response.data : null;
    });
    if (!history) throw new Error('Ledger history was not readable within 120 seconds');
    row.historyMs = rounded(start);
    row.historyAt = new Date().toISOString();
    row.historyTotal = history.total;
    if (visibility === 'public') {
      const catalog = await until(deadline, async () => {
        const response = await request('GET', '/artifacts');
        return response.status === 200 && Array.isArray(response.data) && response.data.some(item => item.id === row.id);
      });
      if (!catalog) throw new Error('Public catalog did not list artifact within 120 seconds');
      row.catalogMs = rounded(start);
      row.catalogAt = new Date().toISOString();
    }
    row.result = 'SUCCESS';
  } catch (error) {
    row.result = 'FAILED';
    row.error = error.message;
  }
  save();
  console.log(`${org.key} ${phase} artifact: ${row.result}, confirmed ${row.confirmedMs ?? 'n/a'} ms`);
  return row;
}

async function submitWorkflow(org, linkedArtifactId) {
  const label = `${runId}-${org.key}-workflow-${slug()}`;
  const row = { type: 'workflow', organization: org.key, phase: 'sequential', visibility: 'private', label };
  report.submissions.push(row);
  const start = performance.now();
  const body = {
    title: `AWS workflow evidence probe ${label}`,
    description: 'Synthetic workflow linking a confirmed artifact to measure application acceptance and Fabric confirmation in the two-organization AWS demonstration.',
    visibility: 'private', keywords: ['aws-evidence-probe'], githubRepositories: [],
    artifactIds: [linkedArtifactId],
    submission_comment: 'Controlled workflow timing probe for the US-RSE 2026 presentation.',
  };
  try {
    const created = requireStatus(await request('POST', '/workflows', body, org.token), [200, 201], label);
    row.id = created.data?.id;
    row.acceptedMs = rounded(start);
    row.acceptedAt = new Date().toISOString();
    if (!row.id) throw new Error('POST did not return a workflow ID');
    const deadline = performance.now() + 120000;
    const detail = await until(deadline, async () => {
      const response = await request('GET', `/workflows/${row.id}`, undefined, org.token);
      if (response.status !== 200) return null;
      if (response.data?.submissionState === 'FAILED') throw new Error('Workflow entered FAILED state');
      return response.data?.submissionState === 'SUCCESS' && response.data?.blockchainTxId ? response.data : null;
    });
    if (!detail) throw new Error('Workflow did not confirm within 120 seconds');
    row.confirmedMs = rounded(start);
    row.confirmedAt = new Date().toISOString();
    row.transactionId = detail.blockchainTxId;
    row.result = 'SUCCESS';
  } catch (error) {
    row.result = 'FAILED';
    row.error = error.message;
  }
  save();
  console.log(`${org.key} workflow: ${row.result}, confirmed ${row.confirmedMs ?? 'n/a'} ms`);
  return row;
}

async function check(label, method, route, body, token, expectedStatus) {
  const result = await request(method, route, body, token);
  const row = { label, method, expectedStatus, actualStatus: result.status, passed: result.status === expectedStatus };
  report.isolationChecks.push(row);
  save();
  if (!row.passed) throw new Error(`${label}: expected HTTP ${expectedStatus}, got ${result.status}`);
}

async function main() {
  const orgs = [
    { key: 'NSG', username: 'nsg-pi' },
    { key: 'Citizen Science', username: 'citizen-contributor' },
  ];
  for (const org of orgs) {
    const login = requireStatus(await request('POST', '/users/login', {
      username: org.username, password,
    }), [200, 201], `${org.key} login`);
    org.token = login.data?.token;
    if (!org.token) throw new Error(`${org.key} login had no token`);
  }

  for (let i = 0; i < 8; i++) {
    for (const org of orgs) await submitArtifact(org, 'sequential', 'private');
  }
  for (let wave = 1; wave <= 4; wave++) {
    await Promise.all(orgs.map(org => submitArtifact(org, `paired-${wave}`, 'private')));
  }
  for (const org of orgs) await submitArtifact(org, 'catalog', 'public');

  for (const org of orgs) {
    const linked = report.submissions.find(row => row.type === 'artifact' && row.organization === org.key && row.result === 'SUCCESS');
    if (!linked) throw new Error(`No confirmed ${org.key} artifact for workflow`);
    for (let i = 0; i < 2; i++) await submitWorkflow(org, linked.id);
  }

  const nsg = report.submissions.find(row => row.type === 'artifact' && row.organization === 'NSG' && row.visibility === 'private' && row.result === 'SUCCESS');
  const citizen = report.submissions.find(row => row.type === 'artifact' && row.organization === 'Citizen Science' && row.visibility === 'private' && row.result === 'SUCCESS');
  const nsgFlow = report.submissions.find(row => row.type === 'workflow' && row.organization === 'NSG' && row.result === 'SUCCESS');
  const citizenFlow = report.submissions.find(row => row.type === 'workflow' && row.organization === 'Citizen Science' && row.result === 'SUCCESS');
  if (!nsg || !citizen || !nsgFlow || !citizenFlow) throw new Error('Missing successful records for isolation checks');
  await check('NSG own private artifact read', 'GET', `/artifacts/${nsg.id}`, undefined, orgs[0].token, 200);
  await check('Citizen own private artifact read', 'GET', `/artifacts/${citizen.id}`, undefined, orgs[1].token, 200);
  await check('Citizen cannot read NSG private artifact', 'GET', `/artifacts/${nsg.id}`, undefined, orgs[1].token, 403);
  await check('NSG cannot read Citizen private artifact', 'GET', `/artifacts/${citizen.id}`, undefined, orgs[0].token, 403);
  await check('Citizen cannot update NSG private artifact', 'PUT', `/artifacts/${nsg.id}`, { submission_comment: 'This cross-organization change must be rejected.', keywords: [] }, orgs[1].token, 403);
  await check('Citizen cannot read NSG artifact history', 'GET', `/artifacts/${nsg.id}/history`, undefined, orgs[1].token, 403);
  await check('NSG own workflow read', 'GET', `/workflows/${nsgFlow.id}`, undefined, orgs[0].token, 200);
  await check('Citizen own workflow read', 'GET', `/workflows/${citizenFlow.id}`, undefined, orgs[1].token, 200);
  await check('Citizen cannot read NSG private workflow', 'GET', `/workflows/${nsgFlow.id}`, undefined, orgs[1].token, 403);
  await check('Citizen cannot update NSG private workflow', 'PUT', `/workflows/${nsgFlow.id}`, { submission_comment: 'This cross-organization change must be rejected.', keywords: [] }, orgs[1].token, 403);
}

main().catch(error => {
  report.fatalError = error.message;
  process.exitCode = 1;
}).finally(() => {
  report.finishedAt = new Date().toISOString();
  report.successfulSubmissions = report.submissions.filter(row => row.result === 'SUCCESS').length;
  report.failedSubmissions = report.submissions.filter(row => row.result === 'FAILED').length;
  report.passedIsolationChecks = report.isolationChecks.filter(row => row.passed).length;
  save();
  console.log(`Evidence run: ${report.successfulSubmissions} confirmed, ${report.failedSubmissions} failed, ${report.passedIsolationChecks} isolation checks passed`);
});
