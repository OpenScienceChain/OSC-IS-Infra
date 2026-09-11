import assert from 'node:assert/strict';
import test from 'node:test';

import {
  IntervalStartPacer,
  MAX_CONCURRENCY,
  RollingStartLimiter,
  maximumRollingStarts,
  runPool,
  runRehearsal,
} from '../../platform/aws/public-history-rehearsal.mjs';

test('rolling limiter never admits more than 300 starts in 60 seconds', async () => {
  let clock = 0;
  const limiter = new RollingStartLimiter({
    now: () => clock,
    wait: async milliseconds => { clock += milliseconds; },
  });
  const starts = [];
  for (let index = 0; index < 301; index += 1) starts.push(await limiter.acquire());
  assert.equal(starts[300], 60_000);
  assert.equal(maximumRollingStarts(starts.map(startedEpochMs => ({ startedEpochMs }))), 300);
});

test('worker pool enforces the 100-client concurrency ceiling', async () => {
  let active = 0;
  let observed = 0;
  const result = await runPool(250, MAX_CONCURRENCY, async index => {
    active += 1;
    observed = Math.max(observed, active);
    await new Promise(resolveImmediate => setImmediate(resolveImmediate));
    active -= 1;
    return index;
  });
  assert.equal(result.results.length, 250);
  assert.equal(result.maximumConcurrency, MAX_CONCURRENCY);
  assert.equal(observed, MAX_CONCURRENCY);
});

test('rate-limit phase pacer reserves starts no faster than ten per second', async () => {
  let clock = 0;
  const pacer = new IntervalStartPacer({
    now: () => clock,
    wait: async milliseconds => { clock += milliseconds; },
  });
  const starts = [];
  for (let index = 0; index < 4; index += 1) starts.push(await pacer.acquire());
  assert.deepEqual(starts, [0, 100, 200, 300]);
});

test('rehearsal separates success, approximate 429 transition, and recovery without identifiers', async () => {
  let clock = Date.parse('2026-09-11T19:00:00Z');
  let recoveryAttempt = 0;
  const cookie = '__Host-osc_demo=sensitive-signed-session';
  const identifiers = [
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
  ];
  const targets = [
    { organization: 'neuroscience-gateway', path: `/demo/artifacts/${identifiers[0]}/history`, cookie },
    { organization: 'neuroscience-gateway', path: `/demo/workflows/${identifiers[1]}/history`, cookie },
    { organization: 'citizen-science', path: `/demo/artifacts/${identifiers[2]}/history`, cookie },
    { organization: 'citizen-science', path: `/demo/workflows/${identifiers[3]}/history`, cookie },
  ];
  const evidence = await runRehearsal({
    targets,
    successCount: 12,
    rateCount: 305,
    concurrency: MAX_CONCURRENCY,
    clearWaitMs: 60_001,
    recoveryIntervalMs: 1,
    recoveryAttempts: 3,
    now: () => clock,
    wait: async milliseconds => { clock += milliseconds; },
    request: async (phase, index) => {
      const startedEpochMs = clock;
      clock += 1;
      let status = 200;
      if (phase === 'read-only-rate-limit' && index >= 300) status = 429;
      if (phase === 'recovery') {
        status = recoveryAttempt === 0 ? 429 : 200;
        recoveryAttempt += 1;
      }
      return {
        startedEpochMs,
        startedAt: new Date(startedEpochMs).toISOString(),
        durationMs: 1,
        status,
        error: null,
      };
    },
  });
  assert.equal(evidence.passed, true, evidence.failures.join(', '));
  assert.equal(evidence.phases.success.requested, 12);
  assert.equal(evidence.phases.success.maximumConcurrency <= MAX_CONCURRENCY, true);
  assert.equal(evidence.phases.rateLimit.statusCounts['429'], 5);
  assert.deepEqual(evidence.phases.recovery.statusCounts, { '200': 1, '429': 1 });
  const serialized = JSON.stringify(evidence);
  assert.equal(serialized.includes(cookie), false);
  for (const identifier of identifiers) assert.equal(serialized.includes(identifier), false);
});
