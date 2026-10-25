#!/usr/bin/env bash
# Tier-2 business-branch scenarios (catalog: docs/plans/active/full-e2e-local-stack.md).
#
# Each scenario places its own order, controls which seeded shippers are online,
# and leaves every order it created in a terminal state. A failing scenario is
# reported and the next one still runs. S12/S13 are covered by the golden flow
# (verify-mvp-cod-flow.sh); S01/S02/S16/S18 need flags that staging keeps off and
# run in tier2-capabilities.sh. S15 shipper cancels after accepting, S17 customer
# cancels after a shipper accepted, S19 admin blocks an account.
#
#   TIER2_ONLY        space-separated subset, e.g. "S05 S08"
#   TIER2_SKIP_SLOW   true to skip S06/S14 (they wait out real offer windows)
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
  local first="$ORDER"
  # While the first order keeps searching, a new order must still be matched
  # promptly (regression: match held the Kafka record and stalled every order).
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 60 0
  order_status "$first"; log "order $first is $STATUS while order $ORDER got its offer"
  respond 0 "$ORDER" REJECT; expect_ok "shipper#0 rejects the second order"
  # Rematch budget is fixed in dispatch (5 tries, 15 s x1.5 ~ 200 s) plus match
  # scheduling lag; wait it out so the search does not leak into later scenarios.
  local o d
  for o in "$first" "$ORDER"; do
    wait_status "$o" SHIPPER_NOT_FOUND 420
    d="$(delivery_status "$o")"
    [ "$d" = SHIPPER_NOT_FOUND ] || fail "order $o: delivery status is $d, customer sees SHIPPER_NOT_FOUND"
  done
  log "both orders searched in parallel; customer + delivery SHIPPER_NOT_FOUND; dispatch case=$(case_status "$first")"
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

s14() { # two shippers ignore the offer in turn -> the third still gets it (Uber-style: short offers, keep searching)
  only_online 0 1 2
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 0 1 2; local first="$OFFERED"
  log "shipper#$first stays silent"
  local rest=() i; for i in 0 1 2; do [ "$i" = "$first" ] || rest+=("$i"); done
  wait_offer "$ORDER" $((OFFER_WINDOW_SECONDS + 90)) "${rest[@]}"; local second="$OFFERED"
  offer_of "$first"; [ "$OFFER_ORDER" = "$ORDER" ] && fail "silent shipper#$first still holds the offer"
  log "shipper#$second stays silent too"
  local third; for i in "${rest[@]}"; do [ "$i" = "$second" ] || third="$i"; done
  wait_offer "$ORDER" $((OFFER_WINDOW_SECONDS + 90)) "$third"; local delivery="$OFFER_DELIVERY"
  order_status "$ORDER"; [ "$STATUS" = SHIPPER_NOT_FOUND ] && fail "order gave up after two silent shippers"
  respond "$third" "$ORDER" ACCEPT; expect_ok "shipper#$third accepts after two silent offers"
  wait_status "$ORDER" ASSIGNED 60
  finish "$third" "$delivery" "$ORDER"
}

s15() { # shipper cancels after accepting -> back to searching, the canceller is never re-offered
  only_online 0 1
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 90 0 1; local first="$OFFERED" second=$((1 - OFFERED))
  respond "$first" "$ORDER" ACCEPT; expect_ok "shipper#$first accepts"
  wait_status "$ORDER" ASSIGNED 60
  req POST /api/deliveries/cancel-assignment "${SHIP_TOKEN[$second]}" "{\"orderId\":$ORDER,\"reason\":\"e2e not mine\"}"
  expect_denied "shipper#$second cancelling an order assigned to shipper#$first"
  req POST /api/deliveries/cancel-assignment "${SHIP_TOKEN[$first]}" "{\"orderId\":$ORDER,\"reason\":\"Xe hỏng\"}"
  expect_ok "shipper#$first cancels the accepted order"
  wait_offer "$ORDER" 120 "$second"; local delivery="$OFFER_DELIVERY"
  offer_of "$first"; [ "$OFFER_ORDER" = "$ORDER" ] && fail "the cancelling shipper#$first was offered the order again"
  respond "$first" "$ORDER" ACCEPT; expect_denied "the cancelling shipper#$first accepting again"
  respond "$second" "$ORDER" ACCEPT; expect_ok "shipper#$second accepts"
  wait_status "$ORDER" ASSIGNED 60
  [ "$(case_shipper "$ORDER")" = "${SHIP_ID[$second]}" ] || fail "dispatch assigned $(case_shipper "$ORDER"), expected ${SHIP_ID[$second]}"
  req PUT "/api/deliveries/$delivery/status?status=PICKED_UP" "${SHIP_TOKEN[$second]}"; expect_ok "shipper#$second picks up"
  req POST /api/deliveries/cancel-assignment "${SHIP_TOKEN[$second]}" "{\"orderId\":$ORDER,\"reason\":\"too late\"}"
  expect_denied "cancelling after pick-up"
  local s; for s in DELIVERING DELIVERED; do
    req PUT "/api/deliveries/$delivery/status?status=$s" "${SHIP_TOKEN[$second]}"; expect_ok "shipper#$second marks $s"
  done
  wait_status "$ORDER" DELIVERED 90
  log "rematched to shipper#$second after shipper#$first cancelled; cancel after pick-up refused"
}

s17() { # customer cancels after a shipper accepted -> delivery cancelled, shipper free again; not after pick-up
  only_online 0
  new_order; local first="$ORDER"; confirm "$first"
  wait_offer "$first" 90 0; local old_delivery="$OFFER_DELIVERY"
  respond 0 "$first" ACCEPT; expect_ok "shipper#0 accepts"
  wait_status "$first" ASSIGNED 60
  cancel "$first"; expect_ok "customer cancels an ASSIGNED order"
  # Delivery holds the pickup as soon as it admits the cancel, before order.cancelled lands.
  req PUT "/api/deliveries/$old_delivery/status?status=PICKED_UP" "${SHIP_TOKEN[0]}"
  expect_denied "shipper picking up right after the customer cancelled"
  wait_status "$first" CANCELLED 60
  local deadline=$((SECONDS + 60)) d
  while (( SECONDS < deadline )); do d="$(delivery_status "$first")"; [ "$d" = CANCELLED ] && break; sleep 2; done
  [ "$d" = CANCELLED ] || fail "delivery of cancelled order is $d"
  req PUT "/api/deliveries/$old_delivery/status?status=PICKED_UP" "${SHIP_TOKEN[0]}"
  expect_denied "shipper picking up a cancelled delivery"
  log "order $first cancelled while ASSIGNED; delivery CANCELLED; pick-up refused (HTTP $CODE)"

  new_order; local second="$ORDER"; confirm "$second"
  wait_offer "$second" 90 0; local delivery="$OFFER_DELIVERY"   # freed shipper gets the next order
  respond 0 "$second" ACCEPT; expect_ok "freed shipper#0 accepts the next order"
  wait_status "$second" ASSIGNED 60
  req PUT "/api/deliveries/$delivery/status?status=PICKED_UP" "${SHIP_TOKEN[0]}"; expect_ok "shipper#0 picks up"
  # No wait: Order still believes ASSIGNED here; Delivery (the authority) must refuse.
  cancel "$second"; expect_denied "customer cancelling right after pick-up"
  log "cancel right after pick-up refused (HTTP $CODE) ${BODY:0:120}"
  wait_status "$second" PICKED_UP 30
  [ "$(delivery_status "$second")" = PICKED_UP ] || fail "delivery is $(delivery_status "$second") after the refused cancel"
  local s; for s in DELIVERING DELIVERED; do
    req PUT "/api/deliveries/$delivery/status?status=$s" "${SHIP_TOKEN[0]}"; expect_ok "shipper#0 marks $s"
  done
  wait_status "$second" DELIVERED 90
}

s19() { # admin blocks a customer -> login and refresh refused; unblock lets them back in
  local refresh account
  login_raw() { curl -sS -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -w $'\n%{http_code}' \
    -d "$(jq -nc --arg e "$OUTSIDER_EMAIL" --arg p "${PASS:-Password123!}" \
      '{email:$e,password:$p,deviceId:"tier2-block",deviceName:"E2E block",deviceType:"WEB"}')"; }
  local out; out="$(login_raw)"; [ "${out##*$'\n'}" = 200 ] || fail "outsider cannot log in before the block: ${out:0:200}"
  refresh="$(jq -r '.data.refreshToken // .refreshToken // empty' <<<"${out%$'\n'*}")"
  [ -n "$refresh" ] || fail "login returned no refresh token"
  account="$(sql auth_db "SELECT id FROM auth_account WHERE email = '$OUTSIDER_EMAIL';")"
  [[ "$account" =~ ^[0-9]+$ ]] || fail "no auth account for $OUTSIDER_EMAIL"

  req POST "/api/auth/admin/accounts/$account/block" "$CUSTOMER" '{"reason":"e2e"}'
  expect_denied "a customer blocking an account"
  admin_token
  req POST "/api/auth/admin/accounts/$account/block" "$ADMIN" '{"reason":"E2E: spam đơn ảo"}'; expect_ok "admin blocks account $account"

  out="$(login_raw)"; [[ "${out##*$'\n'}" == 2* ]] && fail "blocked account could still log in"
  log "blocked: login refused (HTTP ${out##*$'\n'})"
  out="$(curl -sS -X POST "$BASE/api/auth/refresh-token" -H 'Content-Type: application/json' -w $'\n%{http_code}' \
    -d "$(jq -nc --arg r "$refresh" '{refreshToken:$r}')")"
  [[ "${out##*$'\n'}" == 2* ]] && fail "refresh token of a blocked account still works"
  log "blocked: refresh refused (HTTP ${out##*$'\n'})"
  req POST /api/orders "$OUTSIDER" "$(order_body)"
  if [[ "$CODE" == 2* ]]; then
    local stray; stray="$(jq -r '.data.id // empty' <<<"$BODY")"
    log "note: the blocked customer's unexpired access token still placed order $stray (JWT lives up to 15 min)"
    req PUT "/api/orders/$stray/cancel" "$ADMIN" '{"reason":"e2e cleanup"}'
  else
    log "blocked: the old access token cannot order (HTTP $CODE)"
  fi

  req POST "/api/auth/admin/accounts/$account/unblock" "$ADMIN"; expect_ok "admin unblocks account $account"
  out="$(login_raw)"; [ "${out##*$'\n'}" = 200 ] || fail "unblocked account cannot log in: ${out:0:200}"
  log "unblocked: login works again"
}

# ---------------------------------------------------------------- runner
SLOW_SCENARIOS="S06 S14"; [ "${TIER2_SKIP_SLOW:-false}" = true ] || SLOW_SCENARIOS=""
ONLY_SCENARIOS="${TIER2_ONLY:-}"
run_scenarios "Tier 2" S03:s03 S10:s10 S04:s04 S11:s11 S07:s07 S05+S09:s05_s09 S08:s08 S06:s06 S14:s14 S15:s15 S17:s17 S19:s19
exit $?
