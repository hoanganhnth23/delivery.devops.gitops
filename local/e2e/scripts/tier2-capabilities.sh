#!/usr/bin/env bash
# Capabilities that staging keeps off behind flags.
#   S01  delivery-zone check: no zone / zone elsewhere -> refused, zone covering
#        the customer -> preview carries the zone and the order goes through.
#   S02  stock reservation: 1 portion left -> the 2nd order is refused, cancelling
#        the 1st returns the portion and a new order succeeds.
#   S16  failed delivery after pick-up: report -> one retry -> fail again ->
#        RETURNING -> restaurant confirms RETURNED, shipper is free, settlement
#        opens a MANUAL_REVIEW case. S16R: retry then deliver -> RESOLVED.
#   S18  cancelled COD order -> refund case NO_REFUND_REQUIRED, visible to its
#        customer only.
# The script restarts those services with docker-compose.capabilities.yml and
# puts them back without it on exit, so later tiers see the normal stack.
#   TIER2C_ONLY   subset, e.g. "S02"
set -uo pipefail

SUITE=tier2c
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="${E2E_PROJECT:-delivery-e2e}"
CAP_SERVICES=(restaurant-service order-service delivery-service settlement-service)
CALLERS=(api-gateway match-service tracking-service)

wait_healthy() { # SERVICE...
  local deadline=$((SECONDS + 300)) s ok
  while (( SECONDS < deadline )); do
    ok=true
    for s in "$@"; do
      [ "$(docker compose -f "$STACK_DIR/docker-compose.yml" -p "$PROJECT" ps --format '{{.Health}}' "$s" 2>/dev/null)" = healthy ] || ok=false
    done
    $ok && return 0; sleep 3
  done
  echo "[$SUITE] $* not healthy within 300s" >&2; return 1
}
restart_with() { # extra compose file or empty
  local files=(-f "$STACK_DIR/docker-compose.yml"); [ -n "$1" ] && files+=(-f "$1")
  docker compose "${files[@]}" -p "$PROJECT" up -d --no-deps --force-recreate "${CAP_SERVICES[@]}" >/dev/null 2>&1 \
    && wait_healthy "${CAP_SERVICES[@]}" || return 1
  # Recreated containers get new IPs and the callers cache DNS answers, so they
  # would keep dialing the old address (Kubernetes Service IPs do not move):
  # the Gateway, match (-> settlement) and tracking (-> delivery).
  docker compose -f "$STACK_DIR/docker-compose.yml" -p "$PROJECT" restart "${CALLERS[@]}" >/dev/null 2>&1 \
    && wait_healthy "${CALLERS[@]}"
}
restore() { echo "[$SUITE] restore ${CAP_SERVICES[*]} without the capability flags"; restart_with "" || true; }

echo "[$SUITE] restart ${CAP_SERVICES[*]} with the capability flags on"
restart_with "$STACK_DIR/docker-compose.capabilities.yml" || { restore; exit 1; }
trap 'rm -f "${seed_result:-}"; restore' EXIT
source "$SCRIPT_DIR/lib.sh"
trap 'rm -f "${seed_result:-}"; restore' EXIT   # lib.sh installs its own EXIT trap

preview_body() {
  jq -nc --argjson r "$REST_ID" --argjson m "$MENU_ID" --argjson lat "$CUST_LAT" --argjson lng "$CUST_LNG" \
    '{restaurantId:$r, deliveryLat:$lat, deliveryLng:$lng, items:[{menuItemId:$m, quantity:1}]}'
}
box() { # LAT LNG HALF_SIDE_DEGREES -> GeoJSON Polygon string ([lng, lat], closed ring)
  jq -nc --argjson la "$1" --argjson ln "$2" --argjson d "$3" \
    '{type:"Polygon", coordinates:[[[$ln-$d,$la-$d],[$ln+$d,$la-$d],[$ln+$d,$la+$d],[$ln-$d,$la+$d],[$ln-$d,$la-$d]]]}'
}
zone_body() { # NAME POLYGON_JSON_STRING
  jq -nc --arg n "$1" --arg p "$2" '{name:$n, polygonGeoJson:$p, priority:0, active:true}'
}
inventory() { # -> ON_HAND RESERVED AVAILABLE REVISION
  req GET "/api/menu-items/$MENU_ID/inventory" "$OWNER"; expect_ok "read inventory"
  read -r ON_HAND RESERVED AVAILABLE REVISION < <(jq -r '.data | "\(.onHandQuantity) \(.reservedQuantity) \(.availableQuantity) \(.revision)"' <<<"$BODY")
}
set_stock() { # QUANTITY
  local body
  req GET "/api/menu-items/$MENU_ID/inventory" "$OWNER"
  if [[ "$CODE" == 2* ]] && [ "$(jq -r '.data.revision // empty' <<<"$BODY")" != "" ]; then
    body="$(jq -nc --argjson q "$1" --argjson r "$(jq -r .data.revision <<<"$BODY")" '{onHandQuantity:$q, expectedRevision:$r}')"
  else
    body="$(jq -nc --argjson q "$1" '{onHandQuantity:$q}')"
  fi
  req PUT "/api/menu-items/$MENU_ID/inventory" "$OWNER" "$body"; expect_ok "owner sets stock to $1"
}
wait_available() { # QUANTITY SECONDS
  local deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do inventory; [ "$AVAILABLE" = "$1" ] && return 0; sleep 2; done
  fail "available stock expected $1 within $2s, last on-hand=$ON_HAND reserved=$RESERVED available=$AVAILABLE"
}
cancel_terminal() { cancel "$1"; expect_ok "cancel order $1"; wait_status "$1" CANCELLED 60; }

# Both scenarios need the other capability satisfied: a zone over the customer
# (S02) and stock for the menu item (S01). Each sets what it needs.
ZONE_ID=""
cover_customer() {
  if [ -z "$ZONE_ID" ]; then
    req GET "/api/restaurants/$REST_ID/serviceability-zones" "$OWNER"; expect_ok "list zones"
    ZONE_ID="$(jq -r '[.data[]? | select(.name == "e2e-customer")][0].id // empty' <<<"$BODY")"
  fi
  if [ -z "$ZONE_ID" ]; then
    req POST "/api/restaurants/$REST_ID/serviceability-zones" "$OWNER" \
      "$(zone_body e2e-customer "$(box "$CUST_LAT" "$CUST_LNG" 0.02)")"; expect_ok "create covering zone"
    ZONE_ID="$(jq -r '.data.id' <<<"$BODY")"
  fi
}

# -------------------------------------------------------------- scenarios
s01() { # delivery outside every active zone is refused at preview and at create
  only_online
  set_stock 50
  req GET "/api/restaurants/$REST_ID/serviceability-zones" "$OWNER"; expect_ok "list zones"
  [ "$(jq -r '[.data[]? | select(.active == true)] | length' <<<"$BODY")" = 0 ] || fail "fresh restaurant already has zones"

  req POST /api/orders/checkout-preview "$CUSTOMER" "$(preview_body)"
  expect_denied "preview with no zone"; log "no zone: preview refused (HTTP $CODE) ${BODY:0:160}"
  req POST /api/orders "$CUSTOMER" "$(order_body)"
  expect_denied "create with no zone"; log "no zone: create refused (HTTP $CODE)"

  # A zone that exists but lies ~11 km away from the customer.
  req POST "/api/restaurants/$REST_ID/serviceability-zones" "$OWNER" \
    "$(zone_body e2e-elsewhere "$(box "$(jq -n "$CUST_LAT + 0.1")" "$CUST_LNG" 0.02)")"; expect_ok "create distant zone"
  local far; far="$(jq -r '.data.id' <<<"$BODY")"
  req POST /api/orders/checkout-preview "$CUSTOMER" "$(preview_body)"
  expect_denied "preview outside the zone"
  grep -qi "outside the service area\|ngoài vùng phục vụ" <<<"$BODY" || fail "refusal does not say outside the zone: ${BODY:0:300}"
  log "zone elsewhere: preview refused as outside the service area"
  req POST /api/orders "$CUSTOMER" "$(order_body)"
  expect_denied "create outside the zone"; log "zone elsewhere: create refused (HTTP $CODE)"

  cover_customer
  req POST /api/orders/checkout-preview "$CUSTOMER" "$(preview_body)"; expect_ok "preview inside the zone"
  [ "$(jq -r '.data.serviceabilityZoneId // empty' <<<"$BODY")" = "$ZONE_ID" ] \
    || fail "preview did not carry the covering zone $ZONE_ID: ${BODY:0:300}"
  local quote; quote="$(jq -r '.data.quoteId' <<<"$BODY")"
  EXTRA_HEADERS=(-H "Idempotency-Key: $(uuidgen | tr '[:upper:]' '[:lower:]')")
  req POST /api/orders "$CUSTOMER" "$(order_body "$quote")"; EXTRA_HEADERS=(); expect_ok "create inside the zone"
  local order; order="$(jq -r '.data.id' <<<"$BODY")"
  log "inside zone $ZONE_ID: order $order created"
  cancel_terminal "$order"
  req DELETE "/api/restaurants/$REST_ID/serviceability-zones/$far" "$OWNER"; expect_ok "delete distant zone"
}

s02() { # last portion: 2nd order refused, cancelling returns the portion
  only_online
  cover_customer
  set_stock 1
  wait_available 1 10
  new_order; local first="$ORDER"
  wait_available 0 30; log "order $first holds the last portion (reserved=$RESERVED)"

  req POST /api/orders "$CUSTOMER" "$(order_body)"
  expect_denied "order with no stock left"
  log "no stock: second order refused (HTTP $CODE) ${BODY:0:160}"
  local orders; orders="$(sql order_db "SELECT count(*) FROM orders WHERE restaurant_id = $REST_ID AND created_at > now() - interval '2 minutes' AND id > $first;")"
  [ "$orders" = 0 ] || fail "a refused order still left $orders row(s) behind"

  cancel_terminal "$first"
  wait_available 1 60; log "cancel returned the portion (available=$AVAILABLE)"
  new_order; local third="$ORDER"
  wait_available 0 30
  cancel_terminal "$third"
  wait_available 1 60
  [ "$ON_HAND" = 1 ] || fail "on-hand changed to $ON_HAND although nothing was sold"
}

assigned_order() { # SHIPPER_INDEX -> ORDER, DELIVERY (accepted and picked up)
  only_online "$1"
  cover_customer; set_stock 50
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 "$1"; DELIVERY="$OFFER_DELIVERY"
  respond "$1" "$ORDER" ACCEPT; expect_ok "shipper#$1 accepts"
  wait_status "$ORDER" ASSIGNED 60
}
exception() { # SHIPPER_INDEX ACTION [JSON] -> EXC (exception status)
  local path="/api/deliveries/$DELIVERY/exceptions/$2"
  if [ $# -ge 3 ]; then req POST "$path" "${SHIP_TOKEN[$1]}" "$3"; else req POST "$path" "${SHIP_TOKEN[$1]}"; fi
  EXC="$(jq -r '.data.status // empty' <<<"$BODY" 2>/dev/null)"
}
refund_case() { # ORDER SECONDS -> REFUND ("trigger status") once settlement has a case
  local deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do
    REFUND="$(sql settlement_db "SELECT refund_trigger || ' ' || status FROM refund_cases WHERE order_id = $1 ORDER BY created_at DESC LIMIT 1;")"
    [ -n "$REFUND" ] && return 0; sleep 2
  done
  fail "settlement opened no refund case for order $1 within $2s"
}

s16() { # failed delivery -> one retry -> fails again -> returned to the restaurant
  local reason='{"reason":"Khách không nghe máy"}'
  assigned_order 0
  exception 0 failed "$reason"; expect_denied "reporting a failure before pick-up"
  local s; for s in PICKED_UP DELIVERING; do
    req PUT "/api/deliveries/$DELIVERY/status?status=$s" "${SHIP_TOKEN[0]}"; expect_ok "shipper#0 marks $s"
  done
  exception 1 failed "$reason"; expect_denied "another shipper reporting this delivery"
  exception 0 failed "$reason"; expect_ok "shipper#0 reports the failure"
  [ "$EXC" = RETRY_AVAILABLE ] || fail "first report should leave a retry, got $EXC"
  exception 0 failed '{"reason":"Lý do khác"}'; expect_denied "a second report with a different reason"
  exception 0 retry; expect_ok "shipper#0 uses the retry"; [ "$EXC" = RETRY_USED ] || fail "retry gave $EXC"
  exception 0 failed "$reason"; expect_ok "shipper#0 reports the second failure"
  [ "$EXC" = RETURNING ] || fail "second failure should start the return, got $EXC"
  [ "$(delivery_status "$ORDER")" = RETURNING ] || fail "delivery is $(delivery_status "$ORDER"), expected RETURNING"
  req GET "/api/deliveries/$DELIVERY/exception" "$CUSTOMER"; expect_ok "customer reads the exception"
  [ "$(jq -r .data.status <<<"$BODY")" = RETURNING ] || fail "customer sees ${BODY:0:200}"
  req GET "/api/deliveries/$DELIVERY/exception" "$OUTSIDER"; expect_denied "an unrelated customer reading the exception"
  log "order $ORDER: RETRY_AVAILABLE -> RETRY_USED -> RETURNING"

  req POST "/api/deliveries/$DELIVERY/exceptions/return/confirm" "${SHIP_TOKEN[0]}"; expect_denied "shipper confirming the return"
  req POST "/api/deliveries/$DELIVERY/exceptions/return/confirm" "$OWNER"; expect_ok "restaurant confirms the return"
  [ "$(jq -r .data.status <<<"$BODY")" = RETURNED ] || fail "confirm gave ${BODY:0:200}"
  [ "$(delivery_status "$ORDER")" = RETURNED ] || fail "delivery is $(delivery_status "$ORDER"), expected RETURNED"
  # Order has no "returned" state and does not consume the exception events (open
  # product question, see the plan): record what the customer sees, do not judge it.
  sleep 3; order_status "$ORDER"; log "returned; customer still sees order status $STATUS"
  refund_case "$ORDER" 60
  [ "$REFUND" = "DELIVERY_DISPUTE MANUAL_REVIEW" ] || fail "refund case is '$REFUND', expected DELIVERY_DISPUTE MANUAL_REVIEW"
  log "settlement: $REFUND"

  local returned="$ORDER"
  assigned_order 0   # the shipper is free again once the food is back
  log "shipper#0 took order $ORDER after returning $returned"
  cancel "$ORDER"; expect_ok "customer cancels the follow-up order"; wait_status "$ORDER" CANCELLED 60
}

s16r() { # failed attempt, retry, delivered -> exception RESOLVED
  assigned_order 0
  local s; for s in PICKED_UP DELIVERING; do
    req PUT "/api/deliveries/$DELIVERY/status?status=$s" "${SHIP_TOKEN[0]}"; expect_ok "shipper#0 marks $s"
  done
  exception 0 failed '{"reason":"Sai địa chỉ"}'; expect_ok "report"; [ "$EXC" = RETRY_AVAILABLE ] || fail "report gave $EXC"
  exception 0 retry; expect_ok "retry"
  req PUT "/api/deliveries/$DELIVERY/status?status=DELIVERED" "${SHIP_TOKEN[0]}"; expect_ok "delivered on the retry"
  wait_status "$ORDER" DELIVERED 90
  req GET "/api/deliveries/$DELIVERY/exception" "$CUSTOMER"; expect_ok "read exception"
  [ "$(jq -r .data.status <<<"$BODY")" = RESOLVED ] || fail "exception after delivery is ${BODY:0:200}"
  log "delivered on the retry; exception RESOLVED"
}

s18() { # cancelled COD order -> refund case NO_REFUND_REQUIRED, only its customer sees it
  only_online
  cover_customer; set_stock 50
  new_order; cancel_terminal "$ORDER"
  refund_case "$ORDER" 60
  [ "$REFUND" = "ORDER_CANCELLED NO_REFUND_REQUIRED" ] || fail "refund case is '$REFUND'"
  req GET "/api/settlement/refunds/my?limit=20" "$CUSTOMER"; expect_ok "customer lists refunds"
  local mine; mine="$(jq -r --argjson o "$ORDER" '[.data[]? | select(.orderId == $o)][0] | "\(.status) \(.refundAmount)"' <<<"$BODY")"
  [[ "$mine" =~ ^NO_REFUND_REQUIRED\ 0(\.0+)?$ ]] || fail "customer view of the case: '$mine' (${BODY:0:300})"
  req GET "/api/settlement/refunds/my?limit=50" "$OUTSIDER"; expect_ok "outsider lists refunds"
  [ "$(jq --argjson o "$ORDER" '[.data[]? | select(.orderId == $o)] | length' <<<"$BODY")" = 0 ] \
    || fail "an unrelated customer can see order $ORDER's refund case"
  log "order $ORDER: $REFUND, amount 0, hidden from other customers"
}

ONLY_SCENARIOS="${TIER2C_ONLY:-}"
run_scenarios "Tier 2 (capabilities)" S01:s01 S02:s02 S16:s16 S16R:s16r S18:s18
