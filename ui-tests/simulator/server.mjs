import http from 'node:http';

const port = Number(process.env.PORT ?? 3100);

const organizations = [
  {
    id: 'org-nsg',
    code: 'NSG',
    name: 'Neuroscience Gateway',
  },
  {
    id: 'org-citizen-science',
    code: 'CS',
    name: 'Citizen Science',
  },
];

const artifacts = [
  {
    id: 'artifact-nsg-001',
    title: 'Neuroscience image segmentation dataset',
    description:
      'Curated imaging data and metadata used to validate a reproducible segmentation workflow.',
    keywords: ['neuroscience', 'imaging', 'segmentation'],
    links: ['https://www.nsgportal.org/'],
    dois: [],
    fundingAgencies: ['National Science Foundation'],
    acknowledgements:
      'Prepared by the Neuroscience Gateway community for reproducibility testing.',
    submission_comment:
      'Initial release with the image manifest and segmentation reference labels.',
    footprint:
      'b731d8f7cc8d9463a5ab13c6bbef70f5103e398ad001aaf52c91a2fb94d6397e',
    manifest: [
      {
        filename: 'images/sub-001_T1w.nii.gz',
        hash: '73ebfe3d589e0ae1ad76e76f83c4f55d2c8d3ad4b94df4ad71ab30a73d134aba',
        algorithm: 'sha256',
      },
      {
        filename: 'labels/sub-001_segmentation.nii.gz',
        hash: '68f7cf5cb132cdd9208105799ee85c0d9d077256a103dec0439615e321635cf5',
        algorithm: 'sha256',
      },
      {
        filename: 'dataset_description.json',
        hash: 'f32b925cf835fd2606575a746dad693e3b1b06be81b74135ab9c8027218d63e7',
        algorithm: 'sha256',
      },
    ],
    submittedAt: '2026-07-28T12:00:00.000Z',
    updatedAt: '2026-07-29T12:00:00.000Z',
    verified: true,
    lastTimeVerified: '2026-07-29T12:00:00.000Z',
    lastTimeUpdated: null,
    submissionState: 'CONFIRMED',
    submitterEmail: 'nsg-researcher@example.test',
    submitterUsername: 'nsg-researcher',
    blockchainTxId:
      '7c6f65d972d80f65af0f817cbc6f9b5f7bd86e3377bfd593962804afbff02822',
    peerId: 'peer0.nsg.osc.example',
    submissionError: null,
    organization: organizations[0],
  },
  {
    id: 'artifact-cs-001',
    title: 'Citizen Science coastal observations',
    description:
      'A community-contributed collection of coastal observations with collection context.',
    keywords: ['citizen-science', 'coastal', 'observations'],
    links: [],
    dois: [],
    fundingAgencies: ['Community Data Initiative'],
    acknowledgements:
      'Contributed by volunteer observers and reviewed by Citizen Science coordinators.',
    submission_comment:
      'Seasonal release containing observations reviewed through the community quality workflow.',
    footprint:
      '0d315ae0bd6dcf4053de6a7bb58e3989e843335ee8901947dcacfacaddf684ce',
    manifest: [
      {
        filename: 'observations/coastal-observations.csv',
        hash: '31b8be64372a1c76b4fb99984ca63eeb4ad3903d9c3b46d70d4b764fea450e81',
        algorithm: 'sha256',
      },
      {
        filename: 'metadata/data-dictionary.json',
        hash: '959654aafe152a443fb43f56cc9b8d74bed70addbe87840ad33e36d80a395742',
        algorithm: 'sha256',
      },
    ],
    submittedAt: '2026-07-27T12:00:00.000Z',
    updatedAt: '2026-07-30T12:00:00.000Z',
    verified: false,
    lastTimeVerified: null,
    lastTimeUpdated: '2026-07-30T12:00:00.000Z',
    submissionState: 'CONFIRMED',
    submitterEmail: 'coordinator@example.test',
    submitterUsername: 'citizen-science-coordinator',
    blockchainTxId:
      '99fa2aacdb8234b5222d342384eff9d5acd7dbe1b3dc1214d0ad68b8f7a39d09',
    peerId: 'peer0.citizen-science.osc.example',
    submissionError: null,
    organization: organizations[1],
  },
  {
    id: 'artifact-nsg-002',
    title: 'Neural signal processing reference implementation',
    description:
      'Versioned software and test inputs for a neural signal processing method.',
    keywords: ['neuroscience', 'software'],
    links: ['https://github.com/OpenScienceChain/OSC-Chaincode'],
    dois: [],
    fundingAgencies: ['National Science Foundation'],
    acknowledgements: 'Developed with the Neuroscience Gateway community.',
    submission_comment: 'Reference implementation and deterministic test data.',
    footprint:
      '78283295d7ff52ecbc85e7e27ac92452dd831956acc7aa261084199fb9535431',
    manifest: [
      {
        filename: 'src/filter-signals.py',
        hash: '612910bd2aecbf9c3df4581237ee3e869b4063487f7432138dfd08f5108272d9',
        algorithm: 'sha256',
      },
      {
        filename: 'tests/reference-signal.csv',
        hash: '229e4f09fbc460cc4575871231954947ef9d7b2c88b82a66a81188e3252f14f5',
        algorithm: 'sha256',
      },
    ],
    submittedAt: '2026-07-26T12:00:00.000Z',
    updatedAt: '2026-07-30T12:00:00.000Z',
    verified: true,
    lastTimeVerified: '2026-07-30T12:00:00.000Z',
    lastTimeUpdated: null,
    submissionState: 'CONFIRMED',
    submitterEmail: 'developer@example.test',
    submitterUsername: 'nsg-developer',
    blockchainTxId:
      '4f89b4fd291e88d81eab76310481f28596bc9f55ba4ac6598e85a5bc8136c184',
    peerId: 'peer0.nsg.osc.example',
    submissionError: null,
    organization: organizations[0],
  },
];

const workflows = [
  {
    id: 'workflow-nsg-001',
    title: 'Reproducible neuroimaging preparation',
    description:
      'A documented process for preparing, validating, and publishing neuroimaging inputs.',
    keywords: ['neuroscience', 'workflow'],
    githubRepositories: [
      {
        url: 'https://github.com/OpenScienceChain/OSC-Chaincode',
        description:
          'Chaincode and supporting logic used to register provenance events.',
        gitHash: '44f6a8fb818929cd1b7b2fb47226a0c557308ea7',
        contents: [
          {
            filename: 'README.md',
            hash: 'af2e6cdfbf684f9059859db9edb6a24df957572f31ee5dc96ca42c0a1f9522a4',
          },
          {
            filename: 'chaincode/',
            hash: '',
          },
          {
            filename: 'chaincode/artifact.go',
            hash: '28b6c49f410b74047ddb393665651adf14e5d92fb636d4848a702566f9045ecf',
          },
          {
            filename: 'chaincode/workflow.go',
            hash: 'f591ab85e36fc04735f3a447f17f1f2355b30848e17a28b74cb7a20a83e4685a',
          },
        ],
      },
    ],
    artifacts: [
      {
        id: 'artifact-nsg-001',
        title: 'Neuroscience image segmentation dataset',
        description:
          'Curated imaging inputs and reference labels used by this preparation workflow.',
      },
      {
        id: 'artifact-nsg-002',
        title: 'Neural signal processing reference implementation',
        description:
          'Versioned software and deterministic test inputs used during validation.',
      },
    ],
    submissionState: 'SUCCESS',
    submitterEmail: 'nsg-researcher@example.test',
    submitterUsername: 'nsg-researcher',
    submission_comment:
      'Records the preparation, validation, and publication sequence used for this release.',
    submittedAt: '2026-07-28T12:00:00.000Z',
    updatedAt: '2026-07-29T12:00:00.000Z',
    blockchainTxId:
      'd4ca802d8b18353f9b538f65f52293a556aa245ff3777bba516f32c27655ee40',
    peerId: 'peer0.nsg.osc.example',
    submissionError: null,
    organization: organizations[0],
  },
  {
    id: 'workflow-cs-001',
    title: 'Community observation quality review',
    description:
      'A repeatable review path for validating and publishing contributed observations.',
    keywords: ['citizen-science', 'quality'],
    githubRepositories: [],
    artifacts: [
      {
        id: 'artifact-cs-001',
        title: 'Citizen Science coastal observations',
        description:
          'Community observations reviewed and published through this workflow.',
      },
    ],
    submissionState: 'SUCCESS',
    submitterEmail: 'coordinator@example.test',
    submitterUsername: 'citizen-science-coordinator',
    submission_comment:
      'Documents review, correction, approval, and publication of the seasonal dataset.',
    submittedAt: '2026-07-27T12:00:00.000Z',
    updatedAt: '2026-07-30T12:00:00.000Z',
    blockchainTxId:
      '86c8e378a84ab094548e616296ad086904613741274acc713b2f062cb346cb77',
    peerId: 'peer0.citizen-science.osc.example',
    submissionError: null,
    organization: organizations[1],
  },
];

let scenario = 'success';
let scenarioRequestCount = 0;

function sendJson(response, status, body) {
  response.writeHead(status, {
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-OSC-Organization',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
  });
  response.end(JSON.stringify(body));
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function organizationFilter(url, values) {
  const requested = url.searchParams.get('organization');
  if (!requested) return values;
  const normalized = requested.toLowerCase();
  return values.filter((value) => {
    const organization = value.organization;
    return (
      organization.code.toLowerCase() === normalized ||
      organization.name.toLowerCase() === normalized ||
      organization.id.toLowerCase() === normalized
    );
  });
}

async function applyScenario(request, response, successBody, emptyBody = []) {
  scenarioRequestCount += 1;

  if (scenario === 'slow') {
    await new Promise((resolve) => setTimeout(resolve, 1800));
  }

  if (scenario === 'offline') {
    request.socket.destroy();
    return;
  }

  if (scenario === 'error') {
    sendJson(response, 503, { code: 'SIMULATED_OUTAGE', message: 'Simulated dependency outage' });
    return;
  }

  if (scenario === 'unauthorized') {
    sendJson(response, 401, { code: 'UNAUTHORIZED', message: 'Simulated unauthorized request' });
    return;
  }

  if (scenario === 'expired') {
    sendJson(response, 401, { code: 'TOKEN_EXPIRED', message: 'Simulated expired session' });
    return;
  }

  if (scenario === 'recovery' && scenarioRequestCount === 1) {
    sendJson(response, 503, { code: 'RECOVERING', message: 'First request fails by design' });
    return;
  }

  sendJson(response, 200, scenario === 'empty' ? emptyBody : successBody);
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);

  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-OSC-Organization',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Origin': '*',
    });
    response.end();
    return;
  }

  if (request.method === 'GET' && url.pathname === '/health') {
    sendJson(response, 200, { service: 'osc-ui-simulator', status: 'ok' });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/__control/state') {
    sendJson(response, 200, { scenario, scenarioRequestCount });
    return;
  }

  if (request.method === 'POST' && url.pathname === '/__control/scenario') {
    const body = await readJson(request);
    const allowed = [
      'success',
      'empty',
      'slow',
      'error',
      'offline',
      'unauthorized',
      'expired',
      'recovery',
    ];
    if (!allowed.includes(body.scenario)) {
      sendJson(response, 400, { message: `Unknown scenario: ${body.scenario}` });
      return;
    }
    scenario = body.scenario;
    scenarioRequestCount = 0;
    sendJson(response, 200, { scenario });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/v1/health') {
    sendJson(response, 200, { service: 'osc-ui-simulator', status: 'ok' });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/v1/organizations') {
    await applyScenario(request, response, organizations);
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/v1/artifacts') {
    await applyScenario(request, response, organizationFilter(url, artifacts));
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/v1/workflows') {
    await applyScenario(request, response, organizationFilter(url, workflows));
    return;
  }

  const artifactDetailMatch = url.pathname.match(/^\/api\/v1\/artifacts\/([^/]+)$/);
  if (request.method === 'GET' && artifactDetailMatch) {
    const id = decodeURIComponent(artifactDetailMatch[1]);
    const artifact = artifacts.find((record) => record.id === id);
    if (!artifact) {
      sendJson(response, 404, { message: 'Artifact not found' });
      return;
    }
    await applyScenario(request, response, artifact, null);
    return;
  }

  const workflowDetailMatch = url.pathname.match(/^\/api\/v1\/workflows\/([^/]+)$/);
  if (request.method === 'GET' && workflowDetailMatch) {
    const id = decodeURIComponent(workflowDetailMatch[1]);
    const workflow = workflows.find((record) => record.id === id);
    if (!workflow) {
      sendJson(response, 404, { message: 'Workflow not found' });
      return;
    }
    await applyScenario(request, response, workflow, null);
    return;
  }

  sendJson(response, 404, { message: 'Simulation route not found' });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`OSC UI simulator listening on port ${port}`);
});
