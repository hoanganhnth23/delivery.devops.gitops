#!/usr/bin/env bash
set -euo pipefail

readonly BASE="${BASE:-http://127.0.0.1:8079}"
readonly FLOW_TIMEOUT_SECONDS="${FLOW_TIMEOUT_SECONDS:-180}"
readonly POLL_SECONDS=2

command -v curl >/dev/null
command -v jq >/dev/null
command -v docker >/dev/null
if [[ -n "${JAVA_HOME:-}" ]]; then
  readonly JAVA_BIN="$JAVA_HOME/bin/java"
else
  readonly JAVA_BIN="$(command -v java)"
fi
java_version="$($JAVA_BIN -XshowSettings:properties -version 2>&1 \
  | awk -F'= ' '/java.specification.version/{print $2; exit}')"
[[ "$java_version" == "17" ]] || {
  printf 'Tracking WebSocket probe requires JDK 17, found %s.\n' \
    "${java_version:-unknown}" >&2
  exit 1
}

# Keep database/Kafka assertions in the same compose project as the Gateway
# under test (see local/e2e/up.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_COMMAND=(docker compose -f "$SCRIPT_DIR/../docker-compose.yml" -p "${E2E_PROJECT:-delivery-e2e}")

step() {
  printf '[COD] %s\n' "$1"
}

if ! docker info >/dev/null 2>&1; then
  printf '%s\n' "Docker daemon is unavailable; COD flow proof was not executed." >&2
  exit 1
fi

seed_result="$(mktemp)"
trap 'rm -f "$seed_result"' EXIT
step "seed actors, catalog, shipper deposit and location"
env SEED_OUTPUT_FILE="$seed_result" BASE="$BASE" bash "$SCRIPT_DIR/seed.sh" >/dev/null

customer_token="$(jq -er '.customerToken' "$seed_result")"
outsider_token="$(jq -er '.outsiderToken' "$seed_result")"
owner_token="$(jq -er '.ownerToken' "$seed_result")"
shipper_token="$(jq -er '.shipperToken' "$seed_result")"
shipper_user_id="$(jq -er '.shipperUserId' "$seed_result")"
restaurant_id="$(jq -er '.restaurantId' "$seed_result")"
menu_item_id="$(jq -er '.menuItemId' "$seed_result")"

step "customer creates canonical COD order"
order_response="$(curl --fail-with-body --silent --show-error -X POST "$BASE/api/orders" \
  -H "Authorization: Bearer $customer_token" -H 'Content-Type: application/json' \
  -d "{\"restaurantId\":$restaurant_id,\"deliveryAddress\":\"456 Nguyễn Huệ, Q1\",\"deliveryLat\":10.7740,\"deliveryLng\":106.7040,\"customerName\":\"Khách Test\",\"customerPhone\":\"0900000001\",\"paymentMethod\":\"COD\",\"items\":[{\"menuItemId\":$menu_item_id,\"quantity\":2}]}" )"
order_id="$(jq -er '.data.id // .id' <<<"$order_response")"
[[ "$order_id" =~ ^[0-9]+$ ]] || { printf '%s\n' "Order response did not contain a numeric id" >&2; exit 1; }

step "restaurant confirms order"
curl --fail-with-body --silent --show-error -X POST \
  "$BASE/api/restaurants/orders/$order_id/confirm" \
  -H "Authorization: Bearer $owner_token" -H 'Content-Type: application/json' \
  -d "{\"restaurantId\":$restaurant_id,\"estimatedPrepTime\":15}" >/dev/null

deadline=$((SECONDS + FLOW_TIMEOUT_SECONDS))
delivery_id=""
offer_notification_id=""
wait_for_shipper_offer() {
  local notifications notification recovery_endpoint notification_order_id
  local offer_response offer_order_id="" offer_status=""
  while (( SECONDS < deadline )); do
    notifications="$(curl --silent --show-error "$BASE/api/notifications/unread" \
      -H "Authorization: Bearer $shipper_token" || true)"
    notification="$(jq -cer --argjson orderId "$order_id" \
      '[.data[]? | select(.type == "MATCH_FOUND" and .relatedEntityId == $orderId
        and .relatedEntityType == "ORDER")][0] // empty' \
      <<<"$notifications" 2>/dev/null || true)"

    if [[ -n "$notification" ]]; then
      offer_notification_id="$(jq -r '.id // empty' <<<"$notification")"
      recovery_endpoint="$(jq -r '.data | fromjson? | .recoveryEndpoint // empty' \
        <<<"$notification")"
      notification_order_id="$(jq -r '.data | fromjson? | .orderId // empty' \
        <<<"$notification")"
      if [[ "$offer_notification_id" =~ ^[0-9]+$ \
          && "$recovery_endpoint" == "/api/deliveries/offers/current" \
          && "$notification_order_id" == "$order_id" ]]; then
        offer_response="$(curl --silent --show-error \
          "$BASE/api/deliveries/offers/current" \
          -H "Authorization: Bearer $shipper_token" || true)"
        offer_order_id="$(jq -r '.data.orderId // empty' \
          <<<"$offer_response" 2>/dev/null || true)"
        offer_status="$(jq -r '.data.status // empty' \
          <<<"$offer_response" 2>/dev/null || true)"
        delivery_id="$(jq -r '.data.deliveryId // empty' \
          <<<"$offer_response" 2>/dev/null || true)"
      fi
    fi

    if [[ "$offer_order_id" == "$order_id" \
        && "$offer_status" == "WAIT_SHIPPER_CONFIRM" \
        && "$delivery_id" =~ ^[0-9]+$ ]]; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  printf 'Timed out waiting for durable notification + current offer for order %s\n' \
    "$order_id" >&2
  return 1
}

step "observe durable shipper notification and recover current offer"
wait_for_shipper_offer

step "offered shipper accepts"
curl --fail-with-body --silent --show-error -X POST "$BASE/api/deliveries/accept" \
  -H "Authorization: Bearer $shipper_token" -H 'Content-Type: application/json' \
  -d "{\"orderId\":$order_id,\"action\":\"ACCEPT\",\"currentLat\":10.7780,\"currentLng\":106.7020}" >/dev/null

if [[ "$BASE" == https://* ]]; then
  websocket_base="${BASE/https:/wss:}"
else
  websocket_base="${BASE/http:/ws:}"
fi
step "verify raw WebSocket participant authorization and location propagation"
"$JAVA_BIN" "$SCRIPT_DIR/TrackingPublisherProbe.java" \
  "$websocket_base/ws/shipper-locations" participant \
  "$customer_token" "$outsider_token" "$shipper_token" \
  "$delivery_id" "$shipper_user_id"

step "shipper completes delivery lifecycle"
for status in PICKED_UP DELIVERING DELIVERED; do
  curl --fail-with-body --silent --show-error -X PUT \
    "$BASE/api/deliveries/$delivery_id/status?status=$status" \
    -H "Authorization: Bearer $shipper_token" >/dev/null
done

order_deadline=$((SECONDS + FLOW_TIMEOUT_SECONDS))
order_status=""
while (( SECONDS < order_deadline )); do
  order_status="$(curl --silent --show-error "$BASE/api/orders/$order_id" \
    -H "Authorization: Bearer $customer_token" \
    | jq -r '.data.status // .status // empty' 2>/dev/null || true)"
  [[ "$order_status" == "DELIVERED" ]] && break
  sleep "$POLL_SECONDS"
done
[[ "$order_status" == "DELIVERED" ]] || {
  printf 'Order %s did not converge to DELIVERED; last status=%s\n' \
    "$order_id" "${order_status:-<empty>}" >&2
  exit 1
}

step "verify canonical settlement ledger"
ledger_deadline=$((SECONDS + FLOW_TIMEOUT_SECONDS))
ledger_count="0"
while (( SECONDS < ledger_deadline )); do
  ledger_count="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d settlement_db -At \
    -c "SELECT count(*) FROM transactions WHERE order_id = $order_id;")"
  [[ "$ledger_count" == "4" ]] && break
  sleep "$POLL_SECONDS"
done

if [[ "$ledger_count" != "4" ]]; then
  printf 'Expected four canonical ledger entries for order %s, found %s\n' \
    "$order_id" "$ledger_count" >&2
  exit 1
fi

marker_count="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d settlement_db -At \
  -c "SELECT count(*) FROM transactions WHERE order_id = $order_id AND entity_type = 'SYSTEM' AND reason = 'PLATFORM_COMMISSION' AND direction = 'CREDIT';")"
[[ "$marker_count" == "1" ]] || { printf '%s\n' "Missing unique platform completion marker" >&2; exit 1; }

step "replay delivery.completed and verify idempotency"
payload="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d delivery_db -At \
  -c "SELECT payload FROM outbox_events WHERE aggregate_id = '$delivery_id' AND topic = 'delivery.completed' ORDER BY id DESC LIMIT 1;")"
[[ -n "$payload" ]] || { printf '%s\n' "Missing delivery.completed outbox payload" >&2; exit 1; }

printf '%s:%s\n' "$delivery_id" "$payload" | "${COMPOSE_COMMAND[@]}" exec -T kafka \
  kafka-console-producer --bootstrap-server kafka:9092 --topic delivery.completed \
  --property parse.key=true --property key.separator=: >/dev/null
sleep 5

replay_count="$("${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d settlement_db -At \
  -c "SELECT count(*) FROM transactions WHERE order_id = $order_id;")"
[[ "$replay_count" == "4" ]] || {
  printf 'Replay changed ledger cardinality for order %s: %s\n' "$order_id" "$replay_count" >&2
  exit 1
}

step "remove happy-path shipper from the online matching pool"
curl --fail-with-body --silent --show-error -X PATCH \
  "$BASE/api/shippers/online-status?isOnline=false" \
  -H "Authorization: Bearer $shipper_token" >/dev/null
curl --fail-with-body --silent --show-error -X POST \
  "$BASE/api/tracking/shipper-locations/offline" \
  -H "Authorization: Bearer $shipper_token" >/dev/null

printf 'MVP COD flow passed: order=%s delivery=%s, four ledger entries, duplicate replay unchanged.\n' \
  "$order_id" "$delivery_id"
