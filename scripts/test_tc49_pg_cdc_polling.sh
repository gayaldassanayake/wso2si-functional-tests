#!/usr/bin/env bash
# TC49: PostgreSQL CDC polling mode — detect table changes via an incrementing row_version
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC49"

require_si_running
require_postgres_running

# Polling mode never enters Debezium's replication path, so it needs the driver
# present but not the pgjdbc version TC48 checks for.
PG_JAR="$(pgjdbc_jar)"
if [[ -z "${PG_JAR}" ]]; then
    log_skip "PostgreSQL JDBC driver not found in \${SI_HOME}/lib/ — skipping TC49"
    exit 0
fi

log_info "T1: Verify TC49 app started successfully"
undeploy_app "TC49_CDCPgPolling.siddhi"
postgres_query "DELETE FROM cdc_test_table_pg WHERE item_id LIKE 'pgcdc-%';" >/dev/null 2>&1 || true
deploy_app   "TC49_CDCPgPolling.siddhi"
assert_log_contains "T1: TC49 app started" 'TC49_CDCPgPolling.*deployed successfully' 30

log_info "T2: Insert row into Postgres cdc_test_table_pg"
postgres_query "INSERT INTO cdc_test_table_pg (item_id, item_name, quantity) VALUES ('pgcdc-1', 'Apple', 10);" >/dev/null
assert_log_contains "T2: CDC picks up new row (Apple)" '\[TC49-CDC\].*Apple' 30

log_info "T3: Verify captured row in SI in-memory table"
sleep 5
assert_store_count "T3: CDCPgCapturedTable has 1 row" "TC49_CDCPgPolling" \
    "from CDCPgCapturedTable select *" 1

log_info "T4: Insert 2 more rows"
postgres_query "INSERT INTO cdc_test_table_pg (item_id, item_name, quantity) VALUES ('pgcdc-2', 'Banana', 20);" >/dev/null
sleep 1
postgres_query "INSERT INTO cdc_test_table_pg (item_id, item_name, quantity) VALUES ('pgcdc-3', 'Cherry', 30);" >/dev/null
assert_log_contains "T4: CDC picks up Banana" '\[TC49-CDC\].*Banana' 30
assert_log_contains "T4: CDC picks up Cherry" '\[TC49-CDC\].*Cherry' 15

sleep 5
assert_store_count "T4: CDCPgCapturedTable has 3 rows" "TC49_CDCPgPolling" \
    "from CDCPgCapturedTable select *" 3

log_info "T5: Update a row — polling detects the bumped row_version"
postgres_query "UPDATE cdc_test_table_pg SET quantity=100, item_name='Apple Updated' WHERE item_id='pgcdc-1';" >/dev/null
assert_log_contains "T5: CDC picks up update (Apple Updated)" '\[TC49-CDC\].*Apple Updated' 30

log_info "T6: Verify updated value in CDCPgCapturedTable"
sleep 5
response=$(store_query "TC49_CDCPgPolling" "from CDCPgCapturedTable select * having item_id == 'pgcdc-1'")
actual=$(_parse_record_count "${response}")
if [[ "${actual}" == "1" ]]; then
    log_pass "T6: updated row still exists in table"
else
    log_fail "T6: expected 1 record for pgcdc-1, got ${actual}. Response: ${response}"
fi

postgres_query "DELETE FROM cdc_test_table_pg WHERE item_id LIKE 'pgcdc-%';" >/dev/null 2>&1 || true

print_summary; tc_exit_code
