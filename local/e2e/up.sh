#!/usr/bin/env bash
# Start the local E2E stack and wait until every service is ready.
#   E2E_PROJECT  compose project name (default: delivery-e2e)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
export COMPOSE_PROJECT_NAME="${E2E_PROJECT:-delivery-e2e}"

# Per-checkout secrets, generated once and never committed (.run/ is git-ignored).
mkdir -p .run && chmod 700 .run
[ -s .run/internal-secret ] || openssl rand -hex 32 > .run/internal-secret
[ -s .run/db-password ] || openssl rand -hex 24 > .run/db-password
[ -s .run/web-bff-encryption-key ] || openssl rand -base64 -out .run/web-bff-encryption-key 32
if [ ! -s .run/jwt-private.pem ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out .run/jwt-private.pem 2>/dev/null
  openssl rsa -in .run/jwt-private.pem -pubout -out .run/jwt-public.pem 2>/dev/null
fi
chmod 644 .run/*   # containers run as non-root users and must read the mounted files

docker compose up -d --wait --wait-timeout "${E2E_WAIT_SECONDS:-600}"
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
