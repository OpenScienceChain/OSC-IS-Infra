#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const [runId, reportPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !reportPath) {
  throw new Error('Usage: capture-two-org-footprint <run-id> <report-path>');
}

function command(binary, args) {
  return execFileSync(binary, args, { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 }).trim();
}
function json(binary, args) { return JSON.parse(command(binary, args)); }

const expectedContext = `osc-usrse26-${runId}`;
const context = command('kubectl', ['config', 'current-context']);
if (context !== expectedContext) throw new Error(`Refusing Kubernetes context ${context}`);
const account = json('aws', ['sts', 'get-caller-identity', '--output', 'json']).Account;
if (account !== '269624229733') throw new Error(`Refusing AWS account ${account}`);

const capturedAt = new Date();
const start = new Date(capturedAt.getTime() - 60 * 60 * 1000);
const nodes = json('kubectl', ['get', 'nodes', '-o', 'json']).items;
const pods = json('kubectl', ['get', 'pods', '-A', '-o', 'json']).items;
const app = json('kubectl', ['-n', 'argocd', 'get', 'application', 'osc-is-aws', '-o', 'json']);
const namespaceCounts = {};
for (const pod of pods) {
  const namespace = pod.metadata.namespace;
  const count = namespaceCounts[namespace] || { total: 0, ready: 0 };
  count.total++;
  if (pod.status.phase === 'Running' && pod.status.containerStatuses?.every(container => container.ready)) count.ready++;
  namespaceCounts[namespace] = count;
}

const ec2 = json('aws', ['ec2', 'describe-instances', '--region', 'us-west-2',
  '--filters', `Name=tag:eks:cluster-name,Values=osc-usrse26-${runId}-eks`, 'Name=instance-state-name,Values=running',
  '--output', 'json']);
const instances = ec2.Reservations.flatMap(reservation => reservation.Instances);
const cpu = instances.map(instance => {
  const data = json('aws', ['cloudwatch', 'get-metric-statistics', '--region', 'us-west-2',
    '--namespace', 'AWS/EC2', '--metric-name', 'CPUUtilization',
    '--dimensions', `Name=InstanceId,Value=${instance.InstanceId}`,
    '--start-time', start.toISOString(), '--end-time', capturedAt.toISOString(),
    '--period', '300', '--statistics', 'Average', 'Maximum', '--output', 'json']);
  const points = data.Datapoints || [];
  return {
    instanceId: instance.InstanceId,
    zone: instance.Placement.AvailabilityZone,
    type: instance.InstanceType,
    fiveMinutePoints: points.length,
    meanFiveMinuteCpuPct: points.length ? Math.round(points.reduce((sum, point) => sum + point.Average, 0) / points.length * 10) / 10 : null,
    peakFiveMinuteCpuPct: points.length ? Math.round(Math.max(...points.map(point => point.Maximum)) * 10) / 10 : null,
  };
});

const report = {
  runId, account, region: 'us-west-2', context,
  capturedAt: capturedAt.toISOString(),
  cluster: `osc-usrse26-${runId}-eks`,
  nodes: nodes.map(node => ({
    name: node.metadata.name,
    ready: node.status.conditions?.some(condition => condition.type === 'Ready' && condition.status === 'True') ?? false,
    zone: node.metadata.labels['topology.kubernetes.io/zone'],
    cpuCapacity: node.status.capacity.cpu,
    memoryCapacityKi: node.status.capacity.memory,
  })),
  podCountsByNamespace: namespaceCounts,
  totalPods: pods.length,
  readyPods: Object.values(namespaceCounts).reduce((sum, namespace) => sum + namespace.ready, 0),
  argo: { sync: app.status.sync.status, health: app.status.health.status, revision: app.status.sync.revision },
  ec2CpuWindow: { start: start.toISOString(), end: capturedAt.toISOString(), periodSeconds: 300, instances: cpu },
  memoryUsage: null,
  memoryUsageNote: 'The Kubernetes Metrics API is not installed; node memory usage is unavailable. Capacity is reported instead.',
  credentialsRetained: false,
};
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
console.log(JSON.stringify({
  nodes: report.nodes.length, readyNodes: report.nodes.filter(node => node.ready).length,
  pods: report.totalPods, readyPods: report.readyPods, argo: report.argo,
  cpu: report.ec2CpuWindow.instances,
}, null, 2));
