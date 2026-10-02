# Local system tests

This harness validates the asynchronous OSC-IS submission path with the real
RabbitMQ topology, adapter, and submission worker images. The external
blockchain boundary is represented by `mock-osc-api`; neither AWS credentials
nor Fabric identities are required.

The scenarios cover:

1. A version 2 command with explicit organization routing succeeds.
2. Commands remain durable while the worker is stopped and are processed when it returns.
3. An adapter outage produces an explicit failed result instead of silent loss.
4. A subsequent command succeeds after the adapter restarts.

Run on Windows:

```powershell
./run.ps1
```

Run on Linux or in CI:

```bash
./run.sh
```

The scripts always remove their containers and volumes at the end. They use
only fixed local test credentials inside the disposable Compose network.
