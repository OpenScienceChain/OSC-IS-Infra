#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PUBLIC_API_BASE_URL = 'https://demo.osc-staging.org/api/v1';
export const MAX_CONCURRENCY = 100;
export const SUCCESS_START_LIMIT = 300;
export const RATE_WINDOW_MS = 60_000;
export const APPLICATION_TIMEOUT_MS = 70_000;

const DEFAULT_SUCCESS_REQUESTS = 240;
const DEFAULT_RATE_REQUESTS = 600;
const DEFAULT_CLEAR_WAIT_MS = 65_000;
const DEFAULT_RECOVERY_INTERVAL_MS = 5_000;
const DEFAULT_RECOVERY_ATTEMPTS = 24;
const RATE_START_INTERVAL_MS = 100;
const REQUEST_TIMEOUT_MS = 80_000;
const RUN_ID = 'usrse26r1';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const DEFAULT_EVIDENCE_PATH = resolve(
  ROOT,
  'platform',
  '.generated',
  'evidence',
  'public-history-rehearsal',
  'summary.json',
);

const sleep = milliseconds => new Promise(resolveDelay => setTimeout(resolveDelay, milliseconds));

function integerSetting(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

export class RollingStartLimiter {
  constructor({
    limit = SUCCESS_START_LIMIT,
    windowMs = RATE_WINDOW_MS,
    now = Date.now,
    wait = sleep,
  } = {}) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.wait = wait;
    this.starts = [];
  }

  async acquire() {
    while (true) {
      const current = this.now();
      this.starts = this.starts.filter(started => started > current - this.windowMs);
      if (this.starts.length < this.limit) {
        this.starts.push(current);
        return current;
      }
      const waitMs = Math.max(1, this.starts[0] + this.windowMs - current);
      await this.wait(waitMs);
    }
  }
}

export class IntervalStartPacer {
  constructor({ intervalMs = RATE_START_INTERVAL_MS, now = Date.now, wait = sleep } = {}) {
    this.intervalMs = intervalMs;
    this.now = now;
    this.wait = wait;
    this.nextStart = 0;
  }

  async acquire() {
    const current = this.now();
    const permitted = Math.max(current, this.nextStart);
    this.nextStart = permitted + this.intervalMs;
    if (permitted > current) await this.wait(permitted - current);
    return permitted;
  }
}

export function maximumRollingStarts(records, windowMs = RATE_WINDOW_MS) {
  const starts = records.map(record => record.startedEpochMs).sort((left, right) => left - right);
  let left = 0;
  let maximum = 0;
  for (let right = 0; right < starts.length; right += 1) {
    while (starts[left] <= starts[right] - windowMs) left += 1;
    maximum = Math.max(maximum, right - left + 1);
  }
  return maximum;
}

export async function runPool(count, concurrency, operation) {
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > MAX_CONCURRENCY) {
    throw new Error(`concurrency must be between 1 and ${MAX_CONCURRENCY}`);
  }
  const results = new Array(count);
  let next = 0;
  let active = 0;
  let maximumConcurrency = 0;
  async function worker() {
    while (true) {
      const index = next;
      next += 1;
      if (index >= count) return;
      active += 1;
      maximumConcurrency = Math.max(maximumConcurrency, active);
      try {
        results[index] = await operation(index);
      } finally {
        active -= 1;
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, count) }, worker));
  return { results, maximumConcurrency };
}

function validateTargets(payload) {
  if (payload?.schemaVersion !== 1 || payload?.runId !== RUN_ID || !Array.isArray(payload.targets)) {
    throw new Error(`The fixture must be schema version 1 for ${RUN_ID}`);
  }
  if (payload.targets.length < 4) throw new Error('The fixture must provide both history types for both organizations');
  const organizations = new Set();
  const resources = new Set();
  for (const target of payload.targets) {
    if (!['neuroscience-gateway', 'citizen-science'].includes(target?.organization)) {
      throw new Error('Every target must use one reviewed organization');
    }
    const match = /^\/demo\/(artifacts|workflows)\/[0-9a-f-]{36}\/history$/.exec(target?.path || '');
    if (!match) throw new Error('Every target path must be one canonical confirmed history path');
    if (typeof target.cookie !== 'string' || !target.cookie.startsWith('__Host-osc_demo=')) {
      throw new Error('Every target must include its matching host-only guest cookie');
    }
    organizations.add(target.organization);
    resources.add(match[1]);
  }
  if (organizations.size !== 2 || resources.size !== 2) {
    throw new Error('The fixture must cover artifact and workflow histories in both organizations');
  }
  return payload.targets;
}

async function publicHistoryRequest(target) {
  const startedEpochMs = Date.now();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(`${PUBLIC_API_BASE_URL}${target.path}`, {
      method: 'GET',
      redirect: 'error',
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        Cookie: target.cookie,
        'X-Correlation-ID': randomUUID(),
      },
    });
    await response.arrayBuffer();
    return {
      startedEpochMs,
      startedAt: new Date(startedEpochMs).toISOString(),
      durationMs: Date.now() - startedEpochMs,
      status: response.status,
      error: null,
    };
  } catch (error) {
    return {
      startedEpochMs,
      startedAt: new Date(startedEpochMs).toISOString(),
      durationMs: Date.now() - startedEpochMs,
      status: null,
      error: error?.name || 'RequestError',
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function runPhase({ name, count, concurrency, targets, request, limiter = null }) {
  const phaseStartedAt = new Date().toISOString();
  const { results, maximumConcurrency } = await runPool(count, concurrency, async index => {
    if (limiter) await limiter.acquire();
    const record = await request(name, index, targets[index % targets.length]);
    return { sequence: index + 1, ...record };
  });
  return {
    name,
    startedAt: phaseStartedAt,
    completedAt: new Date().toISOString(),
    requested: count,
    maximumConcurrency,
    maximumStartsInRollingMinute: maximumRollingStarts(results),
    statusCounts: Object.fromEntries(
      [...new Set(results.map(record => String(record.status ?? record.error)))].sort().map(status => [
        status,
        results.filter(record => String(record.status ?? record.error) === status).length,
      ]),
    ),
    requests: results,
  };
}

export async function runRehearsal({
  targets,
  successCount = DEFAULT_SUCCESS_REQUESTS,
  rateCount = DEFAULT_RATE_REQUESTS,
  concurrency = MAX_CONCURRENCY,
  clearWaitMs = DEFAULT_CLEAR_WAIT_MS,
  recoveryIntervalMs = DEFAULT_RECOVERY_INTERVAL_MS,
  recoveryAttempts = DEFAULT_RECOVERY_ATTEMPTS,
  rateStartIntervalMs = RATE_START_INTERVAL_MS,
  now = Date.now,
  wait = sleep,
  request = (_phase, _index, target) => publicHistoryRequest(target),
} = {}) {
  if (!Number.isInteger(successCount) || successCount < 1 || successCount > SUCCESS_START_LIMIT) {
    throw new Error(`successCount must be between 1 and ${SUCCESS_START_LIMIT}`);
  }
  if (!Number.isInteger(rateCount) || rateCount <= SUCCESS_START_LIMIT || rateCount > 600) {
    throw new Error(`rateCount must be between ${SUCCESS_START_LIMIT + 1} and 600`);
  }
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > MAX_CONCURRENCY) {
    throw new Error(`concurrency must be between 1 and ${MAX_CONCURRENCY}`);
  }
  if (!Number.isInteger(rateStartIntervalMs) || rateStartIntervalMs < RATE_START_INTERVAL_MS) {
    throw new Error(`rateStartIntervalMs must be at least ${RATE_START_INTERVAL_MS}`);
  }

  const rehearsalStartedAt = new Date().toISOString();
  const success = await runPhase({
    name: 'paced-success',
    count: successCount,
    concurrency,
    targets,
    request,
    limiter: new IntervalStartPacer({ intervalMs: rateStartIntervalMs, now, wait }),
    limiter: new RollingStartLimiter({ now, wait }),
  });
  await wait(clearWaitMs);
  const rateLimit = await runPhase({
    name: 'read-only-rate-limit',
    count: rateCount,
    concurrency,
    targets,
    request,
  });
  await wait(clearWaitMs);

  const recoveryRequests = [];
  for (let index = 0; index < recoveryAttempts; index += 1) {
    const record = await request('recovery', index, targets[index % targets.length]);
    recoveryRequests.push({ sequence: index + 1, ...record });
    if (record.status === 200) break;
    if (index + 1 < recoveryAttempts) await wait(recoveryIntervalMs);
  }
  const recovery = {
    name: 'recovery',
    requested: recoveryRequests.length,
    maximumConcurrency: 1,
    maximumStartsInRollingMinute: maximumRollingStarts(recoveryRequests),
    statusCounts: Object.fromEntries(
      [...new Set(recoveryRequests.map(record => String(record.status ?? record.error)))].sort().map(status => [
        status,
        recoveryRequests.filter(record => String(record.status ?? record.error) === status).length,
      ]),
    ),
    requests: recoveryRequests,
  };

  const failures = [];
  if (success.maximumConcurrency > MAX_CONCURRENCY) failures.push('success-concurrency-exceeded');
  if (success.maximumStartsInRollingMinute > SUCCESS_START_LIMIT) failures.push('success-start-rate-exceeded');
  if (success.requests.some(record => record.status !== 200)) failures.push('success-cohort-not-all-200');
  if (success.requests.some(record => record.durationMs >= APPLICATION_TIMEOUT_MS)) failures.push('success-history-reached-application-timeout');
  if (rateLimit.maximumConcurrency > MAX_CONCURRENCY) failures.push('rate-limit-concurrency-exceeded');
  if (rateLimit.requests.some(record => ![200, 429].includes(record.status))) failures.push('rate-limit-unexpected-status');
  const firstRate429 = rateLimit.requests.findIndex(record => record.status === 429);
  if (firstRate429 < 1 || !rateLimit.requests.slice(0, firstRate429).some(record => record.status === 200)) {
    failures.push('approximate-429-transition-not-observed');
  }
  if (!recovery.requests.some(record => record.status === 200)) failures.push('normal-history-service-did-not-recover');

  return {
    schemaVersion: 1,
    evidenceClass: 'PUBLIC_AWS_REHEARSAL',
    runId: RUN_ID,
    publicApiBaseUrl: PUBLIC_API_BASE_URL,
    startedAt: rehearsalStartedAt,
    completedAt: new Date().toISOString(),
    configuredBounds: {
      maximumClientConcurrency: MAX_CONCURRENCY,
      successStartsPerRollingMinute: SUCCESS_START_LIMIT,
      wafRateEstimatePerMinute: SUCCESS_START_LIMIT,
      rateLimitPhaseMinimumStartIntervalMs: rateStartIntervalMs,
      applicationTimeoutMs: APPLICATION_TIMEOUT_MS,
    },
    targetCoverage: { organizations: 2, resourceTypes: 2, targets: targets.length },
    clearWaitMs,
    phases: { success, rateLimit, recovery },
    passed: failures.length === 0,
    failures,
    privacy: {
      storesCookies: false,
      storesTargetPathsOrRecordIds: false,
      storesCorrelationIds: false,
    },
  };
}

async function main() {
  if (!process.argv.includes('--confirm-public-rehearsal') || process.env.DEMO_RUN_ID !== RUN_ID) {
    throw new Error(`Refusing public traffic without --confirm-public-rehearsal and DEMO_RUN_ID=${RUN_ID}`);
  }
  if (process.env.DEMO_API_BASE_URL && process.env.DEMO_API_BASE_URL !== PUBLIC_API_BASE_URL) {
    throw new Error(`DEMO_API_BASE_URL must remain exactly ${PUBLIC_API_BASE_URL}`);
  }
  const fixturePath = process.env.DEMO_HISTORY_FIXTURE;
  if (!fixturePath) throw new Error('DEMO_HISTORY_FIXTURE must name the restricted local target fixture');
  const targets = validateTargets(JSON.parse(await readFile(resolve(fixturePath), 'utf8')));
  const evidencePath = resolve(process.env.DEMO_HISTORY_EVIDENCE || DEFAULT_EVIDENCE_PATH);
  const evidence = await runRehearsal({
    targets,
    successCount: integerSetting('DEMO_SUCCESS_REQUESTS', DEFAULT_SUCCESS_REQUESTS, 1, SUCCESS_START_LIMIT),
    rateCount: integerSetting('DEMO_RATE_REQUESTS', DEFAULT_RATE_REQUESTS, SUCCESS_START_LIMIT + 1, 600),
    concurrency: integerSetting('DEMO_HISTORY_CONCURRENCY', MAX_CONCURRENCY, 1, MAX_CONCURRENCY),
  });
  await mkdir(dirname(evidencePath), { recursive: true });
  await writeFile(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify({
    evidencePath,
    passed: evidence.passed,
    failures: evidence.failures,
    phaseStatusCounts: Object.fromEntries(
      Object.entries(evidence.phases).map(([name, phase]) => [name, phase.statusCounts]),
    ),
  }, null, 2));
  if (!evidence.passed) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
