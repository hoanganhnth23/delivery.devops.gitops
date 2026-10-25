#!/usr/bin/env bash
# S01/S02: checkout capabilities that staging keeps off behind flags.
#   S01  delivery-zone check: no zone / zone elsewhere -> refused, zone covering
#        the customer -> preview carries the zone and the order goes through.
#   S02  stock reservation: 1 portion left -> the 2nd order is refused, cancelling
#        the 1st returns the portion and a new order succeeds.
# The script restarts restaurant/order with docker-compose.capabilities.yml and
# puts them back without it on exit, so later tiers see the normal stack.
#   TIER2C_ONLY   subset, e.g. "S02"
set -uo pipefail

SUITE=tier2c
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="${E2E_PROJECT:-delivery-e2e}"
CAP_SERVICES=(restaurant-service order-service)

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
  # Recreated containers get new IPs and the Gateway caches DNS answers, so it
  # would keep dialing the old address (Kubernetes Service IPs do not move).
  docker compose -f "$STACK_DIR/docker-compose.yml" -p "$PROJECT" restart api-gateway >/dev/null 2>&1 \
    && wait_healthy api-gateway
}
restore() { echo "[$SUITE] restore restaurant/order without the capability flags"; restart_with "" || true; }

echo "[$SUITE] restart restaurant/order with serviceability + inventory on"
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

ONLY_SCENARIOS="${TIER2C_ONLY:-}"
run_scenarios "Tier 2 (capabilities)" S01:s01 S02:s02
