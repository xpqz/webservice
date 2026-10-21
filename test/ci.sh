#!/usr/bin/env bash
# Run the smoke tests against a throwaway copy of the stack: its own compose
# project (so its own database volume) on its own ports. The demo stack and
# its data are never touched. The test stack is removed afterwards.
# Usage: test/ci.sh [test_name ...]
set -uo pipefail
cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME=issues-test
export API_PORT=${API_PORT:-18080} CONSOLE_PORT=${CONSOLE_PORT:-13000}
export BASE=http://localhost:$API_PORT CONSOLE=http://localhost:$CONSOLE_PORT

trap 'docker compose down -v --remove-orphans >/dev/null 2>&1' EXIT
docker compose up -d --build --scale worker=3 --wait >/dev/null 2>&1 \
    || { echo "test stack failed to start"; docker compose logs --tail=30; exit 1; }
test/smoke.sh "$@"
