#!/usr/bin/env bash
# TC16: Time extension functions
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC16"

require_si_running

undeploy_app "TC16_TimeFunctions.siddhi"
deploy_app   "TC16_TimeFunctions.siddhi"
assert_app_deployed "TC16 app started" TC16_TimeFunctions 30

URL="http://localhost:${PORT_TC16}/TC16_TimeFunctions/EventStream"

log_info "T1: Send event with a known date, verify time functions produce output"
post_event "${URL}" '{"eventId":"e1","eventDate":"2026-04-07","daysToAdd":10}' >/dev/null
assert_log_contains "T1: time function result logged" '\[TC16\].*data=\[e1, 2026-04-07, ' 20

log_info "T2: Verify formatted date contains expected parts (Tue for April 7, 2026)"
assert_log_contains "T2: formattedDate contains day abbreviation" '\[TC16\].*data=\[e1, [^]]*, Tue 07-Apr-2026, ' 10

log_info "T3: Verify dateAdd result (2026-04-07 + 10 days = 2026-04-17)"
assert_log_contains "T3: addedDate=2026-04-17" '\[TC16\].*data=\[e1, [^]]*, 2026-04-17, ' 10

log_info "T4: Send a Monday date and verify day-of-week extraction"
post_event "${URL}" '{"eventId":"e2","eventDate":"2026-04-06","daysToAdd":0}' >/dev/null
assert_log_contains "T4: time function output for Monday" '\[TC16\].*data=\[e2, [^]]*, Mon 06-Apr-2026, ' 15

log_info "T5: Verify timestampInMilliseconds is a positive number (currentTs > 0)"
# The log should contain a long number (epoch millis)
assert_log_contains "T5: currentTs (epoch ms) is present in log" '\[TC16\].*data=\[e1, [^,]*, [^,]*, [^,]*, [^,]*, [0-9]{13}, ' 10

log_info "T6: Verify Store API table has 2 records"
sleep 3
assert_store_count "T6: TimeFunctionTable has 2 records" "TC16_TimeFunctions" \
    "from TimeFunctionTable select *" 2

log_info "T7: Edge case - send a date from a different month"
post_event "${URL}" '{"eventId":"e3","eventDate":"2026-01-15","daysToAdd":30}' >/dev/null
assert_log_contains "T7: Jan date processed" '\[TC16\].*data=\[e3, 2026-01-15, ' 15
# 2026-01-15 + 30 days = 2026-02-14
assert_log_contains "T7: addedDate crosses month boundary" '\[TC16\].*data=\[e3, [^]]*, 2026-02-14, ' 10

log_info "T8: timestampInMilliseconds parses ISO and GMT offsets"
PARSE_URL="http://localhost:${PORT_TC16}/TC16_TimeFunctions/ParseStream"
# commons-lang3 before 3.5 rejects the XXX pattern and reads GMT+05:30 as 30 minutes off.
post_event "${PARSE_URL}" '{"eventId":"iso","dateValue":"2017-11-30T10:30:19+05:30","dateFormat":"yyyy-MM-dd'"'"'T'"'"'HH:mm:ssXXX"}' >/dev/null
assert_log_contains "T8: XXX parses +05:30" '\[TC16-PARSE\].*data=\[iso, 1512018019000\]' 15
post_event "${PARSE_URL}" '{"eventId":"gmt","dateValue":"2017-11-30 10:30:19 GMT+05:30","dateFormat":"yyyy-MM-dd HH:mm:ss z"}' >/dev/null
assert_log_contains "T8: z parses GMT+05:30 to the right instant" '\[TC16-PARSE\].*data=\[gmt, 1512018019000\]' 15

print_summary; tc_exit_code
