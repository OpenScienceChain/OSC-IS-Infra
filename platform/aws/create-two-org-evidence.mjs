import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Presentation, PresentationFile } from '@oai/artifact-tool';

const { SKILL_DIR, TMP_DIR, FINAL_PPTX, RUNTIME_PYTHON, METRICS_JSON, LOAD_METRICS_JSON, PRIVACY_METRICS_JSON, RESOURCE_METRICS_JSON, ONBOARDING_METRICS_JSON } = process.env;
for (const [name, value] of Object.entries({ SKILL_DIR, TMP_DIR, FINAL_PPTX, RUNTIME_PYTHON, METRICS_JSON, LOAD_METRICS_JSON, PRIVACY_METRICS_JSON, RESOURCE_METRICS_JSON })) {
  if (!path.isAbsolute(value ?? '')) throw new Error(`${name} must be an absolute path`);
}
const { applyPresentationChartFont, finalizePresentation, resolvePresentationFont } = await import(
  pathToFileURL(path.join(SKILL_DIR, 'container_tools/artifact_tool_utils.mjs')).href,
);
const metrics = JSON.parse(await fs.readFile(METRICS_JSON, 'utf8'));
const load = JSON.parse(await fs.readFile(LOAD_METRICS_JSON, 'utf8'));
const privacy = JSON.parse(await fs.readFile(PRIVACY_METRICS_JSON, 'utf8'));
const resources = JSON.parse(await fs.readFile(RESOURCE_METRICS_JSON, 'utf8'));
const onboarding = ONBOARDING_METRICS_JSON ? JSON.parse(await fs.readFile(ONBOARDING_METRICS_JSON, 'utf8')) : null;
const font = resolvePresentationFont({ fontFamily: 'Arial' });
const presentation = Presentation.create({ slideSize: { width: 1280, height: 720 } });
const C = {
  ink: '#16324B', teal: '#167D80', blue: '#45749A', gold: '#B87821',
  gray: '#5D6B75', light: '#DCE5E9', white: '#FFFFFF',
};
const sourceLine = 'OSC-IS AWS run usrse260930  |  30 Sep 2026 UTC';

function addText(slide, value, left, top, width, height, size = 20, color = C.ink, bold = false) {
  const shape = slide.shapes.add({
    geometry: 'textbox', position: { left, top, width, height },
    fill: 'none', line: { fill: 'none', width: 0 },
  });
  shape.text = value;
  shape.text.style = {
    typeface: font, fontSize: size, color, bold, autoFit: 'none',
  };
  return shape;
}

function baseSlide(title, subtitle, page, notes) {
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addText(slide, title, 72, 42, 1136, 58, 36, C.ink, true);
  addText(slide, subtitle, 74, 106, 1120, 56, 19, C.gray);
  addText(slide, sourceLine, 74, 680, 900, 24, 13, C.gray);
  addText(slide, String(page).padStart(2, '0'), 1164, 679, 40, 24, 13, C.gray);
  slide.speakerNotes.textFrame.setText(notes);
  return slide;
}

function chart(slide, type, config) {
  const item = slide.charts.add(type, config);
  applyPresentationChartFont(item, { fontFamily: font });
  return item;
}
function seconds(ms) { return Math.round(ms / 10) / 100; }
function org(name) { return metrics.submissionTiming[name]; }
function note(slide, text, top = 586) { addText(slide, text, 75, top, 1130, 66, 18, C.ink); }

// 1. Scope and boundary
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addText(slide, onboarding ? 'AWS evidence: two to three organizations' : 'Two-organization AWS evidence', 74, 144, 1120, 78, 48, C.ink, true);
  addText(slide, 'Open Science Chain  |  US-RSE 2026', 76, 235, 1100, 42, 25, C.teal);
  addText(slide, '575 load submissions across Neuroscience Gateway and Citizen Science', 76, 345, 1080, 45, 26, C.ink);
  addText(slide, 'Added privacy and resource checks. One transaction-pointer discrepancy remains.', 76, 411, 1060, 62, 21, C.gray);
  addText(slide, sourceLine, 76, 679, 1100, 24, 13, C.gray);
  slide.speakerNotes.textFrame.setText(`Sources: ${METRICS_JSON}; ${LOAD_METRICS_JSON}${onboarding ? `; ${ONBOARDING_METRICS_JSON}` : ''}. The opening section describes the two-organization AWS baseline and bounded synthetic load.${onboarding ? ' Slides 20-24 document the real third Fabric peer onboarding.' : ' No third Fabric peer organization has been deployed.'} One of 90 fault-run API transaction pointers did not match Fabric history; see the integrity slide.`);
}

// 2. One public artifact per org shows the observable provenance path.
{
  const slide = baseSlide(
    'Submission to visible provenance',
    'Elapsed since POST start, one public artifact probe per organization', 2,
    `Source: ${METRICS_JSON}, submissionTiming.*.publicArtifact. Client-observed cumulative time. Poll interval 1 second, so ledger, history and catalog timestamps can be late by approximately one second. API acceptance is not ledger confirmation.`,
  );
  const stages = ['API accepted', 'Ledger confirmed', 'History readable', 'Catalog visible'];
  const stageValues = name => {
    const value = org(name).publicArtifact;
    return [value.acceptedMs, value.confirmedMs, value.historyMs, value.catalogMs].map(seconds);
  };
  chart(slide, 'line', {
    position: { left: 104, top: 190, width: 1070, height: 370 }, categories: stages,
    series: [
      { name: 'NSG', values: stageValues('NSG'), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 8 } },
      { name: 'Citizen Science', values: stageValues('Citizen Science'), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 8 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Seconds', min: 0, max: 2.8, majorUnit: 0.5, numberFormatCode: '0.0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'The API accepted both requests in 60 ms. Ledger, history and catalog checks succeeded by about 2.4 seconds.');
}

// 3. Ordered observed runs expose the cold first-run outlier.
{
  const slide = baseSlide(
    'Sequential artifact confirmation',
    'Eight private artifact probes per organization, in submission order', 3,
    `Source: ${METRICS_JSON}, submissionTiming.*.artifactSequential.confirmed.valuesMs. Each run awaited confirmation before the next started. One-second status polling limits timing resolution; this is a bounded demo probe, not a throughput benchmark.`,
  );
  chart(slide, 'line', {
    position: { left: 105, top: 182, width: 1065, height: 390 },
    categories: Array.from({ length: 8 }, (_, index) => String(index + 1)),
    series: [
      { name: 'NSG', values: org('NSG').artifactSequential.confirmed.valuesMs.map(seconds), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 8 } },
      { name: 'Citizen Science', values: org('Citizen Science').artifactSequential.confirmed.valuesMs.map(seconds), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 8 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Observed seconds', min: 0, max: 3.6, majorUnit: 0.5, numberFormatCode: '0.0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Probe number', textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'All 16 confirmed. NSG’s first probe took 3.32 seconds; later observations clustered near 2.2 seconds.');
}

// 4. Access control is more informative as an exact matrix than a percentage chart.
{
  const slide = baseSlide(
    'Organization boundaries',
    'Ten access checks against private, confirmed records', 4,
    `Source: ${METRICS_JSON}, isolation.checksByLabel and postRecoveryPostman. The matrix covers API authorization in this run. Direct Fabric identity denial was validated in the earlier AWS stack summary, not retested in these ten checks.`,
  );
  const rows = [
    ['Own private artifact reads', '2 of 2 returned HTTP 200'],
    ['Cross-org private artifact reads', '2 of 2 returned HTTP 403'],
    ['Cross-org artifact update and history', '2 of 2 returned HTTP 403'],
    ['Own private workflow reads', '2 of 2 returned HTTP 200'],
    ['Cross-org workflow read and update', '2 of 2 returned HTTP 403'],
  ];
  rows.forEach(([label, result], index) => {
    const top = 184 + index * 67;
    addText(slide, label, 95, top, 650, 48, 22, C.ink);
    addText(slide, result, 785, top, 390, 48, 22, C.teal, true);
  });
  note(slide, 'Post-recovery Postman smoke also passed: six requests, zero failed assertions.', 559);
}

// 5. Two controlled disruption cycles, with peer failover named separately.
{
  const slide = baseSlide(
    'Controlled dependency recovery',
    'Elapsed through disruption and confirmed probe, seconds; two cycles per scenario', 5,
    `Source: ${METRICS_JSON}, recovery. The clock starts before the disruption command and ends after a new probe succeeds. Gateway and RabbitMQ are recovery scenarios. Peer values measure alternate-peer transaction acceptance while peer1 is down, not peer1 recovery. Each probe had one ledger revision and no duplicate write observed. Small n; not an SLA.`,
  );
  chart(slide, 'bar', {
    position: { left: 125, top: 190, width: 1030, height: 330 },
    categories: ['Ledger gateway', 'RabbitMQ / outbox'],
    series: [
      { name: 'First cycle', values: [50, 225], fill: C.teal },
      { name: 'Repeat', values: [72, 222], fill: C.gold },
    ],
    barOptions: { direction: 'bar', grouping: 'clustered', gapWidth: 85 },
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    xAxis: { title: 'Seconds', min: 0, max: 250, majorUnit: 50, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    yAxis: { textStyle: { fill: C.ink, fontSize: 17 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 16 } },
  });
  note(slide, 'With one NSG peer down, the alternate path accepted a transaction in 8 and 5 seconds. Each probe had one ledger revision.', 551);
}

// 6. Four drift observations make the long reconciliation visible.
{
  const slide = baseSlide(
    'GitOps drift correction',
    'Seconds from deliberate API replica drift to Argo Synced/Healthy', 6,
    `Source: ${METRICS_JSON}, gitops.secondsToSyncedHealthy. The API deployment was reduced from two replicas to one. Argo self-heal restored the declared two replicas at the same Git revision. Four individual observations; 133 seconds is real, not discarded. This is not a reconciliation SLA.`,
  );
  chart(slide, 'bar', {
    position: { left: 130, top: 185, width: 1010, height: 375 },
    categories: ['Earlier run', 'Repeat 1', 'Repeat 2', 'Repeat 3'],
    series: [{ name: 'Seconds', values: metrics.gitops.secondsToSyncedHealthy, fill: C.teal }],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 92 }, hasLegend: false,
    yAxis: { title: 'Seconds', min: 0, max: 150, majorUnit: 30, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { textStyle: { fill: C.ink, fontSize: 16 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 16 } },
  });
  note(slide, 'All four self-healed. The 133-second observation shows why one fast screenshot should not be presented as a guarantee.');
}

// 7. Operational baseline for a later third-org delta.
{
  const slide = baseSlide(
    'Two-org footprint',
    'Ready pods by namespace, after restoration', 7,
    `Source: ${METRICS_JSON}, footprint; and platform/aws/estimate_cost.py. Three m7i.large nodes in three availability zones and 71/71 ready pods. Node mean five-minute CPU was 3.7-4.0 percent in the sampled preceding hour. The USD 0.9425/hour figure is a planning estimate, not billed cost. Kubernetes Metrics API unavailable, so memory usage is not claimed. This is the baseline to compare with a true third-org onboarding.`,
  );
  const namespaces = Object.entries(metrics.footprint.podCountsByNamespace)
    .sort((a, b) => b[1].total - a[1].total);
  chart(slide, 'bar', {
    position: { left: 155, top: 178, width: 980, height: 390 },
    categories: namespaces.map(([name]) => name),
    series: [{ name: 'Ready pods', values: namespaces.map(([, count]) => count.ready), fill: C.teal }],
    barOptions: { direction: 'bar', grouping: 'clustered', gapWidth: 30 }, hasLegend: false,
    xAxis: { title: 'Pods', min: 0, max: 25, majorUnit: 5, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    yAxis: { textStyle: { fill: C.ink, fontSize: 14 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'Three worker nodes across three zones; 71 of 71 pods ready. Estimated run rate: $0.94/hour, before actual billing.', 578);
}

// 8. API acceptance is deliberately separated from the Fabric record timestamp.
{
  const slide = baseSlide(
    'Offered, accepted, and recorded',
    'Per-second rate during five 5-second load stages; both organizations combined', 8,
    `Source: ${LOAD_METRICS_JSON}, normal.stageThroughput. The Fabric series counts transaction timestamps on records later verified as committed; it is NOT a live finality timestamp or confirmed TPS. All 330 normal-run writes eventually reached API SUCCESS and readable Fabric history.`,
  );
  const stages = load.normal.stageThroughput;
  chart(slide, 'bar', {
    position: { left: 115, top: 185, width: 1050, height: 365 },
    categories: stages.map(item => String(item.offeredRate)),
    series: [
      { name: 'Offered', values: stages.map(item => item.offeredPerSecond), fill: C.blue },
      { name: 'API accepted', values: stages.map(item => item.acceptedPerSecond), fill: C.teal },
      { name: 'Fabric record time', values: stages.map(item => item.fabricRecordTimestampsPerSecond), fill: C.gold },
    ],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 68 },
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 16 } },
    yAxis: { title: 'Records / second', min: 0, max: 32, majorUnit: 5, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Offered submissions / second', textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'At 30/s, the API accepted 30/s; record timestamps averaged 2.4/s in that stage. This is not sustained ledger throughput.');
}

// 9. The timing run samples first observed API confirmation, rather than proposal time.
{
  const slide = baseSlide(
    'Confirmation slows under load',
    'First observed API SUCCESS with transaction ID; 45 sampled submissions', 9,
    `Source: ${LOAD_METRICS_JSON}, timing.stageObservedConfirmationLatency. Five samples at 1/s and ten at each other offered rate; one-second polling. Rates were staged briefly. These are observed request-to-status times, not precise Fabric block commit durations.`,
  );
  const stages = load.timing.stageObservedConfirmationLatency;
  chart(slide, 'line', {
    position: { left: 110, top: 182, width: 1060, height: 380 },
    categories: stages.map(item => String(item.rate)),
    series: [
      { name: 'Median', values: stages.map(item => seconds(item.medianMs)), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 8 } },
      { name: 'P95', values: stages.map(item => seconds(item.p95Ms)), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 8 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Observed seconds', min: 0, max: 50, majorUnit: 10, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Offered submissions / second', textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'P95 rose from 3.1s at 1/s to 45.4s at 30/s. The 30/s stage has only ten sampled records.');
}

// 10. Show the queueing consequence and eventual catch-up in the same figure.
{
  const slide = baseSlide(
    'Time to clear the backlog',
    'Accepted minus Fabric record timestamps, selected timeline samples', 10,
    `Source: ${LOAD_METRICS_JSON}, normal.timelineFiveSeconds. This difference is a proxy for work without a Fabric transaction timestamp, not RabbitMQ queue depth or exact unconfirmed count. Last POST was about 25 seconds after start. All 330 API records were first observed SUCCESS ${load.normal.observedDrainSeconds} seconds after the last POST.`,
  );
  const points = load.normal.timelineFiveSeconds.filter(item => item.second % 15 === 0 || item.second === 25 || item.second === 185);
  chart(slide, 'line', {
    position: { left: 110, top: 184, width: 1050, height: 375 },
    categories: points.map(item => String(item.second)),
    series: [{ name: 'Unrecorded proxy', values: points.map(item => item.unrecordedAtTransactionTime), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 6 } }],
    hasLegend: false,
    yAxis: { title: 'Records', min: 0, max: 300, majorUnit: 50, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Seconds since first POST', textStyle: { fill: C.ink, fontSize: 14 } },
  });
  note(slide, `Peak proxy: ${load.normal.peakUnrecordedAtTransactionTime}. All API records were observed SUCCESS ${load.normal.observedDrainSeconds}s after the last POST.`);
}

// 11. Exact 403 counts make the security boundary auditable.
{
  const slide = baseSlide(
    'Cross-org isolation under load',
    'Forbidden cross-organization checks during the normal staged run', 11,
    `Source: ${LOAD_METRICS_JSON}, normal.crossOrgByRate, timing.counts, fault.counts. These checks used authenticated API requests to private records owned by the other organization. All 25 normal, 16 timing, and 30 fault-run checks returned HTTP 403. This does not constitute a full direct-Fabric penetration test.`,
  );
  const stages = load.normal.crossOrgByRate;
  chart(slide, 'bar', {
    position: { left: 125, top: 188, width: 1020, height: 355 },
    categories: stages.map(item => String(item.rate)),
    series: [{ name: 'HTTP 403', values: stages.map(item => item.forbidden), fill: C.teal }],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 115 }, hasLegend: false,
    yAxis: { title: 'Denied checks', min: 0, max: 6, majorUnit: 1, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Offered submissions / second', textStyle: { fill: C.ink, fontSize: 15 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 16 } },
  });
  note(slide, 'Normal: 25/25 denied. Timing: 16/16 denied. Gateway interruption: 30/30 denied.');
}

// 12. The small pointer mismatch is the crucial finding, not chart noise.
{
  const slide = baseSlide(
    'Hash integrity and pointer check',
    'Share of records matching the Fabric history result in each load run', 12,
    `Source: ${LOAD_METRICS_JSON}, run.integrity and counts. API and Fabric SHA-256 matched for all 575 writes; each had one history revision. In the gateway fault run, one of 90 API blockchainTxId values differed from the Fabric history transactionId. The chaincode idempotency receipt path is a plausible, not runtime-proven, cause.`,
  );
  const runs = [load.normal, load.fault, load.timing];
  const pct = (run, key) => Math.round(1000 * (run.integrity?.[key] ?? (key === 'ledgerTxPointerMatched' ? run.counts.ledgerTransactionsMatched : run.counts.confirmed)) / run.counts.confirmed) / 10;
  chart(slide, 'bar', {
    position: { left: 115, top: 182, width: 1050, height: 375 },
    categories: ['Normal (330)', 'Gateway fault (90)', 'Timing (155)'],
    series: [
      { name: 'API SHA-256', values: runs.map(run => pct(run, 'apiHashMatched')), fill: C.teal },
      { name: 'Fabric SHA-256', values: runs.map(run => pct(run, 'ledgerHashMatched')), fill: C.blue },
      { name: 'API tx pointer', values: runs.map(run => pct(run, 'ledgerTxPointerMatched')), fill: C.gold },
    ],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 72 },
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 16 } },
    yAxis: { title: 'Percent matching', min: 95, max: 100, majorUnit: 1, numberFormatCode: '0.0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'Hashes: 575/575 matched; one revision each. Fault-run tx pointer: 89/90 matched. This needs a fix.');
}

// 13. Preserve the controlled interruption as a distinct, bounded observation.
{
  const slide = baseSlide(
    'Gateway interruption during submissions',
    'Cumulative accepted and Fabric record timestamps, 3 offered writes/s', 13,
    `Source: ${LOAD_METRICS_JSON}, fault.timelineTwoSeconds and gateway scale events. NSG gateway scale-down at +7.5s and scale-up at +18.5s from run start; these are kubectl event times, not exact outage duration. All 90 writes later confirmed and had matching hashes and one history revision. One API transaction pointer differed from Fabric history.`,
  );
  const points = load.fault.timelineTwoSeconds.filter(item => item.second % 4 === 0);
  chart(slide, 'line', {
    position: { left: 108, top: 182, width: 1065, height: 370 },
    categories: points.map(item => String(item.second)),
    series: [
      { name: 'API accepted', values: points.map(item => item.accepted), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 6 } },
      { name: 'Fabric record time', values: points.map(item => item.recordedTransactionTime), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 6 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Cumulative records', min: 0, max: 100, majorUnit: 20, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Seconds since first POST', textStyle: { fill: C.ink, fontSize: 14 } },
  });
  note(slide, 'Gateway scale-down +7.5s; scale-up +18.5s. 90/90 confirmed, but one API tx pointer differed from history.');
}

// 14. An exact sampled API-state count complements the transaction-timestamp proxy.
{
  const slide = baseSlide(
    'Pending sampled records',
    'Accepted minus first-observed SUCCESS among 45 live-polled timing records', 14,
    `Source: ${LOAD_METRICS_JSON}, timing.sampledPendingTimeline. A 2-second time grid and 1-second polling introduce observation delay. This is a 45-record sample, not the entire 155-write run or broker queue depth.`,
  );
  const points = load.timing.sampledPendingTimeline.filter(item => item.second % 6 === 0 || item.second === load.timing.sampledPendingTimeline.at(-1).second);
  chart(slide, 'line', {
    position: { left: 110, top: 184, width: 1050, height: 375 },
    categories: points.map(item => String(item.second)),
    series: [
      { name: 'Accepted sample', values: points.map(item => item.sampledAccepted), line: { style: 'solid', fill: C.blue, width: 3 }, marker: { symbol: 'circle', size: 6 } },
      { name: 'Still pending', values: points.map(item => item.sampledPending), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 6 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Sampled records', min: 0, max: 50, majorUnit: 10, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Seconds since first POST', textStyle: { fill: C.ink, fontSize: 14 } },
  });
  note(slide, `The sampled pending count peaked at ${Math.max(...load.timing.sampledPendingTimeline.map(item => item.sampledPending))}; all 45 were later observed SUCCESS.`);
}

// 15. The small per-org sample must be visible in the caption, not hidden by a smooth trend.
{
  const slide = baseSlide(
    'Latency by organization',
    'Median first-observed SUCCESS time; 2-5 sampled writes per org and rate', 15,
    `Source: ${LOAD_METRICS_JSON}, timing.latencyByOrgAndRate. The groups have only two to five observations; different stage ordering and polling may explain differences. Exploratory comparison, not a fairness benchmark.`,
  );
  const rates = [...new Set(load.timing.latencyByOrgAndRate.map(item => item.rate))];
  const values = name => rates.map(rate => seconds(load.timing.latencyByOrgAndRate.find(item => item.organization === name && item.rate === rate).medianMs));
  chart(slide, 'line', {
    position: { left: 110, top: 184, width: 1050, height: 375 },
    categories: rates.map(String),
    series: [
      { name: 'NSG', values: values('NSG'), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 8 } },
      { name: 'Citizen Science', values: values('Citizen Science'), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'square', size: 8 } },
    ],
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Observed seconds', min: 0, max: 50, majorUnit: 10, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { title: 'Offered submissions / second', textStyle: { fill: C.ink, fontSize: 15 } },
  });
  note(slide, 'Both orgs remained active at every stage. This small sample cannot establish an org-level performance difference.');
}

// 16. Retry safety is a count, not a percentage that would obscure one duplicate.
{
  const slide = baseSlide(
    'No duplicate ledger revisions observed',
    'New artifact history entries across three bounded runs', 16,
    `Source: ${LOAD_METRICS_JSON}, revisionsByRun. Each of 575 newly created records had exactly one Fabric history item when read after the run. This does not prove exactly-once processing for all failure modes.`,
  );
  const runs = load.revisionsByRun;
  chart(slide, 'bar', {
    position: { left: 125, top: 188, width: 1020, height: 355 },
    categories: runs.map(item => item.mode),
    series: [
      { name: 'One revision', values: runs.map(item => item.singleRevision), fill: C.teal },
      { name: 'More than one', values: runs.map(item => item.multipleRevisions), fill: C.gold },
    ],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 95 },
    hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 17 } },
    yAxis: { title: 'Artifacts', min: 0, max: 350, majorUnit: 50, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { textStyle: { fill: C.ink, fontSize: 16 } },
  });
  note(slide, '575 of 575 had one ledger history revision. No duplicate revision was seen, including the gateway fault run.');
}

// 17. The selected files are local fixtures; the actual outbound JSON is intercepted.
{
  const slide = baseSlide(
    'File bytes stay in the browser',
    'Actual intercepted request size after selecting synthetic local files', 17,
    `Source: ${PRIVACY_METRICS_JSON}; OSC-WebApp/e2e/upload-privacy-evidence.spec.ts. The portal selected 1 KiB, 1 MiB, 10 MiB and 40 MiB synthetic files. Playwright intercepted the JSON POST; API was mocked. Neither filename nor file content appeared in the request. This does not measure a real backend upload.`,
  );
  const observations = privacy.observations;
  chart(slide, 'bar', {
    position: { left: 135, top: 188, width: 1000, height: 360 },
    categories: ['1 KiB file', '1 MiB file', '10 MiB file', '40 MiB file'],
    series: [{ name: 'POST JSON bytes', values: observations.map(item => item.requestBytes), fill: C.teal }],
    barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 100 }, hasLegend: false,
    yAxis: { title: 'Request bytes', min: 0, max: 500, majorUnit: 100, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 15 } },
    xAxis: { textStyle: { fill: C.ink, fontSize: 15 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 16 } },
  });
  note(slide, 'POST stayed at 450-454 bytes; no selected file bytes or original filename appeared in it. Local browser test.');
}

// 18-19. CPU and memory use separate units and separate charts.
for (const [page, title, key, unit, max, major] of [
  [18, 'CPU by service', 'meanCpuMilliCores', 'Mean millicores', 100, 20],
  [19, 'Memory by service', 'meanWorkingSetMiB', 'Mean working-set MiB', 650, 100],
]) {
  const slide = baseSlide(
    title,
    'Twelve read-only kubelet snapshots during an additional 330-write staged run', page,
    `Source: ${RESOURCE_METRICS_JSON}; capture-service-resources.ps1. Per-sample pod values were summed by logical service, then averaged over 12 snapshots. ${key} is an observed usage metric, not Kubernetes resource requests or a sustained capacity claim. The transient load Job is excluded.`,
  );
  const selected = resources.byService.filter(item => !['Fabric CAs', 'Chaincode'].includes(item.service)).sort((a, b) => b[key] - a[key]);
  chart(slide, 'bar', {
    position: { left: 180, top: 177, width: 920, height: 410 },
    categories: selected.map(item => item.service),
    series: [{ name: unit, values: selected.map(item => item[key]), fill: C.teal }],
    barOptions: { direction: 'bar', grouping: 'clustered', gapWidth: 32 }, hasLegend: false,
    xAxis: { title: unit, min: 0, max, majorUnit: major, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
    yAxis: { textStyle: { fill: C.ink, fontSize: 14 } },
    dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 14 } },
  });
  note(slide, 'Observed usage during a bounded run; no Metrics Server or new collector was installed.', 602);
}

if (onboarding) {
  const minutes = secondsValue => Math.round(secondsValue / 6) / 10;
  const milestones = onboarding.events.filter(item => !['Kickoff snapshot', 'Argo Synced and Healthy observed'].includes(item.label));
  {
    const slide = baseSlide(
      'Adding a real third Fabric organization',
      'Observed elapsed time from first onboarding snapshot; manual work included', 20,
      `Source: ${ONBOARDING_METRICS_JSON}, events. UTC timestamps from operator milestones, 154 Kubernetes/Argo snapshots, and API confirmation probes. This is one operator-led run, not an automated provisioning benchmark. The first peer-join attempt failed because a config block was used; the corrected genesis-block join succeeded and its repair time is included.`,
    );
    chart(slide, 'bar', {
      position: { left: 205, top: 175, width: 875, height: 405 },
      categories: milestones.map(item => item.label.replace('Fabric ', '').replace(' observed', '').replace('Third app services', 'App services').replace('First third-org ', 'First ')),
      series: [{ name: 'Elapsed minutes', values: milestones.map(item => minutes(item.elapsedSec)), fill: C.teal }],
      barOptions: { direction: 'bar', grouping: 'clustered', gapWidth: 35 }, hasLegend: false,
      xAxis: { title: 'Minutes', min: 0, max: 30, majorUnit: 5, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
      yAxis: { textStyle: { fill: C.ink, fontSize: 14 } },
      dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 13 } },
    });
    note(slide, 'First confirmed workflow at 28.8 minutes. This includes operator checks and a corrected peer-join step.', 604);
  }
  {
    const slide = baseSlide(
      'Pods ready, then GitOps converged',
      'Third-organization pods observed by Kubernetes, sampled about every 10-14 seconds', 21,
      `Source: ${ONBOARDING_METRICS_JSON}, readiness and gitops. Each plotted point is the first sample in a two-minute bucket; readiness is first observed, not the exact state-transition time. Fabric is CA, peer and chaincode; application is ledger gateway and history worker. Argo is 1 only when Synced and Healthy at revision ${onboarding.gitops.revision}.`,
    );
    const points = onboarding.readiness.filter((_, index) => index % 2 === 0 || index === onboarding.readiness.length - 1);
    chart(slide, 'line', {
      position: { left: 102, top: 186, width: 1070, height: 385 },
      categories: points.map(item => String(minutes(item.elapsedSec))),
      series: [
        { name: 'Fabric ready / 3', values: points.map(item => item.fabricReady), line: { style: 'solid', fill: C.teal, width: 3 }, marker: { symbol: 'circle', size: 6 } },
        { name: 'App ready / 2', values: points.map(item => item.appReady), line: { style: 'solid', fill: C.blue, width: 3 }, marker: { symbol: 'square', size: 6 } },
        { name: 'Argo healthy / 1', values: points.map(item => item.argoReady), line: { style: 'solid', fill: C.gold, width: 3 }, marker: { symbol: 'diamond', size: 6 } },
      ],
      hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 15 } },
      yAxis: { title: 'Ready components', min: 0, max: 3.2, majorUnit: 1, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
      xAxis: { title: 'Minutes since first snapshot', textStyle: { fill: C.ink, fontSize: 12 } },
    });
    note(slide, 'Argo reached Synced/Healthy on the reviewed revision; all five third-org pods were ready.', 601);
  }
  {
    const slide = baseSlide(
      'The first third-org artifact was traceable',
      'Client-observed elapsed time from POST start for one public synthetic artifact', 22,
      `Source: ${ONBOARDING_METRICS_JSON}, firstProvenance. Cumulative client timing; 1-second state/history polling can observe confirmation late. The artifact was written through the MagneticArchMSP gateway/peer, had a Fabric transaction ID and one readable history revision, and appeared in the public catalog. The linked private workflow confirmed in ${seconds(onboarding.firstProvenance.workflow.confirmedMs)} seconds. No research bytes were uploaded.`,
    );
    const a = onboarding.firstProvenance.artifact;
    chart(slide, 'bar', {
      position: { left: 150, top: 188, width: 995, height: 365 },
      categories: ['API accepted', 'Ledger confirmed', 'History readable', 'Catalog visible'],
      series: [{ name: 'Seconds', values: [a.acceptedMs, a.confirmedMs, a.historyMs, a.catalogMs].map(seconds), fill: C.teal }],
      barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 80 }, hasLegend: false,
      yAxis: { title: 'Seconds', min: 0, max: 4.2, majorUnit: 1, numberFormatCode: '0.0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
      xAxis: { textStyle: { fill: C.ink, fontSize: 14 } },
      dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 14 } },
    });
    note(slide, 'Workflow confirmed in 2.25 seconds. Pod readiness alone would not prove this provenance path.');
  }
  {
    const slide = baseSlide(
      'The original organizations still worked',
      'One post-onboarding synthetic artifact per organization; all had readable history', 23,
      `Source: ${ONBOARDING_METRICS_JSON}, continuity. One artifact per organization after onboarding, sequentially submitted, 1-second state polling. All three confirmed and had one history item. Nine ownership/denial checks passed, including cross-org reads and updates. This is a functional smoke test, not comparative performance evidence or continuous availability during the entire addition.`,
    );
    chart(slide, 'bar', {
      position: { left: 157, top: 185, width: 965, height: 370 },
      categories: onboarding.continuity.artifacts.map(item => item.organization),
      series: [{ name: 'Confirmation seconds', values: onboarding.continuity.artifacts.map(item => seconds(item.confirmedMs)), fill: C.teal }],
      barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 90 }, hasLegend: false,
      yAxis: { title: 'Seconds', min: 0, max: 4, majorUnit: 1, numberFormatCode: '0.0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
      xAxis: { textStyle: { fill: C.ink, fontSize: 15 } },
      dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 14 } },
    });
    note(slide, 'Three confirmed artifacts; 3/3 histories readable; 9/9 ownership checks passed.');
  }
  {
    const slide = baseSlide(
      'Five more pods, no fourth node',
      'Ready Kubernetes pods before and after third-org onboarding', 24,
      `Source: ${ONBOARDING_METRICS_JSON}, footprint. Before snapshot ${onboarding.footprint.before.capturedAt}; after snapshot ${onboarding.footprint.after.capturedAt}. Both had three ready m7i.large nodes and all pods ready. The three Fabric-side pods and two app services were placed on existing nodes. This is pod-count footprint, not a measured cloud-cost delta; shared-host placement weakens failure isolation.`,
    );
    const before = onboarding.footprint.before;
    const after = onboarding.footprint.after;
    chart(slide, 'bar', {
      position: { left: 152, top: 185, width: 977, height: 377 },
      categories: ['Fabric', 'Application', 'Other'],
      series: [
        { name: 'Before', values: [before.fabricPods, before.appPods, before.pods - before.fabricPods - before.appPods], fill: C.blue },
        { name: 'After', values: [after.fabricPods, after.appPods, after.pods - after.fabricPods - after.appPods], fill: C.teal },
      ],
      barOptions: { direction: 'column', grouping: 'clustered', gapWidth: 80 },
      hasLegend: true, legend: { position: 'top', overlay: false, textStyle: { fill: C.ink, fontSize: 16 } },
      yAxis: { title: 'Ready pods', min: 0, max: 40, majorUnit: 10, numberFormatCode: '0', majorGridlines: { style: 'solid', fill: C.light, width: 1 }, textStyle: { fill: C.gray, fontSize: 14 } },
      xAxis: { textStyle: { fill: C.ink, fontSize: 15 } },
      dataLabels: { showValue: true, position: 'outEnd', textStyle: { fill: C.ink, fontSize: 14 } },
    });
    note(slide, '71 to 76 ready pods; EKS nodes stayed at three. This is not a zero-cost addition.');
  }
}

await fs.mkdir(TMP_DIR, { recursive: true });
await fs.mkdir(path.dirname(FINAL_PPTX), { recursive: true });
const candidatePath = path.join(TMP_DIR, 'candidate.pptx');
await (await PresentationFile.exportPptx(presentation)).save(candidatePath);
const result = await finalizePresentation({
  workspaceDir: process.env.WORKSPACE_DIR || path.dirname(TMP_DIR), candidatePath, finalPath: FINAL_PPTX,
  pythonExecutable: RUNTIME_PYTHON,
  integrityValidatorPath: path.join(SKILL_DIR, 'container_tools/inspect_presentation_package_integrity.py'),
  layoutValidatorPath: path.join(SKILL_DIR, 'container_tools/inspect_presentation_layout_geometry.py'),
  layoutArgs: ['--expected-slide-size-emu', '12192000,6858000', '--validate-heading-fit'],
  requiredNativeChartOwnerSlides: [2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, ...(onboarding ? [20, 21, 22, 23, 24] : [])],
  materializeLiteralChartWorkbooks: true,
  fontPolicy: { basis: 'design', families: [font] },
  verifyArtifactToolImport: true,
  receiptPath: path.join(TMP_DIR, 'validation.json'),
});
console.log(JSON.stringify({ finalized: FINAL_PPTX, result }, null, 2));
