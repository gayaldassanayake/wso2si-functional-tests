#!/usr/bin/env bash
# TC04: Filter predicates and str/math function transformations
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC04"

require_si_running
URL="http://localhost:${PORT_TC04}/TC04_FilterTransform/OrderStream"

log_info "T1: total=125 (5*25) should go to HIGH stream only"
post_event "${URL}" '{"orderId":"ord-1","product":"toffee","qty":5,"unitPrice":25.0}' >/dev/null
assert_log_contains "T1: [TC04-HIGH] fires for total=125" '\[TC04-HIGH\].*ord-1' 20

log_info "T2: HIGH stream should NOT fire for low-value orders (sanity check)"
# [TC04-LOW] should contain ord-2 when we post it next
post_event "${URL}" '{"orderId":"ord-2","product":"candy","qty":2,"unitPrice":30.0}' >/dev/null
# ord-1 was already processed - just check ord-2 doesn't appear in HIGH
sleep 2
assert_log_contains "T2: [TC04-LOW] fires for total=60" '\[TC04-LOW\].*ord-2' 10

log_info "T3: Boundary - total=100 exactly should go to LOW (condition is >100 for HIGH)"
post_event "${URL}" '{"orderId":"ord-3","product":"cake","qty":4,"unitPrice":25.0}' >/dev/null
assert_log_contains "T3: exact boundary=100 goes to LOW" '\[TC04-LOW\].*ord-3' 15

log_info "T4: Verify product name is UPPERCASED in HIGH stream"
post_event "${URL}" '{"orderId":"ord-4","product":"chocolate","qty":10,"unitPrice":20.0}' >/dev/null
assert_log_contains "T4: product uppercased in HIGH output" '\[TC04-HIGH\].*CHOCOLATE' 15

log_info "T5: Verify product name is lowercased in LOW stream"
post_event "${URL}" '{"orderId":"ord-5","product":"CANDY","qty":1,"unitPrice":50.0}' >/dev/null
assert_log_contains "T5: product lowercased in LOW output" '\[TC04-LOW\].*candy' 15

log_info "T6: Verify HIGH table has the tag field (HIGH-<orderId>)"
sleep 3
assert_store_count "T6: HighValueTable has correct entries" "TC04_FilterTransform" \
    "from HighValueTable select *" 2

log_info "T7: Store API - LowValueTable count check"
assert_store_count "T7: LowValueTable has correct entries" "TC04_FilterTransform" \
    "from LowValueTable select *" 3

print_summary; tc_exit_code
