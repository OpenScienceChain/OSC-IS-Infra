#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/.." && pwd)"
GENERATED_DIR="${PLATFORM_DIR}/.generated/gitops"
SOURCE_DIR="${GENERATED_DIR}/source"
SITE_DIR="${GENERATED_DIR}/image/site"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
CLUSTER_NAME="osc-usrse26-infra"
REGISTRY="localhost:5017"
IMAGE_TAG="${REGISTRY}/osc-gitops-repository:${RUN_ID}"

# shellcheck source=../versions.env
source "${PLATFORM_DIR}/versions.env"

for command in docker git kind kubectl python3; do
  command -v "${command}" >/dev/null || {
    echo "Required command not found: ${command}" >&2
    exit 1
  }
done

if ! kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
  echo "Kind cluster ${CLUSTER_NAME} is not running." >&2
  exit 1
fi

rm -rf "${GENERATED_DIR}"
mkdir -p "${SOURCE_DIR}/manifests" "${SITE_DIR}"
cp -a "${PLATFORM_DIR}/gitops/local/." "${SOURCE_DIR}/manifests/"

git -C "${SOURCE_DIR}" init --initial-branch=main >/dev/null
git -C "${SOURCE_DIR}" config user.name "OSC US-RSE evidence"
git -C "${SOURCE_DIR}" config user.email "usrse26-evidence@localhost"
git -C "${SOURCE_DIR}" add manifests
git -C "${SOURCE_DIR}" commit -m "gitops: record known-good local deployment" >/dev/null
BASELINE_REVISION="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"

ROLLOUT_ID="${RUN_ID}"
ROLLOUT_ID="${ROLLOUT_ID}" SOURCE_DIR="${SOURCE_DIR}" python3 - <<'PY'
import os
from pathlib import Path

manifest = Path(os.environ["SOURCE_DIR"]) / "manifests" / "api-gateway.yaml"
text = manifest.read_text(encoding="utf-8")
needle = "  template:\n    metadata:\n      labels:\n"
replacement = (
    "  template:\n"
    "    metadata:\n"
    "      annotations:\n"
    f"        usrse26.osc.example/rollout-id: \"{os.environ['ROLLOUT_ID']}\"\n"
    "      labels:\n"
)
if text.count(needle) != 1:
    raise SystemExit("Could not identify the API Gateway pod template metadata")
manifest.write_text(text.replace(needle, replacement), encoding="utf-8")
PY

git -C "${SOURCE_DIR}" add manifests/api-gateway.yaml
git -C "${SOURCE_DIR}" commit -m "gitops: stage controlled API rollout" >/dev/null
ROLLOUT_REVISION="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"

git clone --bare "${SOURCE_DIR}" "${SITE_DIR}/osc-is-infra.git" >/dev/null
git --git-dir="${SITE_DIR}/osc-is-infra.git" update-server-info

cat >"${GENERATED_DIR}/image/Dockerfile" <<EOF
FROM ${BUSYBOX_IMAGE}
COPY --chown=65534:65534 site /srv
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["busybox", "httpd", "-f", "-p", "8080", "-h", "/srv"]
EOF

docker build --pull=false --tag "${IMAGE_TAG}" "${GENERATED_DIR}/image" >/dev/null
docker push "${IMAGE_TAG}" >/dev/null
REPOSITORY_IMAGE="$(docker image inspect "${IMAGE_TAG}" --format '{{index .RepoDigests 0}}')"
if [[ "${REPOSITORY_IMAGE}" != "${REGISTRY}/osc-gitops-repository@sha256:"* ]]; then
  echo "Could not resolve an immutable repository-server digest." >&2
  exit 1
fi

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace argocd \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite >/dev/null
kubectl apply --server-side --force-conflicts -n argocd \
  -f "${PLATFORM_DIR}/vendor/argocd-install-${ARGOCD_VERSION}.yaml" >/dev/null

kubectl wait -n argocd deployment --all --for=condition=Available --timeout=8m >/dev/null
kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout=8m >/dev/null

REPOSITORY_IMAGE="${REPOSITORY_IMAGE}" \
  BASELINE_REVISION="${BASELINE_REVISION}" \
  ROLLOUT_REVISION="${ROLLOUT_REVISION}" \
  PLATFORM_DIR="${PLATFORM_DIR}" \
  GENERATED_DIR="${GENERATED_DIR}" \
  python3 - <<'PY'
import os
from pathlib import Path

platform = Path(os.environ["PLATFORM_DIR"])
generated = Path(os.environ["GENERATED_DIR"])
replacements = {
    "__REPOSITORY_IMAGE__": os.environ["REPOSITORY_IMAGE"],
    "__BASELINE_REVISION__": os.environ["BASELINE_REVISION"],
    "__ROLLOUT_REVISION__": os.environ["ROLLOUT_REVISION"],
}
for name in ("repository-server.yaml", "application.yaml"):
    source = platform / "gitops" / "bootstrap" / name
    target = generated / name
    text = source.read_text(encoding="utf-8")
    for token, value in replacements.items():
        text = text.replace(token, value)
    if "__" in text:
        raise SystemExit(f"Unresolved template token in {name}")
    target.write_text(text, encoding="utf-8")
PY

kubectl apply -f "${GENERATED_DIR}/repository-server.yaml" >/dev/null
kubectl rollout status -n argocd deployment/osc-gitops-repository --timeout=3m >/dev/null
kubectl apply -f "${GENERATED_DIR}/application.yaml" >/dev/null

cat >"${GENERATED_DIR}/run.env" <<EOF
RUN_ID=${RUN_ID}
BASELINE_REVISION=${BASELINE_REVISION}
ROLLOUT_REVISION=${ROLLOUT_REVISION}
REPOSITORY_IMAGE=${REPOSITORY_IMAGE}
EOF

echo "Argo CD and the immutable local Git source are deployed."
echo "Baseline revision: ${BASELINE_REVISION}"
echo "Rollout revision:  ${ROLLOUT_REVISION}"
echo "Repository image:  ${REPOSITORY_IMAGE}"
