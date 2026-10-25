#!/usr/bin/env bash
# Tier-3 infrastructure-fault scenarios (catalog: docs/plans/active/full-e2e-local-stack.md).
#
#   R01  dispatch is killed (SIGKILL) twice mid-order; the order still completes
#   R02  old, duplicate and out-of-order Kafka events are re-published from the
#        services' own outboxes; nothing changes and the live order still completes
#
#   TIER3_ONLY  space-separated subset, e.g. "R02"
set -uo pipefail

SUITE=tier3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DISPATCH=saga-orchestrator-service

dispatch_crash() { # SECONDS_DOWN: SIGKILL dispatch (no graceful shutdown), then start it again
  "${COMPOSE_COMMAND[@]}" kill -s SIGKILL "$DISPATCH" >/dev/null 2>&1 || fail "could not kill dispatch"
  log "dispatch killed"
  sleep "$1"
  "${COMPOSE_COMMAND[@]}" start "$DISPATCH" >/dev/null 2>&1 || fail "could not start dispatch"
  dispatch_wait_healthy
}

wait_case() { # ORDER REGEX SECONDS
  local deadline=$((SECONDS + $3)) c=""
  while (( SECONDS < deadline )); do
    c="$(case_status "$1")"; [[ "$c" =~ ^($2)$ ]] && return 0; sleep 2
  done
  fail "dispatch case for order $1 expected $2, last=${c:-<none>}"
}

# Re-publish an event a service already emitted, exactly as stored in its outbox.
replay() { # DB TABLE TOPIC AGGREGATE_ID [first|last]
  local order="ASC"; [ "${5:-first}" = last ] && order="DESC"
  local row key payload
  row="$(sql "$1" "SELECT coalesce(event_key, aggregate_id) || chr(9) || payload FROM $2
    WHERE topic = '$3' AND aggregate_id = '$4' ORDER BY id $order LIMIT 1;")"
  [ -n "$row" ] || fail "no $3 event for aggregate $4 in $1.$2"
  key="${row%%$'\t'*}"; payload="${row#*$'\t'}"
  printf '%s\t%s\n' "$key" "$payload" | "${COMPOSE_COMMAND[@]}" exec -T kafka \
    kafka-console-producer --bootstrap-server kafka:9092 --topic "$3" \
    --property parse.key=true --property "key.separator=$(printf '\t')" >/dev/null \
    || fail "could not publish $3"
  log "replayed ${5:-first} $3 (aggregate $4)"
}

snapshot() { # ORDER DELIVERY -> one line describing every service's view
  printf 'order=%s delivery=%s case=%s shipper=%s cases=%s ledger=%s' \
    "$(sql order_db "SELECT status FROM orders WHERE id = $1;")" \
    "$(sql delivery_db "SELECT status FROM deliveries WHERE id = $2;")" \
    "$(case_status "$1")" "$(case_shipper "$1")" \
    "$(sql saga_db "SELECT count(*) FROM saga_instances WHERE order_id = $1;")" \
    "$(sql settlement_db "SELECT count(*) FROM transactions WHERE order_id = $1;")"
}

# ------------------------------------------------------------- scenarios
r01() { # dispatch crashes before matching and again after assignment
  only_online 0
  new_order; confirm "$ORDER"
  dispatch_crash 10                       # down while the order waits for matching
  wait_offer "$ORDER" 180 0; local delivery="$OFFER_DELIVERY"
  respond 0 "$ORDER" ACCEPT; expect_ok "shipper#0 accepts"
  wait_status "$ORDER" ASSIGNED 60
  "${COMPOSE_COMMAND[@]}" kill -s SIGKILL "$DISPATCH" >/dev/null 2>&1 || fail "could not kill dispatch"
  log "dispatch killed while the shipper delivers"
  req PUT "/api/deliveries/$delivery/status?status=PICKED_UP" "${SHIP_TOKEN[0]}"; expect_ok "PICKED_UP with dispatch down"
  req PUT "/api/deliveries/$delivery/status?status=DELIVERING" "${SHIP_TOKEN[0]}"; expect_ok "DELIVERING with dispatch down"
  "${COMPOSE_COMMAND[@]}" start "$DISPATCH" >/dev/null 2>&1; dispatch_wait_healthy
  req PUT "/api/deliveries/$delivery/status?status=DELIVERED" "${SHIP_TOKEN[0]}"; expect_ok "DELIVERED"
  wait_status "$ORDER" DELIVERED 120
  wait_case "$ORDER" COMPLETED 120
  log "$(snapshot "$ORDER" "$delivery")"
  echo "$ORDER $delivery" > "$R01_RESULT"
}
dispatch_wait_healthy() {
  local deadline=$((SECONDS + 240))
  while (( SECONDS < deadline )); do
    [ "$("${COMPOSE_COMMAND[@]}" ps --format '{{.Health}}' "$DISPATCH" 2>/dev/null)" = healthy ] \
      && { log "dispatch back (healthy)"; return 0; }
    sleep 3
  done
  fail "dispatch did not become healthy again"
}

r02() { # duplicates + stale events on a finished order, then out-of-order on a live one
  local done_order done_delivery before after
  if [ -s "$R01_RESULT" ]; then read -r done_order done_delivery < "$R01_RESULT"
  else  # R01 skipped or failed: finish a plain order first
    only_online 0; new_order; confirm "$ORDER"; wait_offer "$ORDER" 120 0
    done_order="$ORDER"; done_delivery="$OFFER_DELIVERY"
    respond 0 "$ORDER" ACCEPT; expect_ok "accept"; wait_status "$ORDER" ASSIGNED 60
    finish 0 "$done_delivery" "$ORDER"; wait_case "$ORDER" COMPLETED 120
  fi
  wait_status "$done_order" DELIVERED 10
  sleep 3   # let settlement finish before taking the baseline
  before="$(snapshot "$done_order" "$done_delivery")"
  log "finished order before replays: $before"
  replay order_db outbox_events order.created "$done_order"                     # duplicate start
  replay delivery_db outbox_events delivery.created.result "$done_delivery"     # stale
  replay delivery_db outbox_events delivery.offer-persisted "$done_delivery"    # stale offer
  replay delivery_db outbox_events delivery.shipper-accepted "$done_delivery"   # duplicate
  replay delivery_db outbox_events delivery.shipper-accepted "$done_delivery"
  replay delivery_db outbox_events delivery.completed "$done_delivery" last     # duplicate money event
  sleep 15
  after="$(snapshot "$done_order" "$done_delivery")"
  [ "$after" = "$before" ] || fail "replays changed the finished order: before [$before] after [$after]"
  never_offered "$done_order" 5 0 1 2
  log "finished order unchanged after 6 replays"

  # Out of order on a live order: earlier events arrive after the offer is out.
  only_online 0
  new_order; confirm "$ORDER"
  wait_offer "$ORDER" 120 0; local live_delivery="$OFFER_DELIVERY"
  wait_status "$ORDER" WAIT_SHIPPER_CONFIRM 30
  wait_case "$ORDER" SHIPPER_FOUND 30
  replay order_db outbox_events order.created "$ORDER"
  replay delivery_db outbox_events delivery.created.result "$live_delivery"
  replay delivery_db outbox_events delivery.offer-persisted "$live_delivery"
  sleep 10
  wait_case "$ORDER" SHIPPER_FOUND 5
  offer_of 0; [ "$OFFER_ORDER" = "$ORDER" ] || fail "out-of-order replays took the live offer away"
  [ "$(sql saga_db "SELECT count(*) FROM saga_instances WHERE order_id = $ORDER;")" = 1 ] \
    || fail "duplicate order.created opened a second dispatch case"
  respond 0 "$ORDER" ACCEPT; expect_ok "shipper#0 accepts after the replays"
  wait_status "$ORDER" ASSIGNED 60
  finish 0 "$live_delivery" "$ORDER"
  wait_case "$ORDER" COMPLETED 120
  log "live order completed normally: $(snapshot "$ORDER" "$live_delivery")"
}

R01_RESULT="$(mktemp)"
trap 'rm -f "$seed_result" "$R01_RESULT"' EXIT
ONLY_SCENARIOS="${TIER3_ONLY:-}"
run_scenarios "Tier 3" R01:r01 R02:r02
exit $?
