#!/usr/bin/env bash
# One command: build images, start the stack, run the golden COD flow, the
# tier-2 business scenarios and the tier-3 fault scenarios, tear down.
# (Tier 4, the browser specs, lives in delivery.client.web-portal:
#  scripts/run-live-e2e.sh, which reuses this stack.)
#   E2E_SKIP_BUILD=true  reuse images from a previous build.sh
#   E2E_KEEP=true        leave the stack running afterwards (for debugging / web specs)
#   E2E_TIER2=false / E2E_TIER3=false  skip a tier
#   TIER2_ONLY / TIER2_SKIP_SLOW / TIER3_ONLY  see the tier scripts
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

# Test-only retry timers so "no shipper found" settles in ~30 s. The matching
# deadline keeps its production 5 minutes: it is absolute from the first search,
# so it must outlast the fixed 180 s offer window or a rematch after an offer
# timeout gives up without searching.
export E2E_MATCH_RETRY_ATTEMPTS="${E2E_MATCH_RETRY_ATTEMPTS:-3}"
export E2E_MATCH_DELAY_SECONDS="${E2E_MATCH_DELAY_SECONDS:-5}"
export E2E_MATCH_MAX_DELAY_SECONDS="${E2E_MATCH_MAX_DELAY_SECONDS:-10}"
export E2E_TIMEOUT_POLL_MS="${E2E_TIMEOUT_POLL_MS:-5000}"
export SEED_LOCAL_FIXTURE_EMAIL_VERIFIED=true
# Wait for the shipper identity projection before publishing a location; otherwise
# tracking (pre-enforcement) falls back to the auth user id and Match sees the wrong shipper.
export SEED_WAIT_SHIPPER_IDENTITY_PROJECTION=true

[ "${E2E_SKIP_BUILD:-false}" = "true" ] || "$HERE/build.sh"
"$HERE/up.sh"
bash "$HERE/scripts/verify-mvp-cod-flow.sh"
status=0
[ "${E2E_TIER2:-true}" = "false" ] || bash "$HERE/scripts/tier2-scenarios.sh" || status=1
[ "${E2E_TIER3:-true}" = "false" ] || bash "$HERE/scripts/tier3-resilience.sh" || status=1
exit $status
