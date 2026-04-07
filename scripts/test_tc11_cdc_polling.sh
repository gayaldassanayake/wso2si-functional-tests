#!/usr/bin/env bash
# TC11: CDC polling mode - detect MySQL table changes
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC11"

require_si_running
require_mysql_running

# Check MySQL JDBC driver
if ! ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | head -1 | grep -q '.jar'; then
    log_skip "MySQL JDBC driver not found in \${SI_HOME}/lib/ - skipping TC11"
    exit 0
fi

log_info "T1: Verify CDC app started successfully"
assert_log_contains "T1: TC11 app started" 'TC11_CDCPolling.*Started Successfully' 30

log_info "T2: Insert row into MySQL cdc_test_table"
mysql_query "INSERT INTO cdc_test_table (item_id, item_name, quantity) VALUES ('cdc-1', 'Apple', 10);"
assert_log_contains "T2: CDC picks up new row (Apple)" '\[TC11-CDC\].*Apple' 30

log_info "T3: Verify captured row in SI in-memory table"
sleep 5
assert_store_count "T3: CDCCapturedTable has 1 row" "TC11_CDCPolling" \
    "from CDCCapturedTable select *" 1

log_info "T4: Insert 2 more rows"
mysql_query "INSERT INTO cdc_test_table (item_id, item_name, quantity) VALUES ('cdc-2', 'Banana', 20);"
sleep 1
mysql_query "INSERT INTO cdc_test_table (item_id, item_name, quantity) VALUES ('cdc-3', 'Cherry', 30);"
assert_log_contains "T4: CDC picks up Banana" '\[TC11-CDC\].*Banana' 30
assert_log_contains "T4: CDC picks up Cherry" '\[TC11-CDC\].*Cherry' 15

sleep 5
assert_store_count "T4: CDCCapturedTable has 3 rows" "TC11_CDCPolling" \
    "from CDCCapturedTable select *" 3

log_info "T5: Update a row - CDC polling should detect the change (updated_at changes)"
mysql_query "UPDATE cdc_test_table SET quantity=100, item_name='Apple Updated' WHERE item_id='cdc-1';"
assert_log_contains "T5: CDC picks up update (Apple Updated)" '\[TC11-CDC\].*Apple Updated' 30

log_info "T6: Verify updated value in CDCCapturedTable"
sleep 5
response=$(store_query "TC11_CDCPolling" "from CDCCapturedTable select * having item_id == 'cdc-1'")
actual=$(_parse_record_count "${response}")
if [[ "${actual}" == "1" ]]; then
    log_pass "T6: updated row still exists in table"
else
    log_fail "T6: expected 1 record for cdc-1, got ${actual}. Response: ${response}"
fi

# Clean up CDC test data
mysql_query "DELETE FROM cdc_test_table WHERE item_id LIKE 'cdc-%';" >/dev/null 2>&1 || true

print_summary; tc_exit_code
