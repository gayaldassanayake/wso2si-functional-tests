#!/usr/bin/env bash
# TC01: Baseline HTTP pass-through
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC01"

require_si_running
URL="http://localhost:${PORT_TC01}/TC01_PassThrough/InputStream"

log_info "T1: POST event and verify log output"
post_event "${URL}" '{"symbol":"AAPL","price":150.25,"volume":1000}' >/dev/null
assert_log_contains "T1: event logged with [TC01] prefix" '\[TC01\].*AAPL' 20

log_info "T2: POST second event with different symbol"
post_event "${URL}" '{"symbol":"GOOG","price":2800.50,"volume":500}' >/dev/null
assert_log_contains "T2: second event logged" '\[TC01\].*GOOG' 15

log_info "T3: POST multiple events rapidly"
for sym in IBM MSFT TSLA; do
    post_event "${URL}" "{\"symbol\":\"${sym}\",\"price\":100.0,\"volume\":200}" >/dev/null
done
assert_log_contains "T3: rapid events processed" '\[TC01\].*TSLA' 15

print_summary; tc_exit_code
