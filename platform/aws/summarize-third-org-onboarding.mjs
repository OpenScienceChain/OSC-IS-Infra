import fs from 'node:fs/promises';

const [timelinePath, milestonesPath, e2ePath, beforePath, afterPath, outputPath] = process.argv.slice(2);
if ([timelinePath, milestonesPath, e2ePath, beforePath, afterPath, outputPath].some(value => !value)) {
  throw new Error('Usage: summarize-third-org-onboarding TIMELINE MILESTONES E2E BEFORE AFTER OUTPUT');
}
const lines = async path => (await fs.readFile(path, 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
const [timeline, milestones, e2e, before, after] = await Promise.all([
  lines(timelinePath), lines(milestonesPath), fs.readFile(e2ePath, 'utf8').then(JSON.parse),
  fs.readFile(beforePath, 'utf8').then(JSON.parse), fs.readFile(afterPath, 'utf8').then(JSON.parse),
]);
if (timeline.length < 20 || e2e.failedSubmissions || e2e.successfulSubmissions !== 4 || e2e.passedChecks !== 9) {
  throw new Error('Onboarding evidence incomplete');
}
if (before.nodes.length !== 3 || after.nodes.length !== 3 || after.readyPods !== after.totalPods) {
  throw new Error('Cluster footprint is not the expected healthy three-node state');
}
const revision = '88c34a5f9cd0c7b7516e93da3cfceca596b4c5ad';
if (after.argo.revision !== revision || after.argo.sync !== 'Synced' || after.argo.health !== 'Healthy') {
  throw new Error('Argo did not converge on the third-org revision');
}
const startMs = Date.parse(timeline[0].capturedAt);
const seconds = iso => Math.round((Date.parse(iso) - startMs) / 1000);
const event = (label, iso, source, precision) => ({ label, atUtc: iso, elapsedSec: seconds(iso), source, precision });
const phaseNames = [
  ['identity-ready', 'Fabric identity ready'],
  ['peer-pod-ready', 'Fabric peer pod ready'],
  ['channel-config-committed', 'Channel includes org three'],
  ['peer-joined-and-readable', 'Peer joined channel'],
  ['chaincode-ready', 'Chaincode ready'],
];
const events = [event('Kickoff snapshot', timeline[0].capturedAt, 'Kubernetes sampler', 'sample timestamp')];
for (const [phase, label] of phaseNames) {
  const row = milestones.find(item => item.phase === phase);
  if (!row) throw new Error(`Missing milestone: ${phase}`);
  events.push(event(label, row.atUtc, 'Fabric operator event', 'one-second timestamp'));
}
const synced = timeline.find(row => row.argoRevision === revision && row.argoSync === 'Synced' && row.argoHealth === 'Healthy');
const appsReady = timeline.find(row => row.thirdAppReady >= 2);
if (!synced || !appsReady) throw new Error('Missing observed GitOps/application readiness');
events.push(event('Argo Synced and Healthy observed', synced.capturedAt, 'Kubernetes sampler', 'up to next sample'));
events.push(event('Third app services ready observed', appsReady.capturedAt, 'Kubernetes sampler', 'up to next sample'));
const magneticArtifact = e2e.submissions.find(row => row.type === 'artifact' && row.organization === 'Magnetic Arch');
const magneticWorkflow = e2e.submissions.find(row => row.type === 'workflow' && row.organization === 'Magnetic Arch');
if (!magneticArtifact || !magneticWorkflow || magneticArtifact.result !== 'SUCCESS' || magneticWorkflow.result !== 'SUCCESS') {
  throw new Error('Third-org transactions are not confirmed');
}
events.push(event('First third-org artifact confirmed', magneticArtifact.confirmedAt, 'API plus Fabric transaction ID', 'one-second API polling'));
events.push(event('First third-org workflow confirmed', magneticWorkflow.confirmedAt, 'API plus Fabric transaction ID', 'one-second API polling'));
events.sort((a, b) => a.elapsedSec - b.elapsedSec);
const firstByMinute = new Map();
for (const row of timeline) {
  const bucket = Math.floor(seconds(row.capturedAt) / 60);
  if (!firstByMinute.has(bucket)) firstByMinute.set(bucket, row);
}
const readiness = [...firstByMinute.values(), timeline.at(-1)].map(row => ({
  elapsedSec: seconds(row.capturedAt), fabricReady: row.thirdFabricReady,
  appReady: row.thirdAppReady, argoReady: Number(row.argoRevision === revision && row.argoSync === 'Synced' && row.argoHealth === 'Healthy'),
  nodesReady: row.readyNodes,
}));
const summary = {
  schemaVersion: 1, runId: 'usrse260930', account: '269624229733', region: 'us-west-2',
  method: {
    boundary: 'Observed operator-led third-org addition. Elapsed includes manual preparation, verification, and pauses; it is not an automated provisioning benchmark.',
    timelineSamples: timeline.length, firstSampleUtc: timeline[0].capturedAt, lastSampleUtc: timeline.at(-1).capturedAt,
    sampling: 'Approximately 10-14 seconds between completed Kubernetes/Argo snapshots; readiness is first observed, not exact transition time.',
    probe: e2e.method,
    e2ePollResolution: '1 second; confirmation and history may be observed up to approximately one poll late.',
  },
  events, readiness,
  gitops: { revision, firstSyncedHealthyObservedAt: synced.capturedAt, firstThirdAppReadyObservedAt: appsReady.capturedAt },
  firstProvenance: {
    artifact: { acceptedMs: magneticArtifact.acceptedMs, confirmedMs: magneticArtifact.confirmedMs, historyMs: magneticArtifact.historyMs, catalogMs: magneticArtifact.catalogMs, historyTotal: magneticArtifact.historyTotal },
    workflow: { acceptedMs: magneticWorkflow.acceptedMs, confirmedMs: magneticWorkflow.confirmedMs },
  },
  continuity: {
    artifacts: e2e.submissions.filter(row => row.type === 'artifact').map(row => ({ organization: row.organization, result: row.result, confirmedMs: row.confirmedMs, historyTotal: row.historyTotal })),
    passedOwnershipChecks: e2e.passedChecks, totalOwnershipChecks: e2e.checks.length,
  },
  footprint: {
    before: { capturedAt: before.capturedAt, nodes: before.nodes.length, pods: before.totalPods, readyPods: before.readyPods, fabricPods: before.podCountsByNamespace['osc-fabric'].total, appPods: before.podCountsByNamespace['osc-apps'].total },
    after: { capturedAt: after.capturedAt, nodes: after.nodes.length, pods: after.totalPods, readyPods: after.readyPods, fabricPods: after.podCountsByNamespace['osc-fabric'].total, appPods: after.podCountsByNamespace['osc-apps'].total },
  },
  caveats: [
    'The first peer-join attempt used a config block and failed; the corrected genesis-block join succeeded. The correction is included in observed wall time.',
    'One original two-org fault-run API transaction pointer differed from Fabric history; this onboarding test does not resolve that separate integrity finding.',
    'The third peer and CA share an existing node with Citizen Science, so no fourth node was added but host failure isolation is weaker.',
  ],
};
await fs.writeFile(outputPath, `${JSON.stringify(summary, null, 2)}\n`);
console.log(JSON.stringify({ events: events.length, timelineSamples: timeline.length, footprint: summary.footprint, passedChecks: e2e.passedChecks }, null, 2));
