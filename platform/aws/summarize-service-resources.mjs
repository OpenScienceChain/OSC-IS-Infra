import fs from 'node:fs/promises';

const [sourcePath, outputPath] = process.argv.slice(2);
if (!sourcePath || !outputPath) throw new Error('Usage: node summarize-service-resources.mjs RAW_JSON OUTPUT_JSON');
const raw = JSON.parse(await fs.readFile(sourcePath, 'utf8'));
if (raw.context !== 'osc-usrse26-usrse260930' || raw.schemaVersion !== 1) throw new Error('Unexpected resource source');

function service(pod) {
  if (/^org[12]-peer[12](?:-|$)/.test(pod)) return 'Fabric peers';
  if (/^org0-orderer/.test(pod)) return 'Fabric orderers';
  if (/^org[12]peer[12]-ccaas/.test(pod)) return 'Chaincode';
  if (/^org[012]-ca$/.test(pod)) return 'Fabric CAs';
  if (/^ledger-gateway-/.test(pod)) return 'Ledger gateways';
  if (/^history-worker-/.test(pod)) return 'History workers';
  if (/^submission-worker-/.test(pod)) return 'Submission workers';
  if (/^submission-listener-/.test(pod)) return 'Submission listeners';
  if (/^api-gateway-/.test(pod)) return 'API gateway';
  if (/^postgres-/.test(pod)) return 'PostgreSQL';
  return null;
}

const samples = [...new Set(raw.rows.map(row => row.sampledAt))].sort();
const services = [...new Set(raw.rows.map(row => service(row.pod)).filter(Boolean))].sort();
const byService = services.map(name => {
  const totals = samples.map(at => {
    const rows = raw.rows.filter(row => row.sampledAt === at && service(row.pod) === name);
    return {
      cpuMilliCores: rows.reduce((sum, row) => sum + (row.cpuMilliCores ?? 0), 0),
      workingSetMiB: rows.reduce((sum, row) => sum + (row.workingSetMiB ?? 0), 0),
    };
  });
  const mean = key => Math.round(totals.reduce((sum, item) => sum + item[key], 0) / totals.length * 10) / 10;
  return { service: name, meanCpuMilliCores: mean('cpuMilliCores'), meanWorkingSetMiB: mean('workingSetMiB') };
});

const result = {
  schemaVersion: 1,
  runId: 'usrse260930',
  method: 'Read-only kubelet stats/summary snapshots during an additional 330-write two-org normal staged run. Per-sample pod values are summed into logical services, then arithmetic means are taken over 12 samples. CPU is instantaneous usageNanoCores; memory is working-set bytes. Transient load Job is excluded.',
  sampleCount: samples.length,
  firstSampleUtc: samples[0],
  lastSampleUtc: samples.at(-1),
  byService,
};
if (samples.length !== raw.requestedSamples || byService.some(item => !Number.isFinite(item.meanCpuMilliCores))) throw new Error('Incomplete resource sample');
await fs.writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`);
