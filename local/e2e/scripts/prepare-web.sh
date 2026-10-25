#!/usr/bin/env bash
# Prepare the running local stack for the web portal's live Playwright specs:
# seed a customer/owner/restaurant/shipper, give the customer a default address,
# and provision an admin. Writes the (password-free) fixture as JSON.
#
#   WEB_FIXTURE_FILE  where to write the fixture (default: .run/web-fixture.json)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${BASE:-http://127.0.0.1:${E2E_GATEWAY_PORT:-8079}}"
PASS="${PASS:-Password123!}"
OUT="${WEB_FIXTURE_FILE:-$E2E_DIR/.run/web-fixture.json}"
if [ -n "${COMPOSE_FILE:-}" ]; then
  COMPOSE_COMMAND=(docker compose -p "${E2E_PROJECT:-delivery-e2e}")
else
  COMPOSE_COMMAND=(docker compose -f "$E2E_DIR/docker-compose.yml" -p "${E2E_PROJECT:-delivery-e2e}")
fi

seed="$(mktemp)"; trap 'rm -f "$seed"' EXIT
SEED_OUTPUT_FILE="$seed" SEED_SHIPPER_COUNT=1 SEED_SKIP_OUTSIDER=true \
  SEED_LOCAL_FIXTURE_EMAIL_VERIFIED=true SEED_WAIT_SHIPPER_IDENTITY_PROJECTION=true \
  BASE="$BASE" PASS="$PASS" bash "$SCRIPT_DIR/seed.sh" >/dev/null

customer_token="$(jq -er .customerToken "$seed")"
# JWT subject is the legacy user id (JWT_ACCESS_TOKEN_SUBJECT_MODE=LEGACY_USER_ID).
payload="$(cut -d. -f2 <<<"$customer_token" | tr '_-' '/+')"
while (( ${#payload} % 4 )); do payload="$payload="; done
customer_user_id="$(base64 -d <<<"$payload" 2>/dev/null | jq -er .sub)"
curl --fail-with-body -sS -X POST "$BASE/api/addresses/users/$customer_user_id/addresses" \
  -H "Authorization: Bearer $customer_token" -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson lat "$(jq .customerLat "$seed")" --argjson lng "$(jq .customerLng "$seed")" \
    '{label:"Nhà", recipientName:"Khách Web E2E", phoneNumber:"0900000002",
      addressLine:"45 Nguyễn Trãi", ward:"Mộ Lao", district:"Hà Đông", city:"Hà Nội",
      latitude:$lat, longitude:$lng, isDefault:true}')" >/dev/null

admin_email="admin+$(jq -r .runId "$seed")@test.dev"
"${COMPOSE_COMMAND[@]}" run --rm --no-deps \
  -e APP_OPERATOR_ADMIN_PROVISIONING_ENABLED=true \
  -e APP_OPERATOR_ADMIN_PROVISIONING_EMAIL="$admin_email" \
  -e APP_OPERATOR_ADMIN_PROVISIONING_PASSWORD="$PASS" \
  -e APP_OPERATOR_ADMIN_PROVISIONING_EXIT_AFTER_RUN=true \
  auth-service >/dev/null
# Same email-verification race as the seeded actors: wait until Auth lets it in.
for _ in $(seq 1 30); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$admin_email" --arg p "$PASS" '{email:$e,password:$p,deviceId:"prep",deviceName:"prep",deviceType:"WEB"}')")"
  [ "$code" = 200 ] && break
  "${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d auth_db -qAt -c \
    "UPDATE auth_account SET lifecycle_status = 'ACTIVE' WHERE email = '$admin_email'
       AND lifecycle_status = 'PENDING_EMAIL_VERIFICATION';" >/dev/null
  sleep 2
done
[ "$code" = 200 ] || { echo "admin $admin_email cannot log in (HTTP $code)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
jq -n --slurpfile s "$seed" --arg admin "$admin_email" --arg base "$BASE" \
  '$s[0] | {gatewayBaseUrl:$base, restaurantId, menuItemId, customerEmail, ownerEmail,
            adminEmail:$admin, shipperEmail:.shippers[0].email, shipperId:.shippers[0].shipperId}' > "$OUT"
chmod 600 "$OUT"
echo "web fixture: $OUT"
