#!/usr/bin/env bash
# TC16: Time extension functions
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC16"

require_si_running
URL="http://localhost:${PORT_TC16}/TC16_TimeFunctions/EventStream"

log_info "T1: Send event with a known date, verify time functions produce output"
post_event "${URL}" '{"eventId":"e1","eventDate":"2026-04-07","daysToAdd":10}' >/dev/null
assert_log_contains "T1: time function result logged" '\[TC16\].*e1' 20

log_info "T2: Verify formatted date contains expected parts (Tue for April 7, 2026)"
assert_log_contains "T2: formattedDate contains day abbreviation" '\[TC16\].*Tue' 10

log_info "T3: Verify dateAdd result (2026-04-07 + 10 days = 2026-04-17)"
assert_log_contains "T3: addedDate=2026-04-17" '\[TC16\].*2026-04-17' 10

log_info "T4: Send a Monday date and verify day-of-week extraction"
post_event "${URL}" '{"eventId":"e2","eventDate":"2026-04-06","daysToAdd":0}' >/dev/null
assert_log_contains "T4: time function output for Monday" '\[TC16\].*e2' 15

log_info "T5: Verify timestampInMilliseconds is a positive number (currentTs > 0)"
# The log should contain a long number (epoch millis)
assert_log_contains "T5: currentTs (epoch ms) is present in log" '\[TC16\].*[0-9]{13}' 10

log_info "T6: Verify Store API table has 2 records"
sleep 3
assert_store_count "T6: TimeFunctionTable has 2 records" "TC16_TimeFunctions" \
    "from TimeFunctionTable select *" 2

log_info "T7: Edge case - send a date from a different month"
post_event "${URL}" '{"eventId":"e3","eventDate":"2026-01-15","daysToAdd":30}' >/dev/null
assert_log_contains "T7: Jan date processed" '\[TC16\].*e3' 15
# 2026-01-15 + 30 days = 2026-02-14
assert_log_contains "T7: addedDate crosses month boundary" '\[TC16\].*2026-02-14' 10

print_summary; tc_exit_code
