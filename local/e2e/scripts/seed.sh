#!/usr/bin/env bash
# =============================================================================
# Seed dữ liệu test cơ bản cho luồng đặt hàng end-to-end.
# Tạo: 1 khách, 1 chủ nhà hàng (+ nhà hàng + 1 menu item), 1 shipper (online +
# có vị trí trong Redis GEO) — đủ điều kiện để đặt đơn và match shipper.
#
# Yêu cầu: cụm docker-compose đang chạy & healthy, có `curl` và `jq`.
# Chạy:   bash local/e2e/scripts/seed.sh (stack từ local/e2e/up.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE="${BASE:-http://localhost:8079}"   # API Gateway (server.port=8079)
PASS="${PASS:-Password123!}"
SHIPPER_DEPOSIT="${SHIPPER_DEPOSIT:-500000}"
SEED_SHIPPER_COUNT="${SEED_SHIPPER_COUNT:-1}"
RUN_ID="${RUN_ID:-$(date +%s)}"
RUN_SUFFIX="${RUN_ID: -8}"
SEED_OUTPUT_FILE="${SEED_OUTPUT_FILE:-}"
SEED_SKIP_OFFLINE_PREVIOUS_SHIPPERS="${SEED_SKIP_OFFLINE_PREVIOUS_SHIPPERS:-false}"
SEED_SKIP_SHIPPER="${SEED_SKIP_SHIPPER:-false}"
SEED_SKIP_OUTSIDER="${SEED_SKIP_OUTSIDER:-false}"
SEED_AUTH_DIRECT_LOGIN="${SEED_AUTH_DIRECT_LOGIN:-false}"
SEED_SIMULATION_ACTORS="${SEED_SIMULATION_ACTORS:-false}"
SIMULATION_COHORT_ID="${SIMULATION_COHORT_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
# Runtime rehearsals may use an isolated local database fixture without an
# SMTP inbox. Production/default seeding never bypasses email verification.
SEED_LOCAL_FIXTURE_EMAIL_VERIFIED="${SEED_LOCAL_FIXTURE_EMAIL_VERIFIED:-false}"
SEED_WAIT_SHIPPER_IDENTITY_PROJECTION="${SEED_WAIT_SHIPPER_IDENTITY_PROJECTION:-false}"

# ⚠️ Role: các service downstream kiểm tra theo các chuỗi này
#   (USER = khách, SHOP_OWNER = chủ nhà hàng, SHIPPER = shipper).
#   Lưu ý có điểm lệch role đã biết giữa auth và các service — xem
#   docs/product/features/order-lifecycle.md §11.
ROLE_CUSTOMER="USER"
ROLE_OWNER="SHOP_OWNER"
ROLE_SHIPPER="SHIPPER"

# Toạ độ mẫu Hà Đông — nhà hàng, khách và shipper gần nhau để match tìm thấy.
REST_LAT="20.9717"; REST_LNG="105.7770"
SHIPPER_LAT="20.9730"; SHIPPER_LNG="105.7790"
CUSTOMER_LAT="20.9760"; CUSTOMER_LNG="105.7750"
MENU_PRICE="45000"
REST_IMAGE="${REST_IMAGE:-https://example.com/e2e/restaurant.webp}"
MENU_IMAGE="${MENU_IMAGE:-https://example.com/e2e/menu-item.webp}"

command -v jq >/dev/null || { echo "❌ Cần cài jq"; exit 1; }
command -v docker >/dev/null || { echo "❌ Cần Docker để seed ledger ký quỹ local"; exit 1; }
command -v grep >/dev/null || { echo "❌ Cần grep để xác nhận fixture local"; exit 1; }

[[ "$SEED_SKIP_SHIPPER" == "true" || "$SEED_SKIP_SHIPPER" == "false" ]] || {
  echo "SEED_SKIP_SHIPPER must be true or false" >&2
  exit 2
}
[[ "$SEED_WAIT_SHIPPER_IDENTITY_PROJECTION" == "true" || "$SEED_WAIT_SHIPPER_IDENTITY_PROJECTION" == "false" ]] || {
  echo "SEED_WAIT_SHIPPER_IDENTITY_PROJECTION must be true or false" >&2
  exit 2
}
[[ "$SEED_SKIP_OUTSIDER" == "true" || "$SEED_SKIP_OUTSIDER" == "false" ]] || {
  echo "SEED_SKIP_OUTSIDER must be true or false" >&2
  exit 2
}
[[ "$SEED_SHIPPER_COUNT" =~ ^[1-9][0-9]*$ ]] || {
  echo "SEED_SHIPPER_COUNT must be a positive integer" >&2
  exit 2
}
[[ "$SEED_AUTH_DIRECT_LOGIN" == "true" || "$SEED_AUTH_DIRECT_LOGIN" == "false" ]] || {
  echo "SEED_AUTH_DIRECT_LOGIN must be true or false" >&2
  exit 2
}
[[ "$SEED_SIMULATION_ACTORS" == "true" || "$SEED_SIMULATION_ACTORS" == "false" ]] || {
  echo "SEED_SIMULATION_ACTORS must be true or false" >&2
  exit 2
}
[[ "$SIMULATION_COHORT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || {
  echo "SIMULATION_COHORT_ID must be a UUID" >&2
  exit 2
}

# A retained-volume rehearsal may need to log in several older fixture shippers
# before the new one. Respect Gateway 429 Retry-After instead of weakening the
# public-auth rate-limit policy for test automation.
# Multi-shipper simulation fixtures legitimately perform several login/profile
# calls in one run. Honour gateway Retry-After instead of weakening public auth
# limits; the broader budget lets a 3+ actor fixture drain the fixed window.
CURL_RETRY_ARGS=(--retry 12 --retry-all-errors --retry-max-time 600)

# Seed writes local fixture rows and must stay inside the same compose project
# as the Gateway passed through BASE (see local/e2e/up.sh).
# COMPOSE_FILE (absolute paths) lets a run layer overrides on the stack.
if [ -n "${COMPOSE_FILE:-}" ]; then
  COMPOSE_COMMAND=(docker compose -p "${E2E_PROJECT:-delivery-e2e}")
else
  COMPOSE_COMMAND=(docker compose -f "$E2E_DIR/docker-compose.yml" -p "${E2E_PROJECT:-delivery-e2e}")
fi

# Trích token: thử cả dạng bọc BaseResponse (.data) lẫn phẳng.
extract() { jq -r "$1 // .data$1 // empty"; }

verify_local_fixture_email() {
  [[ "$SEED_LOCAL_FIXTURE_EMAIL_VERIFIED" == "true" ]] || return 0
  # Auth derives lifecycle_status when the User profile link arrives (async).
  # If that link wins the race against this update, the account stays
  # PENDING_EMAIL_VERIFICATION, so re-apply until it reads ACTIVE.
  local attempt lifecycle=""
  for attempt in $(seq 1 30); do
    lifecycle="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d auth_db \
      -qAt \
      -c "UPDATE auth_account
          SET email_verification_required = false,
              email_verified_at = COALESCE(email_verified_at, CURRENT_TIMESTAMP),
              lifecycle_status = CASE WHEN lifecycle_status = 'PENDING_EMAIL_VERIFICATION'
                                      THEN 'ACTIVE' ELSE lifecycle_status END
          WHERE email = '$1'
          RETURNING lifecycle_status;")"
    [[ "$lifecycle" == "ACTIVE" ]] && return 0
    sleep 1
  done
  echo "❌ Không thể verify local fixture email $1 (lifecycle=${lifecycle:-<none>})"
  return 1
}

register() { # email role
  local auth_response provisioning_token
  auth_response="$(curl "${CURL_RETRY_ARGS[@]}" --fail-with-body --silent --show-error \
    -X POST "$BASE/api/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$PASS\",\"role\":\"$2\"}")"
  provisioning_token="$(jq -r '
    if (.data | type) == "object" then (.data.provisioningToken // empty)
    else empty end' <<< "$auth_response")"
  if [[ -z "$provisioning_token" ]]; then
    # Retained local stacks may still run the previous Auth image, where Auth
    # completed User provisioning itself and returned boolean success. This is
    # fixture compatibility only; production clients remain on the new token
    # handoff contract in the current source tree.
    jq -e '(.data == true) or (. == true)' <<< "$auth_response" >/dev/null \
      || { echo "❌ Auth registration không trả provisioning token hoặc legacy success"; return 1; }
    verify_local_fixture_email "$1"
    return 0
  fi
  curl "${CURL_RETRY_ARGS[@]}" --fail-with-body --silent --show-error \
    -X POST "$BASE/api/users/registrations" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg token "$provisioning_token" --arg name "Seed $2" \
      '{provisioningToken: $token, fullName: $name}')" >/dev/null
  verify_local_fixture_email "$1"
}

login() { # email deviceId -> echoes accessToken
  if [[ "$SEED_AUTH_DIRECT_LOGIN" == "true" ]]; then
    # Sandbox fixture bootstrap only: retain Auth's real login and JWT issuance
    # while avoiding the public Gateway fixed-window shared by a large actor
    # cohort. Simulator traffic itself always goes through Gateway.
    local attempt response token request_body last_failure='empty response'
    request_body="$(jq -nc --arg email "$1" --arg password "$PASS" --arg device_id "$2" \
      '{email:$email,password:$password,deviceId:$device_id,deviceName:"MVP seed",deviceType:"WEB"}')"
    # Auth only permits login after the User profile-created event has linked
    # the newly registered identity.  The public path already retries; direct
    # sandbox fixture login must wait for the same asynchronous convergence.
    # A clean sandbox starts Kafka consumers, User's outbox relay and Auth's
    # profile-link consumer at nearly the same time.  Under a cold Docker host
    # their first poll/rebalance can take longer than the old 20-second budget;
    # wait for the real ACTIVE lifecycle rather than treating that convergence
    # as a failed credential.
    for attempt in $(seq 1 60); do
      response="$("${COMPOSE_COMMAND[@]}" exec -T auth-service wget -qO- \
        --header='Content-Type: application/json' \
        --post-data="$request_body" \
        http://localhost:8081/api/auth/login 2>/dev/null || true)"
      token="$(jq -r '.accessToken // .data.accessToken // empty' <<< "$response" 2>/dev/null || true)"
      if [[ -n "$token" ]]; then
        printf '%s\n' "$token"
        return 0
      fi
      last_failure="$(jq -r '.message // .error // .data.message // "invalid login response"' <<< "$response" 2>/dev/null || printf '%s' 'invalid login response')"
      sleep 1
    done
    printf '❌ Auth fixture login did not issue an access token for %s after %s attempts: %s\n' \
      "$1" "$attempt" "$last_failure" >&2
    return 1
  fi
  curl "${CURL_RETRY_ARGS[@]}" --fail-with-body --silent --show-error \
    -X POST "$BASE/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$PASS\",\"deviceId\":\"$2\",\"deviceName\":\"MVP seed\",\"deviceType\":\"WEB\"}" \
    | jq -r '.accessToken // .data.accessToken // empty'
}

offline_previous_seed_shippers() {
  local rows email token cleanup_index=0
  rows="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql \
    -U postgres -d auth_db -At \
    -c "SELECT email FROM auth_account WHERE role = 'SHIPPER' AND email LIKE 'shipper+%@test.dev';" \
    2>/dev/null || true)"
  [[ -z "$rows" ]] && return 0

  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    cleanup_index=$((cleanup_index + 1))
    token="$(login "$email" "seed-$RUN_ID-cleanup-$cleanup_index" 2>/dev/null || true)"
    [[ -n "$token" ]] || continue
    curl --fail-with-body --silent --show-error -X PATCH \
      "$BASE/api/shippers/online-status?isOnline=false" \
      -H "Authorization: Bearer $token" >/dev/null || true
    curl --fail-with-body --silent --show-error -X POST \
      "$BASE/api/tracking/shipper-locations/offline" \
      -H "Authorization: Bearer $token" >/dev/null || true
  done <<< "$rows"
  echo "✅ Shipper fixture cũ đã được đưa offline"
}

operator_provision_shipper() {
  local email="$1"
  local safe_run_id="${RUN_ID//[^a-zA-Z0-9_.-]/-}"
  "${COMPOSE_COMMAND[@]}" run --rm --no-deps \
    --name "auth-shipper-provision-$safe_run_id" \
    -e EUREKA_CLIENT_REGISTER_WITH_EUREKA=false \
    -e APP_OPERATOR_SHIPPER_PROVISIONING_ENABLED=true \
    -e APP_OPERATOR_SHIPPER_PROVISIONING_EMAIL="$email" \
    -e APP_OPERATOR_SHIPPER_PROVISIONING_PASSWORD="$PASS" \
    -e APP_OPERATOR_SHIPPER_PROVISIONING_EXIT_AFTER_RUN=true \
    auth-service >/dev/null
}

echo "🌱 Seeding vào $BASE ..."

# --- 1. Khách hàng ---
CUST_EMAIL="customer+$RUN_ID@test.dev"
register "$CUST_EMAIL" "$ROLE_CUSTOMER"
CUST_TOKEN="$(login "$CUST_EMAIL" "seed-$RUN_ID-customer")"
[[ -n "$CUST_TOKEN" ]] || { echo "❌ Login customer không trả access token"; exit 1; }
echo "✅ Khách: $CUST_EMAIL (token ${CUST_TOKEN:+ok})"

# Khách không liên quan dùng để khóa participant authorization của raw WebSocket.
OUTSIDER_EMAIL=""
OUTSIDER_TOKEN=""
if [[ "$SEED_SKIP_OUTSIDER" == "true" ]]; then
  echo "SEED_SKIP_OUTSIDER=true — bỏ qua outsider fixture chỉ dùng cho WebSocket authorization."
else
  OUTSIDER_EMAIL="outsider+$RUN_ID@test.dev"
  register "$OUTSIDER_EMAIL" "$ROLE_CUSTOMER"
  OUTSIDER_TOKEN="$(login "$OUTSIDER_EMAIL" "seed-$RUN_ID-outsider")"
  [[ -n "$OUTSIDER_TOKEN" ]] || { echo "❌ Login outsider không trả access token"; exit 1; }
  echo "✅ Khách ngoài delivery: $OUTSIDER_EMAIL (token ${OUTSIDER_TOKEN:+ok})"
fi

# --- 2. Chủ nhà hàng + nhà hàng + menu ---
OWNER_EMAIL="owner+$RUN_ID@test.dev"
register "$OWNER_EMAIL" "$ROLE_OWNER"
OWNER_TOKEN="$(login "$OWNER_EMAIL" "seed-$RUN_ID-owner")"
[[ -n "$OWNER_TOKEN" ]] || { echo "❌ Login owner không trả access token"; exit 1; }
echo "✅ Chủ NH: $OWNER_EMAIL (token ${OWNER_TOKEN:+ok})"

REST_ID="$(curl --fail-with-body --silent --show-error -X POST "$BASE/api/restaurants" \
  -H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Quán Test HÀ ĐÔNG\",\"address\":\"123 Trần Phú, Phường Mộ Lao, Hà Đông, Hà Nội\",\"phone\":\"0900000001\",\"openingHour\":\"00:00\",\"closingHour\":\"23:59\",\"addressLat\":$REST_LAT,\"addressLng\":$REST_LNG,\"description\":\"Quán test phục vụ món Việt tại Hà Đông\",\"image\":\"$REST_IMAGE\"}" \
  | jq -r '.id // .data.id // empty')"
[[ "$REST_ID" =~ ^[0-9]+$ ]] || { echo "❌ Không tạo được restaurant canonical"; exit 1; }
echo "✅ Nhà hàng id=$REST_ID"

MENU_ID="$(curl --fail-with-body --silent --show-error -X POST "$BASE/api/menu-items" \
  -H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Cơm gà sốt nấm\",\"description\":\"Cơm nóng, gà nướng và sốt nấm nhà làm\",\"price\":$MENU_PRICE,\"restaurantId\":$REST_ID,\"image\":\"$MENU_IMAGE\"}" \
  | jq -r '.id // .data.id // empty')"
[[ "$MENU_ID" =~ ^[0-9]+$ ]] || { echo "❌ Không tạo được menu item canonical"; exit 1; }
echo "✅ Menu item id=$MENU_ID"

# --- 3. Shipper: hồ sơ + online + vị trí ---
SHIPPER_TOKEN=""
SHIPPER_USER_ID=""
SHIPPER_ID=""
SHIPPER_FIXTURES_JSON='[]'
SHIPPER_EMAILS=()
if [[ "$SEED_SKIP_SHIPPER" == "true" ]]; then
  echo "SEED_SKIP_SHIPPER=true — bỏ qua shipper, ký quỹ và vị trí Redis GEO."
else
if [[ "$SEED_SKIP_OFFLINE_PREVIOUS_SHIPPERS" != "true" ]]; then
  offline_previous_seed_shippers
fi
for shipper_index in $(seq 1 "$SEED_SHIPPER_COUNT"); do
  shipper_suffix="${RUN_SUFFIX}${shipper_index}"
  shipper_email="shipper+$RUN_ID-$shipper_index@test.dev"
  shipper_lat="$(awk -v base="$SHIPPER_LAT" -v n="$shipper_index" 'BEGIN { printf "%.6f", base + ((n - 1) * 0.001) }')"
  shipper_lng="$(awk -v base="$SHIPPER_LNG" -v n="$shipper_index" 'BEGIN { printf "%.6f", base + ((n - 1) * 0.001) }')"
  operator_provision_shipper "$shipper_email"
  shipper_token="$(login "$shipper_email" "seed-$RUN_ID-shipper-$shipper_index")"
  [[ -n "$shipper_token" ]] || { echo "❌ Login shipper không trả access token"; exit 1; }
  curl --fail-with-body --silent --show-error -X POST "$BASE/api/shippers" \
    -H "Authorization: Bearer $shipper_token" -H 'Content-Type: application/json' \
    -d "{\"fullName\":\"Shipper Test $shipper_index\",\"vehicleType\":\"MOTORBIKE\",\"licenseNumber\":\"LIC-$RUN_ID-$shipper_index\",\"idCard\":\"ID-$RUN_ID-$shipper_index\",\"phone\":\"09$shipper_suffix\",\"licensePlate\":\"59-X$shipper_index-$RUN_SUFFIX\"}" >/dev/null
  shipper_profile="$(curl --fail-with-body --silent --show-error "$BASE/api/shippers/my-profile" \
    -H "Authorization: Bearer $shipper_token")"
  shipper_id="$(jq -r '.data.id // .id // empty' <<< "$shipper_profile")"
  shipper_user_id="$(jq -r '.data.userId // .userId // empty' <<< "$shipper_profile")"
  [[ "$shipper_id" =~ ^[0-9]+$ ]] || { echo "❌ Không lấy được id canonical của shipper"; exit 1; }
  [[ "$shipper_user_id" =~ ^[0-9]+$ ]] || { echo "❌ Không lấy được userId canonical của shipper"; exit 1; }
  if [[ "$SEED_WAIT_SHIPPER_IDENTITY_PROJECTION" == "true" ]]; then
    # The crash harness bounds the entire seed process. Observe the real
    # Kafka projections; never manufacture a mapping or a GEO member.
    for identity_database in tracking_db delivery_db; do
      until [[ "$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres \
        -d "$identity_database" -v ON_ERROR_STOP=1 -At -c \
        "SELECT count(*) FROM shipper_identity_projection
          WHERE shipper_id = $shipper_id AND legacy_user_id = $shipper_user_id;")" == '1' ]]; do
        sleep 2
      done
    done
  fi
  "${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d settlement_db \
    -v shipper_id="$shipper_id" -v deposit_amount="$SHIPPER_DEPOSIT" \
    -f - < "$SCRIPT_DIR/seed-settlement.sql" >/dev/null
  if [[ "$SEED_SIMULATION_ACTORS" == "true" ]]; then
    # Simulator binds these actors before it submits locations. Never seed a
    # real JWT location for a simulation-only actor, or it contaminates the
    # REAL Match GEO namespace before the run begins.
    echo "✅ Shipper fixture $shipper_index is simulation-only; no REAL GEO update"
  else
    curl --fail-with-body --silent --show-error -X PATCH "$BASE/api/shippers/online-status?isOnline=true" \
      -H "Authorization: Bearer $shipper_token" >/dev/null
    curl --fail-with-body --silent --show-error -X POST "$BASE/api/tracking/shipper-locations/update" \
      -H "Authorization: Bearer $shipper_token" -H 'Content-Type: application/json' \
      -d "{\"latitude\":$shipper_lat,\"longitude\":$shipper_lng,\"isOnline\":true}" >/dev/null
  fi
  SHIPPER_EMAILS+=("$shipper_email")
  SHIPPER_FIXTURES_JSON="$(jq -c --arg id "sandbox-shipper-$shipper_index" --arg email "$shipper_email" \
    --arg token "$shipper_token" --argjson userId "$shipper_user_id" --argjson shipperId "$shipper_id" --argjson lat "$shipper_lat" --argjson lng "$shipper_lng" \
    '. + [{id:$id,email:$email,token:$token,userId:$userId,shipperId:$shipperId,lat:$lat,lng:$lng}]' <<< "$SHIPPER_FIXTURES_JSON")"
  if [[ "$shipper_index" == "1" ]]; then
    SHIPPER_EMAIL="$shipper_email"; SHIPPER_TOKEN="$shipper_token"; SHIPPER_USER_ID="$shipper_user_id"; SHIPPER_ID="$shipper_id"
  fi
  echo "✅ Shipper fixture $shipper_index/$SEED_SHIPPER_COUNT online tại ($shipper_lat, $shipper_lng)"
done
fi

if [[ "$SEED_SKIP_SHIPPER" != "true" ]]; then
  "${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d auth_db -qAt -c \
    "UPDATE auth_account SET simulation_actor = true,
        simulation_cohort_id = COALESCE(simulation_cohort_id, '$SIMULATION_COHORT_ID')
     WHERE email IN ('$CUST_EMAIL', '$OWNER_EMAIL'$(printf ",'%s'" "${SHIPPER_EMAILS[@]}"));" >/dev/null
  simulation_cohort_ids="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d auth_db -qAt -c \
    "SELECT DISTINCT simulation_cohort_id FROM auth_account
     WHERE email IN ('$CUST_EMAIL', '$OWNER_EMAIL'$(printf ",'%s'" "${SHIPPER_EMAILS[@]}"))
       AND simulation_actor = true
     ORDER BY simulation_cohort_id;" | sed '/^$/d')"
  if [[ "$(wc -l <<< "$simulation_cohort_ids" | tr -d ' ')" != "1" ]]; then
    echo "❌ Fixture actors must belong to exactly one simulation cohort" >&2
    exit 1
  fi
  SIMULATION_COHORT_ID="$simulation_cohort_ids"
  echo "✅ Actor simulation allowlist đã được gán cho customer/owner/shipper fixture"
fi

if [[ -n "$SEED_OUTPUT_FILE" ]]; then
  umask 077
  jq -n \
    --arg runId "$RUN_ID" \
    --arg simulationCohortId "$SIMULATION_COHORT_ID" \
    --arg customerEmail "$CUST_EMAIL" \
    --arg ownerEmail "$OWNER_EMAIL" \
    --arg customerToken "$CUST_TOKEN" \
    --arg outsiderToken "$OUTSIDER_TOKEN" \
    --arg ownerToken "$OWNER_TOKEN" \
    --arg shipperToken "$SHIPPER_TOKEN" \
    --argjson restaurantId "$REST_ID" \
    --argjson menuItemId "$MENU_ID" \
    --argjson shipperUserId "${SHIPPER_USER_ID:-null}" \
    --argjson shipperId "${SHIPPER_ID:-null}" \
    --argjson shippers "$SHIPPER_FIXTURES_JSON" \
    --argjson restaurantLat "$REST_LAT" \
    --argjson restaurantLng "$REST_LNG" \
    --argjson shipperLat "$SHIPPER_LAT" \
    --argjson shipperLng "$SHIPPER_LNG" \
    --argjson customerLat "$CUSTOMER_LAT" \
    --argjson customerLng "$CUSTOMER_LNG" \
    --argjson menuPrice "$MENU_PRICE" \
    '{runId: $runId, simulationCohortId: $simulationCohortId,
      customerEmail: $customerEmail, ownerEmail: $ownerEmail,
      customerToken: $customerToken, outsiderToken: $outsiderToken,
      ownerToken: $ownerToken,
      shipperToken: $shipperToken, restaurantId: $restaurantId,
      menuItemId: $menuItemId, shipperUserId: $shipperUserId, shipperId: $shipperId,
      shippers: $shippers,
      restaurantLat: $restaurantLat, restaurantLng: $restaurantLng,
      shipperLat: $shipperLat, shipperLng: $shipperLng,
      customerLat: $customerLat, customerLng: $customerLng,
      menuPrice: $menuPrice}' \
    > "$SEED_OUTPUT_FILE"
fi

echo
echo "🎉 Seed xong. Gợi ý đặt đơn thử (đơn thường, không flash sale):"
cat <<EOF
curl -X POST "$BASE/api/orders" \\
  -H "Authorization: Bearer <customer-access-token>" -H 'Content-Type: application/json' \\
  -d '{
    "restaurantId": $REST_ID,
    "deliveryAddress": "45 Nguyễn Trãi, Hà Đông, Hà Nội",
    "deliveryLat": $CUSTOMER_LAT, "deliveryLng": $CUSTOMER_LNG,
    "pickupLat": $REST_LAT, "pickupLng": $REST_LNG,
    "customerName": "Khách Hà Đông", "customerPhone": "0900000001",
    "paymentMethod": "COD",
    "items": [ { "menuItemId": $MENU_ID, "quantity": 2, "price": 45000 } ]
  }'
EOF
