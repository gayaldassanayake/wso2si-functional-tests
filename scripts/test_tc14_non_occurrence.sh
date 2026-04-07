#!/usr/bin/env bash
# TC14: Non-occurrence pattern (missing heartbeat alert after 15 seconds)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC14"

require_si_running
HB_URL="http://localhost:${PORT_TC14}/TC14_NonOccurrence/HeartbeatStream"

# Record log baseline before the test so all log assertions only scan NEW lines
LOG_BEFORE_TEST=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)

log_info "T1 (positive): Send one heartbeat then wait - missing-heartbeat alert should fire after 15s"
post_event "${HB_URL}" '{"deviceId":"dev-A","status":"online"}' >/dev/null
log_info "  Waiting up to 25s for the non-occurrence window to expire..."
# Poll only new log lines to avoid matching stale dev-A entry from previous runs
DEV_A_FOUND=false
for i in $(seq 1 25); do
    if tail -n +"$((LOG_BEFORE_TEST + 1))" "${SI_LOG}" 2>/dev/null | grep -qE '\[TC14-MISSING\].*dev-A'; then
        DEV_A_FOUND=true
        break
    fi
    sleep 1
done
if [[ "$DEV_A_FOUND" == "true" ]]; then
    log_pass "T1: [TC14-MISSING] fires for dev-A after 15s silence"
else
    log_fail "T1: [TC14-MISSING] fires for dev-A: not found in new log lines within 25s"
fi

log_info "T2: Verify dev-A alert in MissingHeartbeatTable"
sleep 2
assert_store_count "T2: dev-A in MissingHeartbeatTable" "TC14_NonOccurrence" \
    "from MissingHeartbeatTable select * having deviceId == 'dev-A'" 1

log_info "T3 (negative): Send heartbeat twice in quick succession - no alert should fire yet"
LOG_BEFORE_T3=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
post_event "${HB_URL}" '{"deviceId":"dev-B","status":"online"}' >/dev/null
sleep 3
post_event "${HB_URL}" '{"deviceId":"dev-B","status":"online"}' >/dev/null
# The second heartbeat for dev-B resets the non-occurrence window before it expires
sleep 5
# dev-B should not have alerted yet in new log lines (5s after second heartbeat, window is 15s)
if tail -n +"$((LOG_BEFORE_T3 + 1))" "${SI_LOG}" 2>/dev/null | grep -qE '\[TC14-MISSING\].*dev-B'; then
    log_fail "T3: dev-B alerted too early (second heartbeat should have reset window)"
else
    log_pass "T3: dev-B correctly not alerted yet (window reset by second heartbeat)"
fi

LOG_BEFORE_T4=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
log_info "T4: Second device (dev-C) also misses heartbeat - second alert fires"
post_event "${HB_URL}" '{"deviceId":"dev-C","status":"online"}' >/dev/null
log_info "  Waiting 25s for dev-C non-occurrence..."
DEV_C_FOUND=false
for i in $(seq 1 25); do
    if tail -n +"$((LOG_BEFORE_T4 + 1))" "${SI_LOG}" 2>/dev/null | grep -qE '\[TC14-MISSING\].*dev-C'; then
        DEV_C_FOUND=true
        break
    fi
    sleep 1
done
if [[ "$DEV_C_FOUND" == "true" ]]; then
    log_pass "T4: [TC14-MISSING] fires for dev-C"
else
    log_fail "T4: [TC14-MISSING] fires for dev-C: not found in new log lines within 25s"
fi
sleep 2
# dev-C alerted; dev-B's second heartbeat (from T3) also times out during this wait
assert_store_count "T4: dev-C in MissingHeartbeatTable" "TC14_NonOccurrence" \
    "from MissingHeartbeatTable select * having deviceId == 'dev-C'" 1
assert_store_count "T4: dev-B also alerted (second heartbeat expired)" "TC14_NonOccurrence" \
    "from MissingHeartbeatTable select * having deviceId == 'dev-B'" 1

print_summary; tc_exit_code
