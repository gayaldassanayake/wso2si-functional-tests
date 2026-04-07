#!/usr/bin/env bash
# TC07: MySQL RDBMS store via @store(type='rdbms')
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC07"

require_si_running
require_mysql_running

# Check MySQL JDBC driver
if ! ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | head -1 | grep -q '.jar'; then
    log_skip "MySQL JDBC driver not found in \${SI_HOME}/lib/ - skipping TC07"
    exit 0
fi

URL="http://localhost:${PORT_TC07}/TC07_MySQLPersist/InventoryStream"

log_info "T1: POST 3 inventory events and verify log output"
post_event "${URL}" '{"itemId":"i1","itemName":"Widget","quantity":100,"price":9.99}' >/dev/null
post_event "${URL}" '{"itemId":"i2","itemName":"Gadget","quantity":50,"price":24.99}' >/dev/null
post_event "${URL}" '{"itemId":"i3","itemName":"Doohickey","quantity":200,"price":4.99}' >/dev/null
assert_log_contains "T1: events logged with [TC07] prefix" '\[TC07\].*Widget' 25

log_info "T2: Verify 3 rows in MySQL InventoryTable"
sleep 5  # Give RDBMS store time to commit
assert_mysql_count "T2: MySQL has 3 rows" "InventoryTable" 3

log_info "T3: Store API also returns 3 records (rdbms tables are queryable)"
assert_store_count "T3: Store API returns 3" "TC07_MySQLPersist" \
    "from InventoryTable select *" 3

log_info "T4: Upsert - re-send itemId=i1 with new quantity"
post_event "${URL}" '{"itemId":"i1","itemName":"Widget Deluxe","quantity":150,"price":12.99}' >/dev/null
sleep 5
assert_mysql_count "T4: MySQL count stays 3 after upsert" "InventoryTable" 3

log_info "T5: Verify updated value in MySQL"
updated_qty=$(mysql_query "SELECT quantity FROM InventoryTable WHERE item_id='i1';")
if [[ "${updated_qty}" == "150" ]]; then
    log_pass "T5: quantity updated to 150 in MySQL"
else
    log_fail "T5: expected quantity=150, got '${updated_qty}'"
fi

log_info "T6: Delete test - remove i2 via direct MySQL DELETE, verify Store API reflects it"
mysql_query "DELETE FROM InventoryTable WHERE item_id='i2';" >/dev/null
sleep 2
assert_store_count "T6: Store API shows 2 after MySQL DELETE" "TC07_MySQLPersist" \
    "from InventoryTable select *" 2

print_summary; tc_exit_code
