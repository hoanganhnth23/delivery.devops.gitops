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

SUITE=tier2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

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
SLOW_SCENARIOS="S06"; [ "${TIER2_SKIP_SLOW:-false}" = true ] || SLOW_SCENARIOS=""
ONLY_SCENARIOS="${TIER2_ONLY:-}"
run_scenarios "Tier 2" S03:s03 S10:s10 S04:s04 S11:s11 S07:s07 S05+S09:s05_s09 S08:s08 S06:s06
exit $?
