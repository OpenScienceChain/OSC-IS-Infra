#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const [runId, outputPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !outputPath) {
  throw new Error('Usage: summarize-two-org-metrics <run-id> <output-path>');
}
const root = path.resolve(__dirname, '../..');
const generated = path.join(root, 'platform', '.generated', 'aws', runId, 'evidence', 'metrics');
const historical = path.join(root, 'docs', 'usrse26', 'platform-evidence', runId);
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const probe = read(path.join(generated, 'two-org-baseline.json'));
const footprint = read(path.join(generated, 'two-org-footprint.json'));
const restoredFootprint = read(path.join(generated, 'two-org-footprint-post-recovery.json'));
const postman = read(path.join(generated, 'postman-post-recovery-repeat.json'));
const recovery = [
  read(path.join(historical, 'aws-recovery-summary.json')),
  read(path.join(generated, 'recovery-repeat-2', 'summary.json')),
];
const drift = [
  read(path.join(historical, 'aws-gitops-drift-summary.json')),
  ...[1, 2, 3].map(index => read(path.join(generated, `drift-repeat-${index}.json`))),
];

function assert(condition, message) { if (!condition) throw new Error(message); }
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}
function values(rows, field) { return rows.map(row => row[field]); }
function distribution(rows, field) {
  const sample = values(rows, field);
  assert(sample.length > 0 && sample.every(value => Number.isFinite(value)), `Missing ${field}`);
  return { n: sample.length, valuesMs: sample, medianMs: median(sample), minMs: Math.min(...sample), maxMs: Math.max(...sample) };
}
function rows(type, organization, mode) {
  return probe.submissions.filter(row => row.type === type && row.organization === organization &&
    (mode === 'paired' ? row.phase.startsWith('paired-') : row.phase === mode));
}

assert(probe.runId === runId && footprint.runId === runId && restoredFootprint.runId === runId, 'Run ID mismatch');
assert(probe.account === '269624229733' && footprint.account === probe.account, 'AWS account mismatch');
assert(probe.submissions.length === 30 && probe.successfulSubmissions === 30 && probe.failedSubmissions === 0, 'Submission count or result mismatch');
assert(probe.isolationChecks.length === 10 && probe.isolationChecks.every(check => check.passed), 'Isolation check failed');
assert(postman.requests === 6 && postman.failures === 0 && postman.failedAssertions === 0, 'Post-recovery Postman smoke failed');
assert(recovery.every(run => run.duplicateLedgerWritesObserved === false &&
  run.ledgerGatewayRecovery.ledgerRevisions === 1 && run.rabbitMqRecovery.ledgerRevisions === 1 &&
  run.peerFailure.ledgerRevisions === 1), 'Recovery ledger revision check failed');
assert(drift.every(run => run.selfHealVerified && run.restoredReplicas === 2 && run.gitopsRevision === drift[0].gitopsRevision), 'GitOps drift check failed');
assert([footprint, restoredFootprint].every(snapshot => snapshot.nodes.length === 3 &&
  snapshot.nodes.every(node => node.ready) && snapshot.readyPods === snapshot.totalPods &&
  snapshot.argo.sync === 'Synced' && snapshot.argo.health === 'Healthy'), 'Footprint snapshot unhealthy');

const organizations = ['NSG', 'Citizen Science'];
const submissionTiming = {};
for (const organization of organizations) {
  const sequential = rows('artifact', organization, 'sequential');
  const paired = rows('artifact', organization, 'paired');
  const workflow = rows('workflow', organization, 'sequential');
  const catalog = rows('artifact', organization, 'catalog');
  assert(sequential.length === 8 && paired.length === 4 && workflow.length === 2 && catalog.length === 1, `Probe sample count mismatch for ${organization}`);
  submissionTiming[organization] = {
    artifactSequential: { accepted: distribution(sequential, 'acceptedMs'), confirmed: distribution(sequential, 'confirmedMs'), history: distribution(sequential, 'historyMs') },
    artifactPaired: { accepted: distribution(paired, 'acceptedMs'), confirmed: distribution(paired, 'confirmedMs') },
    workflow: { accepted: distribution(workflow, 'acceptedMs'), confirmed: distribution(workflow, 'confirmedMs') },
    publicArtifact: {
      acceptedMs: catalog[0].acceptedMs,
      confirmedMs: catalog[0].confirmedMs,
      historyMs: catalog[0].historyMs,
      catalogMs: catalog[0].catalogMs,
    },
  };
}

const summary = {
  schemaVersion: 1,
  runId, account: probe.account, region: probe.region,
  generatedAt: new Date().toISOString(),
  measurementWindowUtc: { start: probe.startedAt, end: restoredFootprint.capturedAt },
  scope: 'Two Fabric peer organizations on one EKS cluster. No third organization was deployed or timed.',
  methodology: {
    submissions: 'Client monotonic time from POST start to the first observed state. Private synthetic hash-only probes, except one public catalog probe per org.',
    pollIntervalMs: probe.method.pollIntervalMs,
    timingPrecision: 'Ledger, history, and catalog values include polling delay of up to approximately one second; small between-org differences are not meaningful.',
    drift: 'Client-observed time from a deliberate API replica change to Argo Synced/Healthy with two replicas; four observations, not an SLA.',
    recovery: 'Elapsed from disruption command through a confirmed probe transaction; peer scenario times alternate-peer acceptance while one peer is down. Two observations per scenario, not a reliability benchmark.',
    cpu: 'AWS/EC2 five-minute CPUUtilization datapoints for the preceding hour, not pod-level CPU or memory usage.',
    cost: 'Reviewed planning estimate, not actual AWS billing.',
  },
  submissions: { total: probe.submissions.length, confirmed: probe.successfulSubmissions, failed: probe.failedSubmissions,
    artifacts: probe.submissions.filter(row => row.type === 'artifact').length,
    workflows: probe.submissions.filter(row => row.type === 'workflow').length },
  submissionTiming,
  isolation: { checks: probe.isolationChecks.length, passed: probe.passedIsolationChecks,
    checksByLabel: probe.isolationChecks.map(check => ({ label: check.label, expectedStatus: check.expectedStatus, actualStatus: check.actualStatus })) },
  postRecoveryPostman: { requests: postman.requests, failures: postman.failures, failedAssertions: postman.failedAssertions },
  recovery: {
    ledgerGatewaySeconds: recovery.map(run => run.ledgerGatewayRecovery.recoverySeconds),
    rabbitMqSeconds: recovery.map(run => run.rabbitMqRecovery.recoverySeconds),
    alternatePeerAcceptanceSeconds: recovery.map(run => run.peerFailure.recoverySeconds),
    allLedgerRevisionsOne: true, duplicateWritesObserved: false,
  },
  gitops: { secondsToSyncedHealthy: drift.map(run => run.secondsToSyncedHealthy),
    allSelfHealed: true, revision: drift[0].gitopsRevision },
  footprint: {
    nodes: footprint.nodes.length, zones: [...new Set(footprint.nodes.map(node => node.zone))].sort(),
    totalPods: footprint.totalPods, readyPods: footprint.readyPods,
    podCountsByNamespace: footprint.podCountsByNamespace,
    nodeCpuFiveMinutePercent: footprint.ec2CpuWindow.instances.map(instance => ({
      zone: instance.zone, points: instance.fiveMinutePoints,
      mean: instance.meanFiveMinuteCpuPct, peak: instance.peakFiveMinuteCpuPct,
    })),
    cpuWindowUtc: { start: footprint.ec2CpuWindow.start, end: footprint.ec2CpuWindow.end },
    postRecoveryReadyPods: restoredFootprint.readyPods,
    memoryUsageAvailable: false,
  },
  estimatedHourlyUsd: 0.9425,
  estimated24HoursUsd: 22.62,
  evidence: {
    detailedProbePath: 'platform/.generated/aws/usrse260930/evidence/metrics/two-org-baseline.json (local, ignored)',
    footprintPath: 'platform/.generated/aws/usrse260930/evidence/metrics/two-org-footprint.json (local, ignored)',
    recoveryHistoricalPath: 'docs/usrse26/platform-evidence/usrse260930/aws-recovery-summary.json',
    recoveryRepeatPath: 'platform/.generated/aws/usrse260930/evidence/metrics/recovery-repeat-2/summary.json (local, ignored)',
    driftHistoricalPath: 'docs/usrse26/platform-evidence/usrse260930/aws-gitops-drift-summary.json',
    driftRepeatPaths: [1, 2, 3].map(index => `platform/.generated/aws/usrse260930/evidence/metrics/drift-repeat-${index}.json (local, ignored)`),
  },
  credentialsRetained: false,
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({
  confirmed: summary.submissions.confirmed,
  isolationChecks: summary.isolation.passed,
  recovery: summary.recovery,
  gitops: summary.gitops.secondsToSyncedHealthy,
  footprint: { nodes: summary.footprint.nodes, pods: summary.footprint.totalPods },
}, null, 2));
