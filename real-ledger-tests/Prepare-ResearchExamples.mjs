import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const output = resolve(dirname(fileURLToPath(import.meta.url)), '.generated/research-examples-manifest.json');

const sources = [
  {
    key: 'eeg-eye-state',
    organizationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    sourceUrl: 'https://archive.ics.uci.edu/dataset/264/eeg+eye+state',
    sourceDoi: '10.24432/C57G7J',
    artifacts: [
      {
        code: 'eeg-recording',
        title: 'EEG Eye State - original recording',
        filename: 'EEG Eye State.arff',
        url: 'https://archive.ics.uci.edu/ml/machine-learning-databases/00264/EEG%20Eye%20State.arff',
        sizeBytes: 1696428,
        sha256: 'e6eccba033d8ce56d38d2f0cca2087356705425a5a2ddbb1012ef3b892bd5a4b',
      },
    ],
  },
  {
    key: 'serengeti-reproduction',
    organizationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    sourceUrl: 'https://zenodo.org/records/4639695',
    sourceDoi: '10.5281/zenodo.4639695',
    artifacts: [
      {
        code: 'classifications',
        title: 'Snapshot Serengeti - volunteer and observer classifications',
        filename: 'volunteers_trainedObservers_sequenceClassification.csv',
        url: 'https://zenodo.org/api/records/4639695/files/volunteers_trainedObservers_sequenceClassification.csv/content',
        sizeBytes: 1490088,
        md5: '5e69c8ee038943e4ec30b4c739e8bf26',
        sha256: '7d2c4652dabcd4c2b177f16770827935e48fba0ac9067d713b678e597a28afac',
      },
      {
        code: 'readme',
        title: 'Snapshot Serengeti - study data dictionary',
        filename: 'README.txt',
        url: 'https://zenodo.org/api/records/4639695/files/README.txt/content',
        sizeBytes: 7716,
        md5: 'a701ee5f01e86b17397c0d0adcfe67c7',
        sha256: 'eadc49e1c806b1a38024d22f41a3144eaae59ea27588d7bb7667d1c71d7317ec',
      },
    ],
  },
];

async function verifiedHash(file) {
  const response = await fetch(file.url, {
    headers: { accept: '*/*', 'user-agent': 'curl/8.0' },
  });
  if (!response.ok || !response.body) {
    throw new Error(`Source unavailable: ${file.filename} (${response.status})`);
  }
  const sha256 = createHash('sha256');
  const md5 = createHash('md5');
  let sizeBytes = 0;
  for await (const chunk of response.body) {
    sizeBytes += chunk.length;
    if (sizeBytes > 50 * 1024 * 1024) throw new Error(`Source exceeds local limit: ${file.filename}`);
    sha256.update(chunk);
    md5.update(chunk);
  }
  const actual = { sizeBytes, sha256: sha256.digest('hex'), md5: md5.digest('hex') };
  if (actual.sizeBytes !== file.sizeBytes || actual.sha256 !== file.sha256 ||
      (file.md5 && actual.md5 !== file.md5)) {
    throw new Error(`Pinned source checksum or size changed: ${file.filename}`);
  }
  return { filename: file.filename, hash: actual.sha256, algorithm: 'sha256', sizeBytes };
}

async function verifyZenodoMetadata() {
  const response = await fetch('https://zenodo.org/api/records/4639695', {
    headers: { accept: 'application/json', 'user-agent': 'curl/8.0' },
  });
  if (!response.ok) throw new Error(`Zenodo metadata unavailable (${response.status})`);
  const record = await response.json();
  if (record.doi !== '10.5281/zenodo.4639695' || record.metadata?.license?.id !== 'cc-by-4.0') {
    throw new Error('Zenodo source identity or license differs from the reviewed record');
  }
  for (const file of sources[1].artifacts) {
    const published = record.files?.find((entry) => entry.key === file.filename);
    if (!published || published.size !== file.sizeBytes ||
        published.checksum !== `md5:${file.md5}`) {
      throw new Error(`Zenodo file metadata changed: ${file.filename}`);
    }
  }
}

await verifyZenodoMetadata();
const examples = [];
for (const source of sources) {
  const artifacts = [];
  for (const file of source.artifacts) {
    const entry = await verifiedHash(file);
    const footprint = createHash('sha256')
      .update(`${entry.filename}\t${entry.hash}`)
      .digest('hex');
    artifacts.push({
      code: file.code,
      title: file.title,
      footprint,
      manifest: [entry],
    });
  }
  examples.push({
    key: source.key,
    organizationId: source.organizationId,
    sourceUrl: source.sourceUrl,
    sourceDoi: source.sourceDoi,
    artifacts,
  });
}
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify({ examples }, null, 2) + '\n', { flag: 'wx' });
console.log(`Verified ${examples.length} published examples; hash-only manifest: ${output}`);
