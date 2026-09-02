# US-RSE 2026 platform experiment

This directory contains the local-first Kubernetes and Fabric experiment. It is
an evidence environment, not a production deployment.

## Safety boundaries

- Kind cluster: `osc-usrse26-infra` (one control plane, three workers).
- Local registry: `osc-usrse26-registry` on loopback port `5017`.
- Ingress: loopback ports `18080` and `18443`.
- Fabric MSP mapping: `org1` is `NSGMSP`; `org2` is
  `CitizenScienceMSP`. Technical service names remain `org1` and `org2` so the
  pinned upstream topology is recognizable.
- Generated enrollments, private keys, runtime manifests, and logs live under
  `platform/.generated` and are ignored by Git.
- The Fabric source is fixed to the commit in `versions.env`. Fabric binaries
  and Kubernetes tooling are downloaded as release assets and verified before
  extraction or execution. No remote installer is piped into a shell.

## Commands

Run these through Ubuntu WSL from the infrastructure repository:

```bash
bash platform/scripts/prepare-local.sh
bash platform/scripts/fabric-up.sh
bash platform/scripts/deploy-local-apps.sh
bash platform/scripts/seed-local-data.sh
bash platform/scripts/validate-local-stack.sh
bash platform/scripts/validate-local-recovery.sh
bash platform/scripts/deploy-local-gitops.sh
bash platform/scripts/validate-local-gitops.sh
bash platform/scripts/fabric-down.sh
```

`fabric-up.sh` fails when an identically named cluster or registry already
exists. `fabric-down.sh` deletes only the exact Kind cluster and a registry
container carrying both OSC experiment labels.

The chaincode CCAAS connection is deliberately plaintext only inside this
isolated local cluster and requires an explicit environment override. The AWS
overlay will use TLS for CCAAS as well as for the externally consumed Fabric
Gateway endpoint.

The GitOps scripts install the vendored Argo CD release and create a disposable
Git repository containing two local-only commits. The repository is served by
an unprivileged, digest-pinned image inside the cluster. The validation records
self-healing of manually injected drift, a controlled rollout, and restoration
of the known-good revision without pushing a branch or exposing credentials.
