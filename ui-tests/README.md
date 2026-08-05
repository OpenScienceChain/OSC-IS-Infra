# Credential-free WebApp deployment tests

This stack validates a blank-machine deployment without AWS, Globus, GitHub,
or production credentials. It runs:

- the production WebApp image behind Nginx;
- the real API Gateway connected to disposable PostgreSQL and RabbitMQ;
- a deterministic API simulator seeded with Neuroscience Gateway (NSG) and
  Citizen Science records.

The seed includes full artifact and workflow details: SHA-256 manifests,
transaction and peer identifiers, linked artifacts, repository revisions, and
organization ownership. Catalog links therefore exercise realistic record
inspection instead of stopping at list mocks.

The WebApp points to the simulator during browser tests. This keeps UI results
repeatable while the real API Gateway independently proves that its database and
broker dependencies boot. The interruption checks stop RabbitMQ and the API
Gateway in turn, verify the expected surviving services, and restart them.

## Run

From this directory on Windows:

```powershell
.\run.ps1
```

Keep the environment running for inspection:

```powershell
.\run.ps1 -KeepRunning
```

Re-run without rebuilding images:

```powershell
.\run.ps1 -SkipBuild -KeepRunning
```

Linux runners can use `./run.sh`. Set `KEEP_RUNNING=true` or `SKIP_BUILD=true`
for the equivalent options.

## Local endpoints

| Service | URL |
| --- | --- |
| WebApp | `http://127.0.0.1:8080` |
| API Gateway health | `http://127.0.0.1:3300/api/v1/health` |
| Simulator health | `http://127.0.0.1:3310/health` |
| RabbitMQ management | `http://127.0.0.1:15672` |

All passwords in `docker-compose.yml` are disposable fixtures scoped to this
local Compose network. They are not acceptable deployment credentials.

## Simulation contract

Set a scenario with:

```bash
curl -X POST http://127.0.0.1:3310/__control/scenario \
  -H "Content-Type: application/json" \
  -d '{"scenario":"slow"}'
```

Supported scenarios are `success`, `empty`, `slow`, `error`, `offline`,
`unauthorized`, `expired`, and `recovery`. Organization isolation can be probed
with `?organization=NSG` or `?organization=Citizen%20Science` on artifact and
workflow endpoints.
