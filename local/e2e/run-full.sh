#!/usr/bin/env bash
# One command: build images, start the stack, run the golden COD flow, tear down.
#   E2E_SKIP_BUILD=true  reuse images from a previous build.sh
#   E2E_KEEP=true        leave the stack running afterwards (for debugging / web specs)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export E2E_PROJECT="${E2E_PROJECT:-delivery-e2e}"
export BASE="${BASE:-http://127.0.0.1:${E2E_GATEWAY_PORT:-8079}}"

cleanup() {
  status=$?
  if [ "${E2E_KEEP:-false}" != "true" ]; then
    "$HERE/down.sh" >/dev/null 2>&1 || true
  else
    echo "E2E_KEEP=true: stack '$E2E_PROJECT' left running ($BASE)"
  fi
  exit $status
}
trap cleanup EXIT

[ "${E2E_SKIP_BUILD:-false}" = "true" ] || "$HERE/build.sh"
"$HERE/up.sh"
# Wait for the shipper identity projection before publishing a location; otherwise
# tracking (pre-enforcement) falls back to the auth user id and Match sees the wrong shipper.
SEED_LOCAL_FIXTURE_EMAIL_VERIFIED=true SEED_WAIT_SHIPPER_IDENTITY_PROJECTION=true \
  bash "$HERE/scripts/verify-mvp-cod-flow.sh"
