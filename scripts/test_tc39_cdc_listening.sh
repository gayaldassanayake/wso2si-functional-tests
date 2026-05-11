#!/usr/bin/env bash
# TC39: CDC listening mode — Debezium binlog INSERT/UPDATE/DELETE
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC39"

require_si_running
require_mysql_running

if ! ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | head -1 | grep -q '.jar'; then
    log_skip "MySQL JDBC driver not found in \${SI_HOME}/lib/ — skipping TC39"
    exit 0
fi

cleanup() {
    mysql_query "DELETE FROM cdc_listen_table;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_info "T1: TC39 app started (Debezium connector initialises)"
assert_log_contains "T1: TC39 app started" 'TC39_CDCListening.*deployed successfully' 60

log_info "T2: INSERT — CDC listening captures new row"
mysql_query "INSERT INTO cdc_listen_table (order_id, product, quantity, price) VALUES (1, 'Apple', 5, 2.50);"
assert_log_contains "T2: CDC captures INSERT (Apple)" '\[TC39-INSERT\].*Apple' 30

log_info "T3: UPDATE — CDC listening captures row change"
mysql_query "UPDATE cdc_listen_table SET quantity=20, price=3.00 WHERE order_id=1;"
assert_log_contains "T3: CDC captures UPDATE (quantity=20)" '\[TC39-UPDATE\].*20' 30

log_info "T4: DELETE — CDC listening captures row removal"
mysql_query "DELETE FROM cdc_listen_table WHERE order_id=1;"
assert_log_contains "T4: CDC captures DELETE (before_order_id=1)" '\[TC39-DELETE\].*1' 30

log_info "T5: Multiple INSERTs in quick succession"
mysql_query "INSERT INTO cdc_listen_table VALUES (2,'Banana',3,1.20);"
mysql_query "INSERT INTO cdc_listen_table VALUES (3,'Cherry',8,4.00);"
assert_log_contains "T5: CDC captures Banana" '\[TC39-INSERT\].*Banana' 20
assert_log_contains "T5: CDC captures Cherry" '\[TC39-INSERT\].*Cherry' 10

print_summary; tc_exit_code
