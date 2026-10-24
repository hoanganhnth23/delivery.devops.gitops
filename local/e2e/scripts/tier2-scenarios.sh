#!/usr/bin/env bash
# Tier-2 business-branch scenarios (catalog: docs/plans/active/full-e2e-local-stack.md).
#
# Each scenario places its own order, controls which seeded shippers are online,
# and leaves every order it created in a terminal state. A failing scenario is
# reported and the next one still runs. S12/S13 are covered by the golden flow
# (verify-mvp-cod-flow.sh); S01/S02 depend on feature flags that are off.
#
#   TIER2_ONLY        space-separated subset, e.g. "S05 S08"
#   TIER2_SKIP_SLOW   true to skip S06 (waits out the real 180 s offer window)
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8079}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# COMPOSE_FILE (absolute paths) lets a run layer overrides on the stack.
if [ -n "${COMPOSE_FILE:-}" ]; then
  COMPOSE_COMMAND=(docker compose -p "${E2E_PROJECT:-delivery-e2e}")
else
  COMPOSE_COMMAND=(docker compose -f "$SCRIPT_DIR/../docker-compose.yml" -p "${E2E_PROJECT:-delivery-e2e}")
fi
OFFER_WINDOW_SECONDS=180   # match-service SingleOfferPolicy.WAITING_TIMEOUT_SECONDS

seed_result="$(mktemp)"
trap 'rm -f "$seed_result"' EXIT
echo "[tier2] seed customer, outsider, restaurant and 3 shippers"
env SEED_OUTPUT_FILE="$seed_result" SEED_SHIPPER_COUNT=3 BASE="$BASE" \
  bash "$SCRIPT_DIR/seed.sh" >/dev/null || { echo "[tier2] seed failed" >&2; exit 1; }

CUSTOMER="$(jq -er .customerToken "$seed_result")"
OWNER="$(jq -er .ownerToken "$seed_result")"
REST_ID="$(jq -er .restaurantId "$seed_result")"
MENU_ID="$(jq -er .menuItemId "$seed_result")"
CUST_LAT="$(jq -er .customerLat "$seed_result")"
CUST_LNG="$(jq -er .customerLng "$seed_result")"
SHIP_TOKEN=(); SHIP_ID=(); SHIP_LAT=(); SHIP_LNG=()
while IFS=$'\t' read -r token id lat lng; do
  SHIP_TOKEN+=("$token"); SHIP_ID+=("$id"); SHIP_LAT+=("$lat"); SHIP_LNG+=("$lng")
done < <(jq -r '.shippers[] | [.token, .shipperId, .lat, .lng] | @tsv' "$seed_result")
[ "${#SHIP_TOKEN[@]}" -eq 3 ] || { echo "[tier2] expected 3 seeded shippers" >&2; exit 1; }
CUSTOMER_EMAIL="$(jq -er .customerEmail "$seed_result")"
OWNER_EMAIL="$(jq -er .ownerEmail "$seed_result")"
SHIP_EMAIL=(); while IFS= read -r e; do SHIP_EMAIL+=("$e"); done < <(jq -r '.shippers[].email' "$seed_result")

# Access tokens live 15 minutes and a full tier-2 run is longer: log in again
# (real password login through the Gateway) once the current set is 10 minutes old.
TOKENS_AT=$SECONDS
login() { # email -> access token
  curl -sS -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$1" --arg p "${PASS:-Password123!}" \
      '{email:$e,password:$p,deviceId:"tier2",deviceName:"E2E tier2",deviceType:"WEB"}')" \
    | jq -r '.accessToken // .data.accessToken // empty'
}
refresh_tokens() {
  (( SECONDS - TOKENS_AT < 600 )) && return 0
  local i t
  t="$(login "$CUSTOMER_EMAIL")"; [ -n "$t" ] && CUSTOMER="$t"
  t="$(login "$OWNER_EMAIL")"; [ -n "$t" ] && OWNER="$t"
  for i in 0 1 2; do t="$(login "${SHIP_EMAIL[$i]}")"; [ -n "$t" ] && SHIP_TOKEN[$i]="$t"; done
  TOKENS_AT=$SECONDS
  echo "[tier2] access tokens refreshed"
}

# ---------------------------------------------------------------- helpers
SCENARIO=""
log()  { printf '  [%s] %s\n' "$SCENARIO" "$*"; }
fail() { printf '  [%s] FAIL: %s\n' "$SCENARIO" "$*" >&2; exit 1; }  # scenarios run in a subshell

EXTRA_HEADERS=()
req() { # METHOD PATH TOKEN [JSON] -> CODE, BODY
  local args=(-sS -X "$1" "$BASE$2" -H "Authorization: Bearer $3" -w $'\n%{http_code}')
  [ $# -ge 4 ] && args+=(-H 'Content-Type: application/json' -d "$4")
  [ ${#EXTRA_HEADERS[@]} -gt 0 ] && args+=("${EXTRA_HEADERS[@]}")
  local out; out="$(curl "${args[@]}" 2>&1)"
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
  if [ "$CODE" = 401 ] && [ -z "${REQ_RETRY:-}" ]; then
    # A rejected token is logged (it is evidence) and the actor logs in again once.
    relogin_for "$3"
    if [ -n "$FRESH" ]; then
      echo "  [${SCENARIO:-tier2}] note: HTTP 401 on $1 $2, logged in again" >&2
      REQ_RETRY=1 req "$1" "$2" "$FRESH" "${@:4}"
    fi
  fi
}
relogin_for() { # stale token -> FRESH token for the same actor (kept for later calls)
  local i t=""
  if [ "$1" = "$CUSTOMER" ]; then t="$(login "$CUSTOMER_EMAIL")"; [ -n "$t" ] && CUSTOMER="$t"
  elif [ "$1" = "$OWNER" ]; then t="$(login "$OWNER_EMAIL")"; [ -n "$t" ] && OWNER="$t"
  else
    for i in 0 1 2; do
      [ "$1" = "${SHIP_TOKEN[$i]}" ] && { t="$(login "${SHIP_EMAIL[$i]}")"; [ -n "$t" ] && SHIP_TOKEN[$i]="$t"; }
    done
  fi
  FRESH="$t"
}
expect_ok()     { [[ "$CODE" == 2* ]] || fail "$1 -> HTTP $CODE ${BODY:0:300}"; }
expect_denied() { [[ "$CODE" == 2* ]] && fail "$1 should be refused, got HTTP $CODE ${BODY:0:300}"; return 0; }

sql() { "${COMPOSE_COMMAND[@]}" exec -T postgres psql -U postgres -d "$1" -At -c "$2"; }
case_status()     { sql saga_db "SELECT status FROM saga_instances WHERE order_id = $1 AND saga_type = 'ORDER_CREATION' ORDER BY created_at DESC LIMIT 1;"; }
case_shipper()    { sql saga_db "SELECT shipper_id FROM saga_instances WHERE order_id = $1 AND saga_type = 'ORDER_CREATION' ORDER BY created_at DESC LIMIT 1;"; }
delivery_status() { sql delivery_db "SELECT status FROM deliveries WHERE order_id = $1 ORDER BY id DESC LIMIT 1;"; }

order_body() { # [quoteId]
  jq -nc --argjson r "$REST_ID" --argjson m "$MENU_ID" --argjson lat "$CUST_LAT" --argjson lng "$CUST_LNG" \
    --arg q "${1:-}" \
    '{restaurantId:$r, deliveryAddress:"45 Nguyễn Trãi, Hà Đông", deliveryLat:$lat, deliveryLng:$lng,
      customerName:"Khách Tier2", customerPhone:"0900000001", paymentMethod:"COD",
      items:[{menuItemId:$m, quantity:1}]} + (if $q == "" then {} else {quoteId:$q} end)'
}
new_order() { # -> ORDER
  req POST /api/orders "$CUSTOMER" "$(order_body)"; expect_ok "create order"
  ORDER="$(jq -r '.data.id // empty' <<<"$BODY")"
  [[ "$ORDER" =~ ^[0-9]+$ ]] || fail "order response had no id: ${BODY:0:300}"
  log "order $ORDER created"
}
confirm() {
  req POST "/api/restaurants/orders/$1/confirm" "$OWNER" "{\"restaurantId\":$REST_ID,\"estimatedPrepTime\":15}"
  expect_ok "restaurant confirms $1"
}
cancel() { req PUT "/api/orders/$1/cancel" "$CUSTOMER" '{"reason":"e2e tier2"}'; }

order_status() { req GET "/api/orders/$1" "$CUSTOMER"; STATUS="$(jq -r '.data.status // empty' <<<"$BODY" 2>/dev/null)"; }
wait_status() { # ORDER REGEX SECONDS
  local deadline=$((SECONDS + $3))
  while (( SECONDS < deadline )); do
    order_status "$1"; [[ "$STATUS" =~ ^($2)$ ]] && return 0; sleep 2
  done
  fail "order $1 expected status $2 within $3s, last=${STATUS:-<empty>}"
}

offer_of() { # SHIPPER_INDEX -> OFFER_ORDER, OFFER_DELIVERY (empty when no live offer)
  req GET /api/deliveries/offers/current "${SHIP_TOKEN[$1]}"
  OFFER_ORDER="$(jq -r 'select(.data.status? == "WAIT_SHIPPER_CONFIRM") | .data.orderId // empty' <<<"$BODY" 2>/dev/null)"
  OFFER_DELIVERY="$(jq -r 'select(.data.status? == "WAIT_SHIPPER_CONFIRM") | .data.deliveryId // empty' <<<"$BODY" 2>/dev/null)"
}
wait_offer() { # ORDER SECONDS SHIPPER_INDEX... -> OFFERED (index), OFFER_DELIVERY
  local order="$1" deadline=$((SECONDS + $2)) i; shift 2
  while (( SECONDS < deadline )); do
    for i in "$@"; do
      offer_of "$i"; [ "$OFFER_ORDER" = "$order" ] && { OFFERED="$i"; log "order $order offered to shipper#$i"; return 0; }
    done
    sleep 2
  done
  fail "order $order was not offered to any of shippers [$*] within the wait"
}
never_offered() { # ORDER SECONDS SHIPPER_INDEX...
  local order="$1" deadline=$((SECONDS + $2)) i; shift 2
  while (( SECONDS < deadline )); do
    for i in "$@"; do
      offer_of "$i"; [ "$OFFER_ORDER" = "$order" ] && fail "order $order was offered to shipper#$i"
    done
    sleep 2
  done
}
respond() { # SHIPPER_INDEX ORDER ACCEPT|REJECT
  local i="$1" body
  if [ "$3" = ACCEPT ]; then
    body="{\"orderId\":$2,\"action\":\"ACCEPT\",\"currentLat\":${SHIP_LAT[$i]},\"currentLng\":${SHIP_LNG[$i]}}"
  else
    body="{\"orderId\":$2,\"action\":\"REJECT\",\"rejectReason\":\"e2e tier2\",\"notes\":\"e2e tier2\"}"
  fi
  req POST /api/deliveries/accept "${SHIP_TOKEN[$i]}" "$body"
}
finish() { # SHIPPER_INDEX DELIVERY ORDER
  local s
  for s in PICKED_UP DELIVERING DELIVERED; do
    req PUT "/api/deliveries/$2/status?status=$s" "${SHIP_TOKEN[$1]}"; expect_ok "shipper#$1 marks $s"
  done
  wait_status "$3" DELIVERED 90
}
online() { # SHIPPER_INDEX true|false
  local i="$1"
  req PATCH "/api/shippers/online-status?isOnline=$2" "${SHIP_TOKEN[$i]}"; expect_ok "shipper#$i online=$2"
  if [ "$2" = true ]; then
    req POST /api/tracking/shipper-locations/update "${SHIP_TOKEN[$i]}" \
      "{\"latitude\":${SHIP_LAT[$i]},\"longitude\":${SHIP_LNG[$i]},\"isOnline\":true}"
  else
    req POST /api/tracking/shipper-locations/offline "${SHIP_TOKEN[$i]}"
  fi
  expect_ok "shipper#$i location online=$2"
}
only_online() { # SHIPPER_INDEX... (none = everybody offline)
  local i want
  for i in 0 1 2; do
    want=false; for want_i in "$@"; do [ "$want_i" = "$i" ] && want=true; done
    online "$i" "$want"
  done
  sleep 3   # let the location projection reach match-service
}

# -------------------------------------------------------------- scenarios
s03() { # same Idempotency-Key twice -> one order
  only_online
  req POST /api/orders/checkout-preview "$CUSTOMER" "$(jq -nc --argjson r "$REST_ID" --argjson m "$MENU_ID" \
    --argjson lat "$CUST_LAT" --argjson lng "$CUST_LNG" \
    '{restaurantId:$r, deliveryLat:$lat, deliveryLng:$lng, items:[{menuItemId:$m, quantity:1}]}')"
  expect_ok "checkout preview"
  local quote key first second
  quote="$(jq -r '.data.quoteId // empty' <<<"$BODY")"; [ -n "$quote" ] || fail "preview had no quoteId"
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  EXTRA_HEADERS=(-H "Idempotency-Key: $key")
  req POST /api/orders "$CUSTOMER" "$(order_body "$quote")"; expect_ok "first create"
  first="$(jq -r '.data.id' <<<"$BODY")"
  req POST /api/orders "$CUSTOMER" "$(order_body "$quote")"; expect_ok "retry with same key"
  second="$(jq -r '.data.id' <<<"$BODY")"
  EXTRA_HEADERS=()
  [ "$first" = "$second" ] || fail "same key produced two orders: $first and $second"
  [ "$(sql order_db "SELECT count(*) FROM orders WHERE id IN ($first, $second);")" = 1 ] || fail "order rows differ"
  log "both calls returned order $first"
  cancel "$first"; expect_ok "cancel $first"; wait_status "$first" CANCELLED 30
}

s10() { # customer cancels before the restaurant confirms
  only_online 0
  new_order; cancel "$ORDER"; expect_ok "customer cancels"
  wait_status "$ORDER" CANCELLED 30
  confirm_attempt="$(req POST "/api/restaurants/orders/$ORDER/confirm" "$OWNER" \
    "{\"restaurantId\":$REST_ID,\"estimatedPrepTime\":15}"; echo "$CODE")"
  [[ "$confirm_attempt" == 2* ]] && fail "restaurant could confirm a cancelled order"
  never_offered "$ORDER" 15 0
  log "cancelled cleanly; confirm refused ($confirm_attempt); no shipper offer"
}

s04() { # restaurant rejects -> order cancelled, nobody is searched for
  only_online 0
  new_order
  req POST "/api/restaurants/orders/$ORDER/reject" "$OWNER" "{\"restaurantId\":$REST_ID,\"reason\":\"Hết món\"}"
  expect_ok "restaurant rejects"
  wait_status "$ORDER" CANCELLED 60
  never_offered "$ORDER" 15 0
  log "dispatch case=$(case_status "$ORDER")"
}

s11() { # customer cancels while dispatch is searching -> nobody gets assigned
  only_online
  new_order; confirm "$ORDER"
  wait_status "$ORDER" FINDING_SHIPPER 60
  cancel "$ORDER"; expect_ok "customer cancels during matching"
  wait_status "$ORDER" CANCELLED 60
  only_online 0
  never_offered "$ORDER" 20 0
  local c; c="$(case_status "$ORDER")"
  [[ "$c" =~ ^(CANCELLED|FAILED)$ ]] || fail "dispatch case still $c after cancel"
  log "matching stopped; dispatch case=$c"
}

s07() { # the only candidate rejects -> no one left -> SHIPPER_NOT_FOUND everywhere
  only_online 0
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 0
  respond 0 "$ORDER" REJECT; expect_ok "shipper#0 rejects"
  wait_status "$ORDER" SHIPPER_NOT_FOUND 240
  local d; d="$(delivery_status "$ORDER")"
  [ "$d" = SHIPPER_NOT_FOUND ] || fail "delivery status is $d, customer sees SHIPPER_NOT_FOUND"
  log "customer + delivery both SHIPPER_NOT_FOUND; dispatch case=$(case_status "$ORDER")"
}

s05_s09() { # reject -> next shipper; rejecter is never re-offered and cannot accept late
  only_online 0 1
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 0 1; local first="$OFFERED" second=$((1 - OFFERED))
  respond "$first" "$ORDER" REJECT; expect_ok "shipper#$first rejects"
  wait_offer "$ORDER" 120 "$second"; local delivery="$OFFER_DELIVERY"
  # Order status is a projection of dispatch events: let it catch up before judging.
  wait_status "$ORDER" WAIT_SHIPPER_CONFIRM 30
  respond "$first" "$ORDER" ACCEPT; expect_denied "late accept by rejecting shipper#$first (S09)"
  local late="$CODE"
  sleep 3
  order_status "$ORDER"; [ "$STATUS" = WAIT_SHIPPER_CONFIRM ] || fail "late accept changed order to $STATUS"
  offer_of "$second"; [ "$OFFER_ORDER" = "$ORDER" ] || fail "late accept took the offer away from shipper#$second"
  respond "$second" "$ORDER" ACCEPT; expect_ok "shipper#$second accepts"
  wait_status "$ORDER" ASSIGNED 60
  [ "$(case_shipper "$ORDER")" = "${SHIP_ID[$second]}" ] || fail "dispatch assigned $(case_shipper "$ORDER"), expected ${SHIP_ID[$second]}"
  never_offered "$ORDER" 1 "$first"
  finish "$second" "$delivery" "$ORDER"
  log "rematched to shipper#$second; late accept refused (HTTP $late)"
}

s08() { # a shipper busy with an active order is not offered, and cannot take, another one
  only_online 0
  new_order; local busy="$ORDER"; confirm "$busy"
  wait_offer "$busy" 90 0; local delivery="$OFFER_DELIVERY"
  respond 0 "$busy" ACCEPT; expect_ok "shipper#0 accepts first order"
  wait_status "$busy" ASSIGNED 60
  new_order; local other="$ORDER"; confirm "$other"
  never_offered "$other" 25 0
  respond 0 "$other" ACCEPT; expect_denied "busy shipper#0 accepting a second order"
  log "busy shipper not offered order $other; direct accept refused (HTTP $CODE)"
  cancel "$other"   # best effort; otherwise it ends SHIPPER_NOT_FOUND once matching gives up
  only_online
  finish 0 "$delivery" "$busy"
  wait_status "$other" 'CANCELLED|SHIPPER_NOT_FOUND' 240
}

s06() { # offer expires unanswered -> next shipper; the silent one is excluded
  only_online 0 1
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 0 1; local silent="$OFFERED" next=$((1 - OFFERED))
  log "shipper#$silent stays silent for the ${OFFER_WINDOW_SECONDS}s offer window"
  wait_offer "$ORDER" $((OFFER_WINDOW_SECONDS + 120)) "$next"; local delivery="$OFFER_DELIVERY"
  offer_of "$silent"; [ "$OFFER_ORDER" = "$ORDER" ] && fail "expired shipper#$silent still holds the offer"
  respond "$next" "$ORDER" ACCEPT; expect_ok "shipper#$next accepts"
  wait_status "$ORDER" ASSIGNED 60
  finish "$next" "$delivery" "$ORDER"
}

# ---------------------------------------------------------------- runner
SCENARIOS=(S03:s03 S10:s10 S04:s04 S11:s11 S07:s07 S05+S09:s05_s09 S08:s08 S06:s06)
declare -a RESULTS=()
failed=0
for entry in "${SCENARIOS[@]}"; do
  id="${entry%%:*}" fn="${entry#*:}"
  if [ -n "${TIER2_ONLY:-}" ]; then
    match=false; for want in $TIER2_ONLY; do [[ "+$id+" == *"+$want+"* ]] && match=true; done
    $match || continue
  fi
  if [ "$id" = S06 ] && [ "${TIER2_SKIP_SLOW:-false}" = true ]; then RESULTS+=("$id SKIP (slow)"); continue; fi
  refresh_tokens
  echo "[tier2] $id"
  started=$SECONDS
  ( SCENARIO="$id"; "$fn" )
  rc=$?
  if [ $rc -eq 0 ]; then RESULTS+=("$id PASS ($((SECONDS - started))s)")
  else RESULTS+=("$id FAIL ($((SECONDS - started))s)"); failed=$((failed + 1))
    ( SCENARIO="$id cleanup"; only_online ) >/dev/null 2>&1 || true
  fi
done

echo
echo "[tier2] results"
printf '  %s\n' "${RESULTS[@]}"
[ "$failed" -eq 0 ] && echo "Tier 2 passed." || echo "Tier 2: $failed scenario(s) failed."
exit $(( failed > 0 ))
