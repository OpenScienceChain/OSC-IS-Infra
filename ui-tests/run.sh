#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
WEBAPP_DIR="$SCRIPT_DIR/../../OSC-WebApp"

wait_http() {
  url="$1"
  attempt=1
  while [ "$attempt" -le 60 ]; do
    if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "Timed out waiting for $url" >&2
  return 1
}

cleanup() {
  if [ "${KEEP_RUNNING:-false}" != "true" ]; then
    docker compose -f "$COMPOSE_FILE" down -v
  fi
}
trap cleanup EXIT

docker info >/dev/null
if [ "${SKIP_BUILD:-false}" != "true" ]; then
  docker compose -f "$COMPOSE_FILE" build
fi
docker compose -f "$COMPOSE_FILE" up -d

wait_http http://127.0.0.1:8080/healthz
wait_http http://127.0.0.1:3300/api/v1/health
wait_http http://127.0.0.1:3310/health

cd "$WEBAPP_DIR"
npx cypress run --browser chrome --config baseUrl=http://127.0.0.1:8080 --spec cypress/e2e/local-stack/local-stack.cy.ts

docker compose -f "$COMPOSE_FILE" stop rabbitmq
wait_http http://127.0.0.1:3300/api/v1/health
docker compose -f "$COMPOSE_FILE" start rabbitmq

docker compose -f "$COMPOSE_FILE" stop api-gateway
wait_http http://127.0.0.1:8080/healthz
wait_http http://127.0.0.1:3310/health
docker compose -f "$COMPOSE_FILE" start api-gateway
wait_http http://127.0.0.1:3300/api/v1/health

echo "Local OSC deployment and interruption checks passed."
echo "WebApp: http://127.0.0.1:8080"
