#!/usr/bin/env bash
# TC48: PostgreSQL CDC listening mode — Debezium logical replication INSERT/UPDATE/DELETE
# Each operation uses a separate siddhi app (one Debezium connector each) for the same
# reason as TC39: Debezium's JMX MBean names collide when connectors share a server id.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC48"

require_si_running
require_postgres_running

PG_JAR="$(pgjdbc_jar)"
if [[ -z "${PG_JAR}" ]]; then
    log_skip "PostgreSQL JDBC driver not found in \${SI_HOME}/lib/ — skipping TC48"
    exit "${SKIP_EXIT_CODE}"
fi

PG_VER="$(pgjdbc_version "${PG_JAR}")"
log_info "T1: pgjdbc supports Debezium 3.6.1 logical replication"
if pgjdbc_has_automatic_flush "${PG_JAR}"; then
    log_pass "T1: pgjdbc ${PG_VER:-unknown} provides ChainedCommonStreamBuilder.withAutomaticFlush"
else
    # Not a skip: the driver is installed but too old, which breaks CDC listening at
    # runtime with a bare NoSuchMethodError. Naming it here is the point of TC48.
    log_fail "T1: pgjdbc ${PG_VER:-unknown} lacks ChainedCommonStreamBuilder.withAutomaticFlush — Debezium 3.6.1 needs pgjdbc ${PGJDBC_MIN_VERSION}+ (siddhi-io-cdc PR #101). CDC listening will fail with NoSuchMethodError."
    print_summary; tc_exit_code
fi

cleanup() {
    undeploy_app "TC48_CDCPgInsert.siddhi" 2>/dev/null || true
    undeploy_app "TC48_CDCPgUpdate.siddhi" 2>/dev/null || true
    undeploy_app "TC48_CDCPgDelete.siddhi" 2>/dev/null || true
    postgres_query "DELETE FROM cdc_listen_table_pg;" >/dev/null 2>&1 || true
    drop_pg_replication_slots
}
trap cleanup EXIT

# Start from a clean slot set so max_replication_slots cannot be exhausted by
# a previous interrupted run.
drop_pg_replication_slots

_wait_pg_streaming() {
    local baseline="$1"
    local elapsed=0
    until tail -n +"$((baseline + 1))" "${SI_LOG}" 2>/dev/null \
          | grep -E 'ChangeEventSourceCoordinator.*Starting streaming|PostgresStreamingChangeEventSource.*Processing messages' >/dev/null; do
        sleep 1; (( elapsed++ )) || true
        if (( elapsed >= 45 )); then
            log_fail "Debezium logical replication not streaming within 45s"
            return 1
        fi
    done
    log_pass "Debezium logical replication streaming"
}

# ── INSERT ───────────────────────────────────────────────────────────────────
log_info "T2: TC48 INSERT app started (Debezium connector initialises)"
undeploy_app "TC48_CDCPgInsert.siddhi"
mark_log
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC48_CDCPgInsert.siddhi"
assert_app_deployed "T2: TC48 INSERT app started" TC48_CDCPgInsert 60
_wait_pg_streaming "$_BASELINE"

log_info "T3: INSERT — CDC listening captures new row"
postgres_query "INSERT INTO cdc_listen_table_pg (order_id, product, quantity, price) VALUES (1, 'Apple', 5, 2.50);" >/dev/null
assert_log_contains "T3: CDC captures INSERT (Apple)" '\[TC48-INSERT\].*data=\[1, Apple, 5, 2\.5\]' 30

undeploy_app "TC48_CDCPgInsert.siddhi"

# ── UPDATE ───────────────────────────────────────────────────────────────────
log_info "T4: TC48 UPDATE app started (Debezium connector initialises)"
undeploy_app "TC48_CDCPgUpdate.siddhi"
mark_log
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC48_CDCPgUpdate.siddhi"
assert_app_deployed "T4: TC48 UPDATE app started" TC48_CDCPgUpdate 60
_wait_pg_streaming "$_BASELINE"

log_info "T5: UPDATE — CDC listening captures row change"
postgres_query "UPDATE cdc_listen_table_pg SET quantity=20, price=3.00 WHERE order_id=1;" >/dev/null
assert_log_contains "T5: CDC captures UPDATE (quantity=20)" '\[TC48-UPDATE\].*data=\[1, Apple, 20, 3\.0\]' 30

undeploy_app "TC48_CDCPgUpdate.siddhi"

# ── DELETE ───────────────────────────────────────────────────────────────────
# REPLICA IDENTITY FULL on cdc_listen_table_pg is what makes the before_* fields
# arrive populated; with the default identity they would be null here.
log_info "T6: TC48 DELETE app started (Debezium connector initialises)"
undeploy_app "TC48_CDCPgDelete.siddhi"
mark_log
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC48_CDCPgDelete.siddhi"
assert_app_deployed "T6: TC48 DELETE app started" TC48_CDCPgDelete 60
_wait_pg_streaming "$_BASELINE"

log_info "T7: DELETE — CDC listening captures row removal with before-image"
postgres_query "DELETE FROM cdc_listen_table_pg WHERE order_id=1;" >/dev/null
assert_log_contains "T7: CDC captures DELETE (before_product=Apple)" '\[TC48-DELETE\].*data=\[1, Apple\]' 30

undeploy_app "TC48_CDCPgDelete.siddhi"

# ── Multiple INSERTs ─────────────────────────────────────────────────────────
log_info "T8: Deploy INSERT app again for multi-row test"
mark_log
_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)
deploy_app   "TC48_CDCPgInsert.siddhi"
assert_app_deployed "T8: TC48 INSERT app restarted" TC48_CDCPgInsert 60
_wait_pg_streaming "$_BASELINE"

log_info "T9: Multiple INSERTs in quick succession"
postgres_query "INSERT INTO cdc_listen_table_pg VALUES (2,'Banana',3,1.20);" >/dev/null
postgres_query "INSERT INTO cdc_listen_table_pg VALUES (3,'Cherry',8,4.00);" >/dev/null
assert_log_contains "T9: CDC captures Banana" '\[TC48-INSERT\].*data=\[2, Banana, ' 20
assert_log_contains "T9: CDC captures Cherry" '\[TC48-INSERT\].*data=\[3, Cherry, ' 10

print_summary; tc_exit_code
