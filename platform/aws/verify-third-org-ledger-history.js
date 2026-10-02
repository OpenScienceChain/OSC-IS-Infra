#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

const [reportPath, outputPath] = process.argv.slice(2);
if (!reportPath || !outputPath) throw new Error('Usage: verify-third-org-ledger-history E2E_REPORT OUTPUT');
const context = execFileSync('kubectl', ['config', 'current-context'], { encoding: 'utf8' }).trim();
if (context !== 'osc-usrse26-usrse260930') throw new Error(`Refusing context ${context}`);
const account = JSON.parse(execFileSync('aws', ['sts', 'get-caller-identity', '--output', 'json'], { encoding: 'utf8' })).Account;
if (account !== '269624229733') throw new Error(`Refusing account ${account}`);
const e2e = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const records = e2e.submissions.filter(row => row.organization === 'Magnetic Arch' && row.result === 'SUCCESS');
if (records.length !== 2 || !records.some(row => row.type === 'artifact') || !records.some(row => row.type === 'workflow')) {
  throw new Error('Expected one confirmed third-org artifact and workflow');
}
const secret = JSON.parse(execFileSync('aws', [
  'secretsmanager', 'get-secret-value', '--region', 'us-west-2',
  '--secret-id', 'osc-usrse26-usrse260930/ledger-token/magnetic-arch',
  '--query', 'SecretString', '--output', 'text',
], { encoding: 'utf8' }));
if (!secret.token || secret.token.length < 32) throw new Error('Third-org ledger token unavailable');

async function main() {
  const checks = [];
  for (const row of records) {
    const route = row.type === 'workflow' ? 'workflow/history' : 'history';
    const response = await fetch(`http://127.0.0.1:18988/${route}/${row.id}`, {
      headers: { Authorization: `Bearer ${secret.token}` },
      signal: AbortSignal.timeout(30000),
    });
    if (response.status !== 200) throw new Error(`${row.type} Fabric history: HTTP ${response.status}`);
    const history = await response.json();
    const match = Array.isArray(history) && history.some(item => item.transactionId === row.transactionId);
    checks.push({ type: row.type, historyItems: Array.isArray(history) ? history.length : null, transactionIdMatchesApi: match });
    if (!match) throw new Error(`${row.type} API transaction ID absent from Fabric history`);
  }
  const result = {
    runId: 'usrse260930', capturedAt: new Date().toISOString(),
    method: 'Private localhost-only port-forward to the MagneticArchMSP ledger gateway; direct Fabric history reads for the confirmed artifact and workflow.',
    checks, passed: checks.length === 2 && checks.every(check => check.transactionIdMatchesApi),
    credentialsRetained: false,
  };
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
  console.log(`Third-org direct Fabric history: ${checks.length}/2 transaction IDs matched`);
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
