#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "$SCRIPT_DIR/docker-compose.yml")

cleanup() {
  "${COMPOSE[@]}" down --volumes --remove-orphans
}
trap cleanup EXIT

cleanup
"${COMPOSE[@]}" up --detach --build rabbitmq mock-ledger-api adapter submission-worker

echo "[1/4] Healthy v2 multi-organization submission"
"${COMPOSE[@]}" --profile probe run --rm probe publish --count 1
"${COMPOSE[@]}" --profile probe run --rm probe wait --count 1 --state SUCCESS

echo "[2/4] Durable queue while the worker is unavailable"
"${COMPOSE[@]}" stop submission-worker
"${COMPOSE[@]}" --profile probe run --rm probe publish --count 2
"${COMPOSE[@]}" --profile probe run --rm probe depth --queue artifact.submit.queue --expected 2
"${COMPOSE[@]}" start submission-worker
"${COMPOSE[@]}" --profile probe run --rm probe wait --count 2 --state SUCCESS

echo "[3/4] Explicit failure event while the adapter is unavailable"
"${COMPOSE[@]}" stop adapter
"${COMPOSE[@]}" --profile probe run --rm probe publish --count 1
"${COMPOSE[@]}" --profile probe run --rm probe wait --count 1 --state FAILED

echo "[4/4] Recovery after the adapter returns"
"${COMPOSE[@]}" start adapter
"${COMPOSE[@]}" --profile probe run --rm probe publish --count 1
"${COMPOSE[@]}" --profile probe run --rm probe wait --count 1 --state SUCCESS

echo "OSC-IS Docker system tests passed."
