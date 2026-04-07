#!/usr/bin/env bash
# TC06: Exhaustive Store Query API verification
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC06"

require_si_running
URL="http://localhost:${PORT_TC06}/TC06_StoreAndQuery/ProductStream"

# Insert test products (2 electronics, 2 appliances, 1 furniture)
log_info "Inserting 5 test products..."
post_event "${URL}" '{"productId":"p1","name":"Laptop","category":"electronics","price":1200.0,"stock":10}' >/dev/null
post_event "${URL}" '{"productId":"p2","name":"Phone","category":"electronics","price":800.0,"stock":25}' >/dev/null
post_event "${URL}" '{"productId":"p3","name":"Fridge","category":"appliances","price":600.0,"stock":5}' >/dev/null
post_event "${URL}" '{"productId":"p4","name":"Blender","category":"appliances","price":45.0,"stock":50}' >/dev/null
post_event "${URL}" '{"productId":"p5","name":"Chair","category":"furniture","price":150.0,"stock":30}' >/dev/null
sleep 3

log_info "T1: SELECT * returns all 5 records"
assert_store_count "T1: all 5 products returned" "TC06_StoreAndQuery" \
    "from ProductTable select *" 5

log_info "T2: Filter by category (electronics) returns 2 records"
assert_store_count "T2: electronics filter" "TC06_StoreAndQuery" \
    "from ProductTable select * having category == 'electronics'" 2

log_info "T3: Filter by price > 500 returns 3 records (Laptop, Phone, Fridge)"
assert_store_count "T3: price > 500 filter" "TC06_StoreAndQuery" \
    "from ProductTable select * having price > 500.0" 3

log_info "T4: Filter by stock < 10 returns 1 record (Fridge)"
assert_store_count "T4: stock < 10 filter" "TC06_StoreAndQuery" \
    "from ProductTable select * having stock < 10" 1

log_info "T5: Upsert - re-insert p1 with new price, count stays at 5"
post_event "${URL}" '{"productId":"p1","name":"Laptop Pro","category":"electronics","price":2000.0,"stock":8}' >/dev/null
sleep 3
assert_store_count "T5: count stays 5 after upsert" "TC06_StoreAndQuery" \
    "from ProductTable select *" 5

log_info "T6: Wrong app name returns HTTP 404"
actual=$(store_query_status "NonExistentApp" "from ProductTable select *")
if [[ "${actual}" == "404" ]]; then
    log_pass "T6: non-existent app returns HTTP 404"
else
    log_fail "T6: expected 404, got ${actual}"
fi

log_info "T7: Non-existent table returns HTTP 500"
actual=$(store_query_status "TC06_StoreAndQuery" "from NonExistentTable select *")
if [[ "${actual}" == "500" ]]; then
    log_pass "T7: non-existent table returns HTTP 500"
else
    log_fail "T7: expected 500, got ${actual}"
fi

log_info "T8: Empty app name returns HTTP 400"
actual=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"appName":"","query":"from ProductTable select *"}' \
    "http://localhost:${SI_STORE_API_PORT}/stores/query")
if [[ "${actual}" == "400" ]]; then
    log_pass "T8: empty appName returns HTTP 400"
else
    log_fail "T8: expected 400, got ${actual}"
fi

log_info "T9: Malformed request body returns HTTP 400"
actual=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" \
    -X POST -H "Content-Type: application/json" \
    -d 'not-valid-json' \
    "http://localhost:${SI_STORE_API_PORT}/stores/query")
if [[ "${actual}" == "400" || "${actual}" == "500" ]]; then
    log_pass "T9: malformed JSON body returns HTTP ${actual} (error)"
else
    log_fail "T9: expected 4xx/5xx for malformed body, got ${actual}"
fi

print_summary; tc_exit_code
