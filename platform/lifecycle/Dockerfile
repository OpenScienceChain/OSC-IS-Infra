FROM golang@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS fabric-tools

ARG FABRIC_COMMIT=f871cf92a026aba7b12e6f06d71ded3e6e659d71
ARG FABRIC_CA_COMMIT=991439f8f01d3f7a31ef77111afadf67a93f8c9d
ARG TERRAFORM_COMMIT=82e042fb6372443813f6759056308d6adc642fa1
ARG KUBERNETES_COMMIT=1c2e10a409eb1b03f2f28f401ce935312e20d9fb

RUN git clone --filter=blob:none --no-checkout https://github.com/hyperledger/fabric.git /src/fabric \
    && git -C /src/fabric checkout --detach "${FABRIC_COMMIT}" \
    && test "$(git -C /src/fabric rev-parse HEAD)" = "${FABRIC_COMMIT}" \
    && git clone --filter=blob:none --no-checkout https://github.com/hyperledger/fabric-ca.git /src/fabric-ca \
    && git -C /src/fabric-ca checkout --detach "${FABRIC_CA_COMMIT}" \
    && test "$(git -C /src/fabric-ca rev-parse HEAD)" = "${FABRIC_CA_COMMIT}" \
    && git clone --filter=blob:none --no-checkout https://github.com/hashicorp/terraform.git /src/terraform \
    && git -C /src/terraform checkout --detach "${TERRAFORM_COMMIT}" \
    && test "$(git -C /src/terraform rev-parse HEAD)" = "${TERRAFORM_COMMIT}" \
    && git clone --filter=blob:none --no-checkout https://github.com/kubernetes/kubernetes.git /src/kubernetes \
    && git -C /src/kubernetes checkout --detach "${KUBERNETES_COMMIT}" \
    && test "$(git -C /src/kubernetes rev-parse HEAD)" = "${KUBERNETES_COMMIT}"

RUN cd /src/fabric \
    && go get golang.org/x/crypto@v0.55.0 golang.org/x/mod@v0.40.0 google.golang.org/grpc@v1.83.2 \
    && CGO_ENABLED=0 go build -mod=mod -buildvcs=false -trimpath \
      -ldflags="-s -w -X github.com/hyperledger/fabric/common/metadata.Version=v2.5.16 -X github.com/hyperledger/fabric/common/metadata.CommitSHA=${FABRIC_COMMIT}" \
      -o /out/ ./cmd/peer ./cmd/configtxgen ./cmd/configtxlator ./cmd/osnadmin \
    && cd /src/fabric-ca \
    && go get golang.org/x/crypto@v0.55.0 google.golang.org/grpc@v1.83.2 \
    && CGO_ENABLED=0 go build -mod=mod -buildvcs=false -trimpath -tags caclient \
      -ldflags="-s -w -X github.com/hyperledger/fabric-ca/lib/metadata.Version=v1.5.22" \
      -o /out/fabric-ca-client ./cmd/fabric-ca-client \
    && cd /src/terraform \
    && CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags="-s -w -X github.com/hashicorp/terraform/version.dev=no" \
      -o /out/terraform . \
    && cd /src/kubernetes \
    && CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags="-s -w -X k8s.io/component-base/version.gitVersion=v1.35.8 -X k8s.io/component-base/version.gitCommit=${KUBERNETES_COMMIT}" \
      -o /out/kubectl ./cmd/kubectl

FROM scratch AS fabric-binaries
COPY --from=fabric-tools /out/peer /peer
COPY --from=fabric-tools /out/configtxgen /configtxgen
COPY --from=fabric-tools /out/configtxlator /configtxlator
COPY --from=fabric-tools /out/osnadmin /osnadmin
COPY --from=fabric-tools /out/fabric-ca-client /fabric-ca-client

FROM public.ecr.aws/aws-cli/aws-cli:2.36.1@sha256:406ca32d31e640a56e8d52921b40528cc64bfa59ec9cb4ee1456db6746cb7292

ARG AL2023_REPOSITORY_GUID=59479e247947fb5165d81aa2364f556030fe518713c50b111a30f75cb118dc0f
RUN dnf --setopt=amazonlinux.mirrorlist= \
      --setopt=amazonlinux.baseurl="https://cdn.amazonlinux.com/al2023/core/guids/${AL2023_REPOSITORY_GUID}/x86_64/" \
      upgrade -y \
    && dnf --setopt=amazonlinux.mirrorlist= \
      --setopt=amazonlinux.baseurl="https://cdn.amazonlinux.com/al2023/core/guids/${AL2023_REPOSITORY_GUID}/x86_64/" \
      install -y \
      bash findutils gettext git gzip jq openssl procps-ng python3 shadow-utils tar unzip \
    && dnf clean all \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

COPY --from=fabric-tools /out/terraform /usr/local/bin/terraform
COPY --from=fabric-tools /out/kubectl /usr/local/bin/kubectl

ENV OSC_RUNNER_ROOT=/opt/osc/infra \
    TF_CLI_CONFIG_FILE=/opt/osc/terraform.rc \
    HOME=/opt/osc/home \
    AWS_PAGER=""

COPY terraform/usrse26-eks /opt/osc/infra/terraform/usrse26-eks
COPY terraform/usrse26-control/templates /opt/osc/infra/terraform/usrse26-control/templates
COPY platform/aws /opt/osc/infra/platform/aws
COPY platform/gitops /opt/osc/infra/platform/gitops
COPY platform/scripts /opt/osc/infra/platform/scripts
COPY platform/vendor /opt/osc/infra/platform/vendor
COPY platform/versions.env /opt/osc/infra/platform/versions.env
COPY platform/.generated/fabric-network-eks /opt/osc/infra/platform/.generated/fabric-network-eks
COPY --from=fabric-binaries / /opt/osc/infra/platform/.generated/fabric-network-eks/bin/
COPY platform/.generated/lifecycle-context/chaincode-go/go.mod /opt/osc/chaincode-go/go.mod
COPY platform/lifecycle/osc_demo_lifecycle.py /usr/local/bin/osc-demo-lifecycle
COPY platform/lifecycle/terraform.rc /opt/osc/terraform.rc

RUN chmod 0755 /usr/local/bin/osc-demo-lifecycle \
    && terraform -chdir=/opt/osc/infra/terraform/usrse26-eks providers mirror /opt/osc/provider-mirror \
    && useradd --uid 10001 --create-home --home-dir /opt/osc/home --shell /bin/bash osc-runner \
    && chown -R 10001:10001 /opt/osc/home /opt/osc/infra /opt/osc/chaincode-go

ENTRYPOINT []
USER 10001:10001
WORKDIR /opt/osc/infra

RUN /usr/local/bin/osc-demo-lifecycle SELF_TEST

CMD ["/usr/local/bin/osc-demo-lifecycle", "SELF_TEST"]
