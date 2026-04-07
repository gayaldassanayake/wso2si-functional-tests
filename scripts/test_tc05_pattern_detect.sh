#!/usr/bin/env bash
# TC05: Sequential pattern detection (login -> large transfer within 60s)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC05"

require_si_running
LOGIN_URL="http://localhost:${PORT_TC05}/TC05_PatternDetect/LoginStream"
TRANSFER_URL="http://localhost:${PORT_TC05}/TC05_PatternDetect/TransferStream"

log_info "T1 (positive): login then qualifying transfer for same user - alert should fire"
post_event "${LOGIN_URL}" '{"userId":"u1","ipAddress":"192.168.1.10"}' >/dev/null
sleep 1
post_event "${TRANSFER_URL}" '{"userId":"u1","amount":9999.0}' >/dev/null
assert_log_contains "T1: [TC05-ALERT] fires for u1" '\[TC05-ALERT\].*u1' 15

log_info "T2: Verify u1 is in AlertTable"
sleep 2
assert_store_count "T2: u1 is in AlertTable" "TC05_PatternDetect" \
    "from AlertTable select * having userId == 'u1'" 1

log_info "T3 (negative - amount too small): login then small transfer - no alert"
post_event "${LOGIN_URL}" '{"userId":"u2","ipAddress":"10.0.0.5"}' >/dev/null
sleep 1
post_event "${TRANSFER_URL}" '{"userId":"u2","amount":100.0}' >/dev/null
sleep "${PATTERN_WAIT_SECONDS}"
# u2 should NOT have generated an alert (amount too small)
assert_store_count "T3: u2 not in AlertTable (amount too small)" "TC05_PatternDetect" \
    "from AlertTable select * having userId == 'u2'" 0

log_info "T4 (negative - user mismatch): login u3 but transfer from u4 - no alert"
post_event "${LOGIN_URL}" '{"userId":"u3","ipAddress":"172.16.0.1"}' >/dev/null
sleep 1
post_event "${TRANSFER_URL}" '{"userId":"u4","amount":9999.0}' >/dev/null
sleep "${PATTERN_WAIT_SECONDS}"
# u3 login + u4 transfer (userId mismatch) should not fire
assert_store_count "T4: u3 not in AlertTable (userId mismatch)" "TC05_PatternDetect" \
    "from AlertTable select * having userId == 'u3'" 0

log_info "T5 (positive): second alert for u5"
post_event "${LOGIN_URL}" '{"userId":"u5","ipAddress":"192.168.2.20"}' >/dev/null
sleep 1
post_event "${TRANSFER_URL}" '{"userId":"u5","amount":50000.0}' >/dev/null
assert_log_contains "T5: [TC05-ALERT] fires for u5" '\[TC05-ALERT\].*u5' 15
sleep 2
assert_store_count "T5: u5 is in AlertTable" "TC05_PatternDetect" \
    "from AlertTable select * having userId == 'u5'" 1

print_summary; tc_exit_code
