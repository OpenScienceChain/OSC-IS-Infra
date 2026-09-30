#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const [normalPath, faultPath, timingPath, eventsPath, outputPath] = process.argv.slice(2);
if (![normalPath, faultPath, timingPath, eventsPath, outputPath].every(Boolean)) {
  throw new Error('Usage: summarize-two-org-load <normal-raw.json> <fault-raw.json> <timing-raw.json> <fault-events.json> <output.json>');
}
const normal = JSON.parse(fs.readFileSync(normalPath, 'utf8'));
const fault = JSON.parse(fs.readFileSync(faultPath, 'utf8'));
const timing = JSON.parse(fs.readFileSync(timingPath, 'utf8'));
const events = JSON.parse(fs.readFileSync(eventsPath, 'utf8'));
const ms = value => Date.parse(value);
const check = (condition, message) => { if (!condition) throw new Error(message); };
function percentile(values, fraction) {
  const ordered = [...values].sort((a, b) => a - b);
  const index = Math.min(ordered.length - 1, Math.ceil(ordered.length * fraction) - 1);
  return Math.round(ordered[index]);
}

function inspectRun(run, expected) {
  check(run.summary?.offered === expected && run.summary?.accepted === expected &&
    run.summary?.confirmed === expected && run.summary?.failed === 0 && run.summary?.pending === 0,
  `${run.mode}: incomplete submissions`);
  check(run.summary.crossOrgDenied === run.summary.crossOrgChecks, `${run.mode}: cross-org denial failed`);
  check(run.summary.apiHashesMatched === expected && run.summary.ledgerHashesMatched === expected &&
    run.summary.historyReadable === expected && run.summary.duplicateHistories === 0,
  `${run.mode}: footprint, history, or duplicate check failed`);
  check(run.submissions.every(row => Number.isFinite(ms(row.offeredAt)) &&
    Number.isFinite(ms(row.acceptedAt)) && Number.isFinite(ms(row.ledgerCommittedAt))),
  `${run.mode}: missing timestamps`);
  const start = ms(run.loadStartedAt);
  const end = ms(run.loadEndedAt);
  const commits = run.submissions.map(row => ms(row.ledgerCommittedAt));
  const lastCommit = Math.max(...commits);
  const lastOffered = Math.max(...run.submissions.map(row => ms(row.offeredAt)));
  check(start <= lastOffered && end >= lastOffered && lastCommit >= start, `${run.mode}: inconsistent timeline`);
  const drainObservedAt = ms(run.drainObservedAt);
  check(drainObservedAt >= lastCommit && drainObservedAt >= end, `${run.mode}: invalid observation time`);
  return {
    start, end, lastCommit,
    recordTimestampDrainSeconds: Math.round((lastCommit - end) / 100) / 10,
    observedDrainSeconds: Math.round((drainObservedAt - end) / 100) / 10,
  };
}

const normalTime = inspectRun(normal, 330);
const faultTime = inspectRun(fault, 90);
const timingTime = inspectRun(timing, 155);
check(normal.summary.ledgerTransactionsMatched === 330, 'Normal load has a transaction-pointer mismatch');
check(fault.summary.ledgerTransactionsMatched === 89, 'Fault transaction-pointer result changed; review before publishing');
check(timing.summary.ledgerTransactionsMatched === 155, 'Timing load has a transaction-pointer mismatch');
check(Array.isArray(events.events) && events.events.length === 2, 'Need two observed gateway scaling events');
const downAt = ms(events.events[0].at);
const upAt = ms(events.events[1].at);
check(downAt >= faultTime.start && upAt > downAt && upAt <= faultTime.end,
  'Gateway scale events do not lie within the fault traffic window');

function timeline(run, time, stepSeconds) {
  const finish = Math.ceil((time.lastCommit - time.start) / (stepSeconds * 1000)) * stepSeconds;
  const rows = [];
  for (let second = 0; second <= finish; second += stepSeconds) {
    const cutoff = time.start + second * 1000;
    const offered = run.submissions.filter(row => ms(row.offeredAt) <= cutoff).length;
    const accepted = run.submissions.filter(row => ms(row.acceptedAt) <= cutoff).length;
    const confirmed = run.submissions.filter(row => ms(row.ledgerCommittedAt) <= cutoff).length;
    check(confirmed <= accepted + 2, `${run.mode}: timestamp clocks are too far apart for a backlog chart`);
    rows.push({ second, offered, accepted, recordedTransactionTime: confirmed,
      unrecordedAtTransactionTime: Math.max(0, accepted - confirmed) });
  }
  return rows;
}

const stageLatency = timing.stages.map(stage => {
  const rows = timing.submissions.filter(row => row.stage === stage.rate && row.sampled);
  check(rows.length === Math.min(10, stage.rate * stage.seconds) &&
    rows.every(row => Number.isFinite(ms(row.firstObservedSuccessAt))),
  `Missing ${stage.rate}/s live-polling samples`);
  const times = rows.map(row => ms(row.firstObservedSuccessAt) - ms(row.offeredAt));
  check(times.every(value => value >= 0), 'Negative observed confirmation latency');
  return { rate: stage.rate, n: rows.length, medianMs: percentile(times, 0.5),
    p95Ms: percentile(times, 0.95), maxMs: Math.max(...times) };
});

const crossOrgByRate = normal.stages.map((stage, index) => {
  const checks = normal.crossOrgChecks.filter(row => row.second >= index * 5 && row.second < (index + 1) * 5);
  return { rate: stage.rate, checks: checks.length, forbidden: checks.filter(row => row.actualStatus === 403).length };
});

const stageThroughput = normal.stages.map((stage, index) => {
  const from = normalTime.start + index * 5000;
  const to = from + 5000;
  const inWindow = field => normal.submissions.filter(row => ms(row[field]) >= from && ms(row[field]) < to).length;
  return {
    offeredRate: stage.rate,
    offeredPerSecond: inWindow('offeredAt') / 5,
    acceptedPerSecond: inWindow('acceptedAt') / 5,
    fabricRecordTimestampsPerSecond: inWindow('ledgerCommittedAt') / 5,
  };
});

function integrity(run) {
  return {
    n: run.summary.confirmed,
    apiHashMatched: run.summary.apiHashesMatched,
    ledgerHashMatched: run.summary.ledgerHashesMatched,
    ledgerTxPointerMatched: run.summary.ledgerTransactionsMatched,
    singleRevision: run.summary.confirmed - run.summary.duplicateHistories,
  };
}

const summary = {
  schemaVersion: 1, runId: 'usrse260930', generatedAt: new Date().toISOString(),
  scope: 'Two AWS Fabric peer organizations; bounded synthetic private load; no third organization or real research file bytes.',
  method: {
    source: 'One-off in-cluster Job using the already pinned API gateway image, with no Kubernetes service-account token and a read-only root filesystem.',
    normal: 'Five 5-second stages at 1, 5, 10, 20, 30 offered submissions/second, split evenly between NSG and Citizen Science; 330 timed writes plus two pre-test seed records.',
    fault: 'Thirty seconds at 3 offered submissions/second, split between the two organizations; 90 timed writes plus two seed records. NSG ledger gateway was scaled from two replicas to zero, then back to two.',
    confirmation: 'For a separate 155-write timing run, a 1-second poll on five to ten sampled records per rate measured submission to first observed API SUCCESS with a transaction ID. Timing resolution is approximately one second.',
    backlog: 'Accepted count minus the count with a Fabric transaction timestamp at each timeline sample. This is a proxy for work not yet written, not exact ledger finality or RabbitMQ queue depth. End-of-run drain is measured separately when all API records were first observed SUCCESS.',
    integrity: 'Original synthetic SHA-256 footprint compared with API detail and Fabric history payload, and API blockchainTxId compared with Fabric history transactionId.',
    caveat: 'These short controlled runs are demonstration evidence, not a capacity or availability SLA. Test traffic and its ledger records persist.',
  },
  normal: {
    startUtc: normal.loadStartedAt, postEndUtc: normal.loadEndedAt,
    lastLedgerCommitUtc: new Date(normalTime.lastCommit).toISOString(),
    recordTimestampDrainSeconds: normalTime.recordTimestampDrainSeconds,
    observedDrainSeconds: normalTime.observedDrainSeconds,
    peakUnrecordedAtTransactionTime: Math.max(...timeline(normal, normalTime, 5).map(row => row.unrecordedAtTransactionTime)),
    counts: normal.summary,
    stageThroughput,
    crossOrgByRate,
    integrity: integrity(normal),
    timelineFiveSeconds: timeline(normal, normalTime, 5),
  },
  timing: {
    startUtc: timing.loadStartedAt, postEndUtc: timing.loadEndedAt,
    observedDrainSeconds: timingTime.observedDrainSeconds,
    counts: timing.summary, stageObservedConfirmationLatency: stageLatency,
    sampledCount: stageLatency.reduce((sum, stage) => sum + stage.n, 0),
  },
  fault: {
    startUtc: fault.loadStartedAt, postEndUtc: fault.loadEndedAt,
    lastLedgerCommitUtc: new Date(faultTime.lastCommit).toISOString(),
    recordTimestampDrainSeconds: faultTime.recordTimestampDrainSeconds,
    observedDrainSeconds: faultTime.observedDrainSeconds,
    gatewayScaledDownUtc: new Date(downAt).toISOString(),
    gatewayScaledUpUtc: new Date(upAt).toISOString(),
    gatewayScaleWindowSeconds: Math.round((upAt - downAt) / 1000),
    counts: fault.summary,
    integrity: integrity(fault),
    timelineTwoSeconds: timeline(fault, faultTime, 2),
  },
  finding: 'All 575 timed load records were confirmed with matching SHA-256 footprints and one Fabric history revision each. Under the gateway interruption, one API transaction pointer differed from the history transaction ID (89/90 matched). The chaincode idempotency-receipt path is a plausible cause, not a verified runtime trace.',
  evidence: {
    normalRaw: path.relative(process.cwd(), normalPath).replaceAll('\\', '/'),
    faultRaw: path.relative(process.cwd(), faultPath).replaceAll('\\', '/'),
    timingRaw: path.relative(process.cwd(), timingPath).replaceAll('\\', '/'),
    faultEvents: path.relative(process.cwd(), eventsPath).replaceAll('\\', '/'),
    rawReportsLocalIgnored: true,
  },
  credentialsRetained: false,
};
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ outputPath, normal: summary.normal.counts, fault: summary.fault.counts,
  timing: summary.timing.counts, normalObservedDrainSeconds: summary.normal.observedDrainSeconds,
  faultObservedDrainSeconds: summary.fault.observedDrainSeconds }));
