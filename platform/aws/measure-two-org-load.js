#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');

const mode = process.env.LOAD_MODE || 'normal';
const stages = mode === 'normal'
  ? [{ rate: 1, seconds: 5 }, { rate: 5, seconds: 5 }, { rate: 10, seconds: 5 }, { rate: 20, seconds: 5 }, { rate: 30, seconds: 5 }]
  : mode === 'fault' ? [{ rate: 3, seconds: 30 }]
    : mode === 'timing' ? [{ rate: 1, seconds: 5 }, { rate: 5, seconds: 4 }, { rate: 10, seconds: 3 }, { rate: 20, seconds: 2 }, { rate: 30, seconds: 2 }]
      : null;
if (!stages) throw new Error('LOAD_MODE must be normal, fault, or timing');
const expectedWrites = stages.reduce((sum, stage) => sum + stage.rate * stage.seconds, 0);
if (process.argv.includes('--self-test')) {
  console.log(JSON.stringify({ mode, stages, expectedWrites }));
  process.exit(0);
}

const runId = process.env.LOAD_RUN_ID || '';
const password = process.env.E2E_PASSWORD || '';
const baseUrl = process.env.LOAD_BASE_URL || '';
const maxWrites = Number(process.env.LOAD_MAX_WRITES || 0);
if (!/^[a-z0-9-]{12,64}$/.test(runId) || password.length < 20 ||
    baseUrl !== 'http://api-gateway.osc-apps.svc.cluster.local:3000/api/v1' ||
    expectedWrites + 2 > maxWrites || maxWrites > 332) {
  throw new Error('Load preflight failed: run ID, secret, private URL, or write cap');
}

const orgs = [
  { name: 'NSG', username: 'nsg-pi' },
  { name: 'Citizen Science', username: 'citizen-contributor' },
];
const report = {
  schemaVersion: 1, runId, mode, stages, expectedWrites,
  startedAt: new Date().toISOString(),
  method: 'In-cluster scheduled arrival rate; private synthetic hash-only artifacts; each confirmation verified against Fabric history after traffic stops.',
  submissions: [], crossOrgChecks: [], seeds: [], credentialsRetained: false,
};
const samplePolls = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = value => crypto.createHash('sha256').update(value).digest('hex');

async function request(method, route, body, token, timeoutMs = 20000) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(baseUrl + route, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* Status is retained. */ }
  return { status: response.status, data };
}

async function submit(org, stage, index) {
  const label = `${runId}-${stage}-${index}-${crypto.randomUUID().slice(0, 8)}`;
  const row = {
    organization: org.name, stage, label,
    offeredAt: new Date().toISOString(), expectedHash: hash(label),
  };
  report.submissions.push(row);
  const body = {
    title: `AWS load evidence ${label}`,
    description: 'Private synthetic hash-only load-test record. No research file bytes or original filenames were submitted.',
    visibility: 'private', keywords: ['aws-load-evidence'], links: [], dois: [],
    fundingAgencies: [], acknowledgements: '', manifest: [],
    footprint: row.expectedHash,
    submission_comment: 'Bounded two-organization AWS load measurement for US-RSE 2026.',
  };
  try {
    const result = await request('POST', '/artifacts', body, org.token);
    row.acceptedAt = new Date().toISOString();
    row.httpStatus = result.status;
    if (![200, 201].includes(result.status) || !result.data?.id) {
      row.error = `POST HTTP ${result.status}`;
    } else {
      row.id = result.data.id;
      if (mode === 'timing' && index < 10) {
        row.sampled = true;
        samplePolls.push(observeConfirmation(row, org.token));
      }
    }
  } catch (error) {
    row.acceptedAt = new Date().toISOString();
    row.error = error.name || 'request failure';
  }
  return row;
}

async function observeConfirmation(row, token) {
  const deadline = Date.now() + 600000;
  while (Date.now() < deadline) {
    try {
      const result = await request('GET', `/artifacts/${row.id}`, undefined, token, 10000);
      if (result.status === 200 && result.data?.submissionState === 'SUCCESS' && result.data?.blockchainTxId) {
        row.firstObservedSuccessAt = new Date().toISOString();
        return;
      }
      if (result.data?.submissionState === 'FAILED') return;
    } catch { /* A later observation may succeed. */ }
    await sleep(1000);
  }
}

async function waitSeed(row, token) {
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const result = await request('GET', `/artifacts/${row.id}`, undefined, token);
    if (result.status === 200 && result.data?.submissionState === 'SUCCESS' && result.data?.blockchainTxId) return;
    if (result.data?.submissionState === 'FAILED') throw new Error('Seed artifact failed');
    await sleep(1000);
  }
  throw new Error('Seed artifact did not confirm');
}

async function crossOrgProbe(second, seedIds) {
  const target = second % 2;
  const actor = 1 - target;
  const method = second % 4 < 2 ? 'GET' : 'PUT';
  const body = method === 'PUT'
    ? { submission_comment: 'Cross-organization test must be rejected.', keywords: [] }
    : undefined;
  const row = { at: new Date().toISOString(), second, actor: orgs[actor].name,
    target: orgs[target].name, method, expectedStatus: 403 };
  try {
    const result = await request(method, `/artifacts/${seedIds[target]}`, body, orgs[actor].token, 10000);
    row.actualStatus = result.status;
  } catch (error) {
    row.error = error.name || 'request failure';
  }
  report.crossOrgChecks.push(row);
}

async function readDetail(row, token) {
  try {
    const result = await request('GET', `/artifacts/${row.id}`, undefined, token, 10000);
    if (result.status !== 200) return;
    row.state = result.data?.submissionState;
    if (row.state === 'SUCCESS' && result.data?.blockchainTxId) {
      row.apiHashMatch = result.data.footprint === row.expectedHash;
      row.apiUpdatedAt = result.data.updatedAt;
      row.transactionId = result.data.blockchainTxId;
      row.transactionPresent = true;
    } else if (row.state === 'FAILED') {
      row.failure = 'Ledger submission failed';
    }
  } catch { /* A later pass may succeed. */ }
}

async function readHistory(row, token) {
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const result = await request('GET', `/artifacts/${row.id}/history?limit=2&includeValue=true`, undefined, token, 15000);
      const first = result.data?.items?.[0];
      if (result.status === 200 && first?.record?.payload) {
        row.ledgerCommittedAt = first.committedAt;
        row.ledgerHashMatch = first.record.payload.footprint === row.expectedHash;
        row.historyTotal = result.data.total;
        row.ledgerRevision = first.record.revision;
        row.ledgerTxMatch = first.transactionId === row.transactionId;
        return;
      }
    } catch { /* Retry boundedly. */ }
    await sleep(1000);
  }
  row.historyError = 'History was not readable';
}

async function inBatches(rows, size, fn) {
  for (let index = 0; index < rows.length; index += size) {
    await Promise.all(rows.slice(index, index + size).map(fn));
  }
}

async function main() {
  for (const org of orgs) {
    const login = await request('POST', '/users/login', { username: org.username, password });
    if (![200, 201].includes(login.status) || !login.data?.token) throw new Error(`Login failed for ${org.name}`);
    org.token = login.data.token;
  }
  const seedIds = [];
  for (let index = 0; index < orgs.length; index++) {
    const row = await submit(orgs[index], 'seed', index);
    if (!row.id) throw new Error('Seed POST failed');
    await waitSeed(row, orgs[index].token);
    seedIds.push(row.id);
    report.seeds.push(row.id);
  }
  report.submissions = [];
  report.loadStartedAt = new Date().toISOString();
  console.log(`RUN_START ${report.loadStartedAt} ${mode} ${expectedWrites}`);

  const launched = [];
  const checks = [];
  const start = performance.now();
  let offsetMs = 0;
  let sequence = 0;
  for (const stage of stages) {
    for (let index = 0; index < stage.rate * stage.seconds; index++) {
      const due = offsetMs + index * 1000 / stage.rate;
      const org = orgs[sequence++ % 2];
      launched.push(new Promise(resolve => setTimeout(() => {
        void submit(org, stage.rate, index).then(resolve);
      }, Math.max(0, start + due - performance.now()))));
    }
    offsetMs += stage.seconds * 1000;
  }
  for (let second = 0; second < offsetMs / 1000; second++) {
    checks.push(new Promise(resolve => setTimeout(() => {
      void crossOrgProbe(second, seedIds).then(resolve);
    }, Math.max(0, start + second * 1000 - performance.now()))));
  }
  await Promise.all([...launched, ...checks]);
  report.loadEndedAt = new Date().toISOString();
  console.log(`RUN_POSTS_DONE ${report.loadEndedAt} ${report.submissions.filter(row => row.id).length}`);
  await Promise.all(samplePolls);

  const deadline = Date.now() + 600000;
  let pending = report.submissions.filter(row => row.id);
  while (pending.length && Date.now() < deadline) {
    await inBatches(pending, 24, row => readDetail(row, orgs.find(org => org.name === row.organization).token));
    pending = pending.filter(row => row.state !== 'SUCCESS' && row.state !== 'FAILED');
    if (pending.length) await sleep(1000);
  }
  report.drainObservedAt = new Date().toISOString();
  report.pendingAtDeadline = pending.length;
  const successful = report.submissions.filter(row => row.state === 'SUCCESS');
  await inBatches(successful, 16, row => readHistory(row, orgs.find(org => org.name === row.organization).token));
  report.finishedAt = new Date().toISOString();
  report.summary = {
    offered: report.submissions.length,
    accepted: report.submissions.filter(row => row.id).length,
    confirmed: successful.length,
    failed: report.submissions.filter(row => row.state === 'FAILED').length,
    pending: pending.length,
    crossOrgDenied: report.crossOrgChecks.filter(row => row.actualStatus === 403).length,
    crossOrgChecks: report.crossOrgChecks.length,
    apiHashesMatched: successful.filter(row => row.apiHashMatch).length,
    ledgerHashesMatched: successful.filter(row => row.ledgerHashMatch).length,
    historyReadable: successful.filter(row => row.ledgerCommittedAt).length,
    duplicateHistories: successful.filter(row => row.historyTotal > 1).length,
    ledgerTransactionsMatched: successful.filter(row => row.ledgerTxMatch).length,
    sampledConfirmations: report.submissions.filter(row => row.firstObservedSuccessAt).length,
  };
  console.log(`RESULT_JSON ${JSON.stringify(report)}`);
  if (report.summary.confirmed !== expectedWrites || report.summary.crossOrgDenied !== report.summary.crossOrgChecks ||
      report.summary.apiHashesMatched !== expectedWrites || report.summary.ledgerHashesMatched !== expectedWrites ||
      report.summary.ledgerTransactionsMatched !== expectedWrites || report.summary.duplicateHistories !== 0 ||
      (mode === 'timing' && report.summary.sampledConfirmations !== report.submissions.filter(row => row.sampled).length)) {
    process.exitCode = 2;
  }
}

main().catch(error => {
  console.error(`RUN_ERROR ${error.message}`);
  process.exitCode = 1;
});
