#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if ! command -v docker >/dev/null 2>&1; then
    printf 'ERROR: Docker CLI is required to validate Compose files.\n' >&2
    exit 127
fi

export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-validation-only-not-a-real-secret}"

docker compose -f compose.yaml -f compose.override.yaml config --quiet
docker compose -f compose.yaml -f compose.cloud.yaml config --quiet
docker compose -f compose.yaml -f compose.monitoring.yaml --profile monitoring config --quiet
docker compose -f compose.yaml -f compose.override.yaml -f compose.load-balancing.yaml config --quiet

printf 'PASS: local, cloud, monitoring, and load-balancing Compose configurations are valid.\n'
