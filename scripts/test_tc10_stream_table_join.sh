#!/usr/bin/env bash
# TC10: Stream-to-table join for data enrichment
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC10"

require_si_running
CATALOG_URL="http://localhost:${PORT_TC10}/TC10_StreamTableJoin/ProductCatalogStream"
ORDER_URL="http://localhost:${PORT_TC10}/TC10_StreamTableJoin/OrderStream"

log_info "Phase 1: Populate product catalog"
post_event "${CATALOG_URL}" '{"productId":"prod-1","productName":"Laptop","category":"electronics","unitPrice":1200.0}' >/dev/null
post_event "${CATALOG_URL}" '{"productId":"prod-2","productName":"Mouse","category":"electronics","unitPrice":25.0}' >/dev/null
post_event "${CATALOG_URL}" '{"productId":"prod-3","productName":"Desk","category":"furniture","unitPrice":350.0}' >/dev/null
sleep 3

log_info "T1: Order for prod-1 (Laptop) - should be enriched with name, category, total price"
post_event "${ORDER_URL}" '{"orderId":"ord-A","productId":"prod-1","quantity":2}' >/dev/null
assert_log_contains "T1: enriched order for Laptop" '\[TC10-ENRICHED\].*Laptop' 20

log_info "T2: Verify total price in enriched output (2 * 1200.0 = 2400.0)"
assert_log_contains "T2: totalPrice=2400.0 in enriched output" '\[TC10-ENRICHED\].*2400' 10

log_info "T3: Order for prod-2 (Mouse)"
post_event "${ORDER_URL}" '{"orderId":"ord-B","productId":"prod-2","quantity":5}' >/dev/null
assert_log_contains "T3: enriched order for Mouse" '\[TC10-ENRICHED\].*Mouse' 15

log_info "T4: Verify total price for Mouse (5 * 25.0 = 125.0)"
assert_log_contains "T4: totalPrice=125.0 for Mouse" '\[TC10-ENRICHED\].*125' 10

log_info "T5: Order for unknown product - should appear in UnknownProduct stream"
post_event "${ORDER_URL}" '{"orderId":"ord-C","productId":"prod-999","quantity":1}' >/dev/null
assert_log_contains "T5: unknown product flagged" '\[TC10-UNKNOWN\].*prod-999' 20

log_info "T6: Verify EnrichedOrderTable has correct entries"
sleep 3
assert_store_count "T6a: ord-A (Laptop) in EnrichedOrderTable" "TC10_StreamTableJoin" \
    "from EnrichedOrderTable select * having orderId == 'ord-A'" 1
assert_store_count "T6b: ord-B (Mouse) in EnrichedOrderTable" "TC10_StreamTableJoin" \
    "from EnrichedOrderTable select * having orderId == 'ord-B'" 1

log_info "T7: Update catalog price and re-order - new total should reflect updated price"
post_event "${CATALOG_URL}" '{"productId":"prod-2","productName":"Mouse Pro","category":"electronics","unitPrice":50.0}' >/dev/null
sleep 2
post_event "${ORDER_URL}" '{"orderId":"ord-D","productId":"prod-2","quantity":3}' >/dev/null
assert_log_contains "T7: enriched order with updated Mouse price (3 * 50.0 = 150.0)" '\[TC10-ENRICHED\].*150' 20

print_summary; tc_exit_code
