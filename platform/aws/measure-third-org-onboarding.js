#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');

const [runId, reportPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !reportPath) {
  throw new Error('Usage: measure-third-org-onboarding <run-id> <report-path>');
}
const context = execFileSync('kubectl', ['config', 'current-context'], { encoding: 'utf8' }).trim();
if (context !== `osc-usrse26-${runId}`) throw new Error(`Refusing context ${context}`);
const account = JSON.parse(execFileSync('aws', ['sts', 'get-caller-identity', '--output', 'json'], { encoding: 'utf8' })).Account;
if (account !== '269624229733') throw new Error(`Refusing account ${account}`);
const secret = JSON.parse(execFileSync('kubectl', ['-n', 'osc-apps', 'get', 'secret', 'e2e-user-credentials', '-o', 'json'], { encoding: 'utf8' }));
const password = Buffer.from(secret.data.password, 'base64').toString('utf8');
if (password.length < 20) throw new Error('Test password unavailable');

const baseUrl = 'http://127.0.0.1:18989/api/v1';
const report = {
  runId, account, context, startedAt: new Date().toISOString(),
  method: 'Single synthetic hash-only artifact per org, one linked third-org workflow; 1-second polls for state/history; localhost EKS port-forward.',
  submissions: [], checks: [], credentialsRetained: false,
};
function save() {
  fs.mkdirSync(require('node:path').dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
}
async function request(method, route, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const start = performance.now();
  const response = await fetch(baseUrl + route, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }
  return { status: response.status, ms: Math.round(performance.now() - start), data };
}
function expect(response, statuses, label) {
  if (!statuses.includes(response.status)) throw new Error(`${label}: HTTP ${response.status}`);
  return response;
}
async function until(probe) {
  const deadline = performance.now() + 120000;
  while (performance.now() < deadline) {
    const value = await probe();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error('Timed out after 120 seconds');
}
async function artifact(org) {
  const label = `${runId}-${org.key}-${crypto.randomUUID().slice(0, 8)}`;
  const start = performance.now();
  const row = { type: 'artifact', organization: org.key, label, visibility: org.key === 'Magnetic Arch' ? 'public' : 'private' };
  report.submissions.push(row);
  try {
    const body = {
      title: `Three-organization evidence probe ${label}`,
      description: 'Synthetic provenance timing probe. No research files were uploaded.',
      visibility: row.visibility, keywords: ['aws-evidence-probe'], links: [], dois: [], fundingAgencies: [],
      acknowledgements: '', manifest: [], footprint: crypto.createHash('sha256').update(label).digest('hex'),
      submission_comment: 'Controlled third-organization onboarding probe.',
    };
    const created = expect(await request('POST', '/artifacts', body, org.token), [200, 201], `${label} POST`);
    row.id = created.data?.id;
    row.acceptedMs = Math.round(performance.now() - start);
    row.acceptedAt = new Date().toISOString();
    if (!row.id) throw new Error('No artifact ID returned');
    const detail = await until(async () => {
      const r = await request('GET', `/artifacts/${row.id}`, undefined, org.token);
      if (r.data?.submissionState === 'FAILED') throw new Error('Artifact entered FAILED state');
      return r.status === 200 && r.data?.submissionState === 'SUCCESS' && r.data?.blockchainTxId ? r.data : null;
    });
    row.confirmedMs = Math.round(performance.now() - start);
    row.confirmedAt = new Date().toISOString();
    row.transactionId = detail.blockchainTxId;
    const history = await until(async () => {
      const r = await request('GET', `/artifacts/${row.id}/history?limit=1&includeValue=false`, undefined, org.token);
      return r.status === 200 && Number(r.data?.total) >= 1 ? r.data : null;
    });
    row.historyMs = Math.round(performance.now() - start);
    row.historyTotal = history.total;
    if (row.visibility === 'public') {
      await until(async () => {
        const r = await request('GET', '/artifacts');
        return r.status === 200 && Array.isArray(r.data) && r.data.some(item => item.id === row.id);
      });
      row.catalogMs = Math.round(performance.now() - start);
    }
    row.result = 'SUCCESS';
  } catch (error) { row.result = 'FAILED'; row.error = error.message; }
  save();
  console.log(`${org.key} artifact: ${row.result}, confirmed ${row.confirmedMs ?? 'n/a'} ms`);
  return row;
}
async function workflow(org, linkedId) {
  const label = `${runId}-magnetic-workflow-${crypto.randomUUID().slice(0, 8)}`;
  const start = performance.now();
  const row = { type: 'workflow', organization: org.key, label, visibility: 'private' };
  report.submissions.push(row);
  try {
    const body = {
      title: `Three-organization workflow probe ${label}`,
      description: 'Synthetic workflow linking a confirmed Magnetic Arch artifact. No research files were uploaded.',
      visibility: 'private', keywords: ['aws-evidence-probe'], githubRepositories: [], artifactIds: [linkedId],
      submission_comment: 'Controlled third-organization onboarding probe.',
    };
    const created = expect(await request('POST', '/workflows', body, org.token), [200, 201], 'workflow POST');
    row.id = created.data?.id;
    row.acceptedMs = Math.round(performance.now() - start);
    row.acceptedAt = new Date().toISOString();
    if (!row.id) throw new Error('No workflow ID returned');
    const detail = await until(async () => {
      const r = await request('GET', `/workflows/${row.id}`, undefined, org.token);
      if (r.data?.submissionState === 'FAILED') throw new Error('Workflow entered FAILED state');
      return r.status === 200 && r.data?.submissionState === 'SUCCESS' && r.data?.blockchainTxId ? r.data : null;
    });
    row.confirmedMs = Math.round(performance.now() - start);
    row.confirmedAt = new Date().toISOString();
    row.transactionId = detail.blockchainTxId;
    row.result = 'SUCCESS';
  } catch (error) { row.result = 'FAILED'; row.error = error.message; }
  save();
  console.log(`${org.key} workflow: ${row.result}, confirmed ${row.confirmedMs ?? 'n/a'} ms`);
  return row;
}
async function check(label, method, route, body, token, expectedStatus) {
  const r = await request(method, route, body, token);
  const row = { label, expectedStatus, actualStatus: r.status, passed: r.status === expectedStatus };
  report.checks.push(row);
  save();
  if (!row.passed) throw new Error(`${label}: expected ${expectedStatus}, got ${r.status}`);
}
async function main() {
  const orgs = [
    { key: 'NSG', username: 'nsg-pi' },
    { key: 'Citizen Science', username: 'citizen-contributor' },
    { key: 'Magnetic Arch', username: 'magnetic-e2e' },
  ];
  for (const org of orgs) {
    const login = expect(await request('POST', '/users/login', { username: org.username, password }), [200, 201], `${org.key} login`);
    org.token = login.data?.token;
    if (!org.token) throw new Error(`${org.key} login did not return token`);
  }
  for (const org of orgs) await artifact(org);
  const magnetic = report.submissions.find(row => row.type === 'artifact' && row.organization === 'Magnetic Arch' && row.result === 'SUCCESS');
  const citizen = report.submissions.find(row => row.type === 'artifact' && row.organization === 'Citizen Science' && row.result === 'SUCCESS');
  const nsg = report.submissions.find(row => row.type === 'artifact' && row.organization === 'NSG' && row.result === 'SUCCESS');
  if (!magnetic || !citizen || !nsg) throw new Error('Missing confirmed artifact for continuity/isolation checks');
  const flow = await workflow(orgs[2], magnetic.id);
  if (flow.result !== 'SUCCESS') throw new Error('Third-org workflow did not confirm');
  await check('Magnetic own artifact read', 'GET', `/artifacts/${magnetic.id}`, undefined, orgs[2].token, 200);
  await check('NSG own artifact read', 'GET', `/artifacts/${nsg.id}`, undefined, orgs[0].token, 200);
  await check('Citizen own artifact read', 'GET', `/artifacts/${citizen.id}`, undefined, orgs[1].token, 200);
  await check('Magnetic cannot read NSG private artifact', 'GET', `/artifacts/${nsg.id}`, undefined, orgs[2].token, 403);
  await check('NSG cannot read Citizen private artifact', 'GET', `/artifacts/${citizen.id}`, undefined, orgs[0].token, 403);
  await check('Citizen cannot update Magnetic artifact', 'PUT', `/artifacts/${magnetic.id}`, { submission_comment: 'Reject cross-org revision', keywords: [] }, orgs[1].token, 403);
  await check('Magnetic cannot update NSG artifact', 'PUT', `/artifacts/${nsg.id}`, { submission_comment: 'Reject cross-org revision', keywords: [] }, orgs[2].token, 403);
  await check('NSG cannot read Magnetic workflow', 'GET', `/workflows/${flow.id}`, undefined, orgs[0].token, 403);
  await check('Citizen cannot update Magnetic workflow', 'PUT', `/workflows/${flow.id}`, { submission_comment: 'Reject cross-org revision', keywords: [] }, orgs[1].token, 403);
}
main().catch(error => { report.fatalError = error.message; process.exitCode = 1; }).finally(() => {
  report.finishedAt = new Date().toISOString();
  report.successfulSubmissions = report.submissions.filter(row => row.result === 'SUCCESS').length;
  report.failedSubmissions = report.submissions.filter(row => row.result === 'FAILED').length;
  report.passedChecks = report.checks.filter(row => row.passed).length;
  save();
  console.log(`Third-org probe: ${report.successfulSubmissions} confirmed, ${report.failedSubmissions} failed, ${report.passedChecks} checks passed`);
});
