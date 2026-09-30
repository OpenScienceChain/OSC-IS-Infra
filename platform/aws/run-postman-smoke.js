#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const newman = require('newman');

const [runId, collectionPath, environmentPath, reportPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !collectionPath || !environmentPath || !reportPath) {
  throw new Error('Usage: run-postman-smoke <run-id> <collection> <environment> <report>');
}

const context = execFileSync('kubectl', ['config', 'current-context'], { encoding: 'utf8' }).trim();
if (context !== `osc-usrse26-${runId}`) {
  throw new Error('Refusing to test a different Kubernetes context');
}

const secret = JSON.parse(execFileSync('kubectl', [
  '-n', 'osc-apps', 'get', 'secret', 'e2e-user-credentials', '-o', 'json',
], { encoding: 'utf8' }));
const password = Buffer.from(secret.data.password, 'base64').toString('utf8');
if (!password || password.length < 20) {
  throw new Error('Seeded test password is missing');
}

const collection = JSON.parse(fs.readFileSync(collectionPath, 'utf8'));
const environment = JSON.parse(fs.readFileSync(environmentPath, 'utf8'));
const values = new Map(environment.values.map(value => [value.key, value]));
for (const [key, value] of Object.entries({
  baseUrl: 'http://127.0.0.1:18989/api/v1',
  nsgUsername: 'nsg-pi',
  nsgPassword: password,
  citizenScienceUsername: 'citizen-contributor',
  citizenSciencePassword: password,
  nsgExpectedOrganizationName: 'NEUROSCIENCE GATEWAY',
  citizenScienceExpectedOrganizationName: 'CITIZEN SCIENCE',
})) {
  if (!values.has(key)) throw new Error(`Missing Postman variable: ${key}`);
  values.get(key).value = value;
}

newman.run({
  collection,
  environment,
  folder: 'Multi-organization smoke',
  reporters: [],
  timeoutRequest: 30000,
}, (error, summary) => {
  if (error) throw error;
  const executions = summary.run.executions.map(execution => ({
    item: execution.item.name,
    status: execution.response?.code ?? null,
    responseTimeMs: execution.response?.responseTime ?? null,
    assertions: (execution.assertions || []).map(assertion => ({
      name: assertion.assertion,
      passed: !assertion.error,
    })),
  }));
  const report = {
    runId,
    capturedAt: new Date().toISOString(),
    target: 'localhost-only EKS API port-forward',
    collection: collection.info.name,
    folder: 'Multi-organization smoke',
    requests: executions.length,
    failedAssertions: executions.flatMap(item => item.assertions).filter(item => !item.passed).length,
    failures: summary.run.failures.length,
    executions,
  };
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
  console.log(`Postman AWS smoke: ${report.requests} requests, ${report.failedAssertions} failed assertions, ${report.failures} failures`);
  if (report.failures || report.failedAssertions || executions.some(item => item.status === null)) {
    process.exitCode = 1;
  }
});
