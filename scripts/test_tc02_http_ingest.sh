#!/usr/bin/env bash
# TC02: HTTP ingest + in-memory table + Store API
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC02"

require_si_running
URL="http://localhost:${PORT_TC02}/TC02_HttpIngest/SweetStream"

log_info "T1: POST event and verify log output"
post_event "${URL}" '{"name":"toffee","amount":25.5,"category":"candy"}' >/dev/null
assert_log_contains "T1: event logged with [TC02] prefix" '\[TC02\].*toffee' 20

log_info "T2: Insert 3 distinct products, verify Store API returns 3 records"
for row in \
    '{"name":"toffee","amount":25.5,"category":"candy"}' \
    '{"name":"cake","amount":150.0,"category":"bakery"}' \
    '{"name":"chocolate","amount":75.0,"category":"candy"}'; do
    post_event "${URL}" "${row}" >/dev/null
    sleep 0.3
done
sleep 3
assert_store_count "T2: 3 records in SweetTable" "TC02_HttpIngest" \
    "from SweetTable select *" 3

log_info "T3: Re-insert 'toffee' with different amount (upsert - count should stay 3)"
post_event "${URL}" '{"name":"toffee","amount":99.9,"category":"premium-candy"}' >/dev/null
sleep 3
assert_store_count "T3: upsert keeps count at 3" "TC02_HttpIngest" \
    "from SweetTable select *" 3

log_info "T4: Insert a 4th unique product, verify count becomes 4"
post_event "${URL}" '{"name":"marshmallow","amount":12.0,"category":"candy"}' >/dev/null
sleep 3
assert_store_count "T4: 4 records after new insert" "TC02_HttpIngest" \
    "from SweetTable select *" 4

print_summary; tc_exit_code
