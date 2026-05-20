#!/usr/bin/env bash
# TC39: CDC listening mode — Debezium binlog INSERT/UPDATE/DELETE
# Each operation uses a separate siddhi app (one Debezium connector each) to avoid
# Debezium 2.x JMX MBean name conflicts that occur when multiple connectors share
# the same MySQL URL and therefore the same JMX server identifier.
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
    undeploy_app "TC39_CDCInsert.siddhi" 2>/dev/null || true
    undeploy_app "TC39_CDCUpdate.siddhi" 2>/dev/null || true
    undeploy_app "TC39_CDCDelete.siddhi" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: wait for the single Debezium connector in a freshly deployed app to be streaming.
# Uses a log-line baseline to avoid matching "Keepalive thread is running" from previous runs.
_wait_debezium_ready() {
    local baseline="$1"
    local elapsed=0
    until tail -n +"$((baseline + 1))" "${SI_LOG}" 2>/dev/null \
          | grep -qE 'Keepalive thread is running'; do
        sleep 1; (( elapsed++ )) || true
        if (( elapsed >= 30 )); then
            log_fail "Debezium binlog streaming not ready within 30s"
            return 1
        fi
    done
    log_pass "Debezium binlog streaming ready"
}

# ── T1: INSERT ────────────────────────────────────────────────────────────────
log_info "T1: TC39 INSERT app started (Debezium connector initialises)"
undeploy_app "TC39_CDCInsert.siddhi"
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC39_CDCInsert.siddhi"
assert_log_contains "T1: TC39 INSERT app started" 'TC39_CDCInsert.*deployed successfully' 60
_wait_debezium_ready "$_BASELINE"

log_info "T2: INSERT — CDC listening captures new row"
mysql_query "INSERT INTO cdc_listen_table (order_id, product, quantity, price) VALUES (1, 'Apple', 5, 2.50);"
assert_log_contains "T2: CDC captures INSERT (Apple)" '\[TC39-INSERT\].*Apple' 30

undeploy_app "TC39_CDCInsert.siddhi"

# ── T3: UPDATE ────────────────────────────────────────────────────────────────
log_info "T3: TC39 UPDATE app started (Debezium connector initialises)"
undeploy_app "TC39_CDCUpdate.siddhi"
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC39_CDCUpdate.siddhi"
assert_log_contains "T3: TC39 UPDATE app started" 'TC39_CDCUpdate.*deployed successfully' 60
_wait_debezium_ready "$_BASELINE"

log_info "T4: UPDATE — CDC listening captures row change"
mysql_query "UPDATE cdc_listen_table SET quantity=20, price=3.00 WHERE order_id=1;"
assert_log_contains "T4: CDC captures UPDATE (quantity=20)" '\[TC39-UPDATE\].*20' 30

undeploy_app "TC39_CDCUpdate.siddhi"

# ── T5: DELETE ────────────────────────────────────────────────────────────────
log_info "T5: TC39 DELETE app started (Debezium connector initialises)"
undeploy_app "TC39_CDCDelete.siddhi"
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC39_CDCDelete.siddhi"
assert_log_contains "T5: TC39 DELETE app started" 'TC39_CDCDelete.*deployed successfully' 60
_wait_debezium_ready "$_BASELINE"

log_info "T6: DELETE — CDC listening captures row removal"
mysql_query "DELETE FROM cdc_listen_table WHERE order_id=1;"
assert_log_contains "T6: CDC captures DELETE (before_order_id=1)" '\[TC39-DELETE\].*1' 30

undeploy_app "TC39_CDCDelete.siddhi"

# ── T7: Multiple INSERTs ──────────────────────────────────────────────────────
log_info "T7: Deploy INSERT app again for multi-row test"
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC39_CDCInsert.siddhi"
assert_log_contains "T7: TC39 INSERT app restarted" 'TC39_CDCInsert.*deployed successfully' 60
_wait_debezium_ready "$_BASELINE"

log_info "T8: Multiple INSERTs in quick succession"
mysql_query "INSERT INTO cdc_listen_table VALUES (2,'Banana',3,1.20);"
mysql_query "INSERT INTO cdc_listen_table VALUES (3,'Cherry',8,4.00);"
assert_log_contains "T8: CDC captures Banana" '\[TC39-INSERT\].*Banana' 20
assert_log_contains "T8: CDC captures Cherry" '\[TC39-INSERT\].*Cherry' 10

print_summary; tc_exit_code
