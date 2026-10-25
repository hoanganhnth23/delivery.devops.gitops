#!/usr/bin/env bash
# Remove the local E2E stack, its network and volumes.
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="${E2E_PROJECT:-delivery-e2e}"
docker compose down -v --remove-orphans
