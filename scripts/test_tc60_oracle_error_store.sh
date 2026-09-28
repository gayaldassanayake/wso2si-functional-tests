#!/usr/bin/env bash
# TC60: Siddhi error store on Oracle (BNYMDMAPROD-86 / EIINTERNAL-1256)
#
# STANDALONE — do NOT run while SI is already running on port SI_HTTP_PORT.
# It enables error.store in deployment.yaml with an Oracle datasource, starts SI,
# and restores deployment.yaml and stops SI on exit.
#
# Usage:
#   SI_HOME=/path/to/wso2si-4.4.1-SNAPSHOT bash scripts/test_tc60_oracle_error_store.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC60"

APP_FILE="TC60_ErrorStoreOracle.siddhi"
RECV_FILE="TC60_ErrorStoreReceiver.siddhi"
APP_NAME="TC60_ErrorStoreOracle"
DEPLOYMENT_YAML="${SI_HOME}/conf/server/deployment.yaml"
BACKUP_YAML="${DEPLOYMENT_YAML}.tc60.bak"
URL="http://localhost:${PORT_TC60}/TC60_ErrorStoreOracle/OrderStream"
ERR_API="https://localhost:9443/error-handler"
TABLE="SIDDHI_ERROR_STORE_TABLE"
RUN_ID="tc60-$(date +%s)"

require_file "${SI_HOME}/bin/server.sh"
require_file "${DEPLOYMENT_YAML}"
require_docker_container "${ORACLE_CONTAINER}"

if nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo "[ERROR] A server is already running on port ${SI_HTTP_PORT}. Stop it before running TC60."
    exit 1
fi

if ! ls "${SI_HOME}/lib/ojdbc"*.jar >/dev/null 2>&1; then
    log_skip "Oracle JDBC bundle (ojdbc11) not found in \${SI_HOME}/lib/ - convert it with bin/jartobundle.sh"
    exit 0
fi

if [[ -f "${BACKUP_YAML}" ]]; then
    echo "[ERROR] ${BACKUP_YAML} exists from an earlier run. Restore it to deployment.yaml and delete it first."
    exit 1
fi

stop_si() {
    sh "${SI_HOME}/bin/server.sh" stop >/dev/null 2>&1 || true
    local elapsed=0
    while nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null && (( elapsed < 60 )); do
        sleep 1
        (( elapsed++ )) || true
    done
}

cleanup() {
    stop_si
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}" "${SI_SIDDHI_DIR}/${RECV_FILE}"
    [[ -f "${BACKUP_YAML}" ]] && mv "${BACKUP_YAML}" "${DEPLOYMENT_YAML}"
}
trap cleanup EXIT

LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
# carbon.log may be truncated on startup.
new_log() {
    local size
    size=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
    if (( size < LOG_OFFSET )); then
        cat "${SI_LOG}"
    else
        tail -c "+$(( LOG_OFFSET + 1 ))" "${SI_LOG}"
    fi 2>/dev/null
}

wait_new_log() {
    local pattern="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        # grep -q would SIGPIPE new_log under pipefail
        new_log | grep -E "${pattern}" >/dev/null && return 0
        sleep 2
        (( elapsed += 2 )) || true
    done
    return 1
}

start_si() {
    sh "${SI_HOME}/bin/server.sh" start >/dev/null 2>&1
    wait_new_log 'WSO2 Streaming Integrator started' 180 &&
        wait_new_log "${APP_NAME} deployed successfully" 60
}

api() { curl -sk -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" --max-time 20 "$@" || true; }
table_rows() { oracle_query "SELECT COUNT(*) FROM ${TABLE};" | tr -d '[:space:]'; }
wait_table_rows() {
    local expected="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        [[ "$(table_rows)" == "${expected}" ]] && return 0
        sleep 2
        (( elapsed += 2 )) || true
    done
    return 1
}
ora_errors() { new_log | grep -E 'ORA-[0-9]{5}' | head -3 || true; }

oracle_query "DROP TABLE IF EXISTS ${TABLE} PURGE;" >/dev/null

cp "${DEPLOYMENT_YAML}" "${BACKUP_YAML}"
export TC60_DS='    - name: ERROR_STORE_DB
      description: "Error store on Oracle (TC60)"
      definition:
        type: RDBMS
        configuration:
          jdbcUrl: "jdbc:oracle:thin:@localhost:1522/FREEPDB1"
          username: sitest
          password: sitest123
          driverClassName: oracle.jdbc.OracleDriver
          maxPoolSize: 10
          idleTimeout: 60000
          connectionTestQuery: SELECT 1 FROM DUAL
          validationTimeout: 30000
          isAutoCommit: false
'
perl -0pi -e '
  s/(error\.store:\n  enabled: )false/${1}true/;
  s/(datasource: )WSO2_CARBON_DB(\n    table: SIDDHI_ERROR_STORE_TABLE)/${1}ERROR_STORE_DB$2/;
  s/(wso2\.datasources:\n  dataSources:\n)/$1$ENV{TC60_DS}/;
' "${DEPLOYMENT_YAML}"
if ! { grep -A1 '^error.store:' "${DEPLOYMENT_YAML}" | grep -q 'enabled: true' &&
        grep -q 'datasource: ERROR_STORE_DB' "${DEPLOYMENT_YAML}" &&
        grep -q 'name: ERROR_STORE_DB' "${DEPLOYMENT_YAML}"; }; then
    echo "[ERROR] deployment.yaml patch did not apply"
    exit 1
fi

cp "${SUITE_ROOT}/siddhi-apps/${APP_FILE}" "${SI_SIDDHI_DIR}/"

log_info "T1: SI starts with the Oracle error store"
if start_si; then
    log_pass "T1: server started and ${APP_NAME} deployed"
else
    log_fail "T1: server did not start or ${APP_NAME} did not deploy"
    print_summary; exit 1
fi
ERRS=$(ora_errors)
if [[ -z "${ERRS}" ]] && ! new_log | grep -E 'DatasourceConfigurationException|DatabaseUnsupportedException' >/dev/null; then
    log_pass "T1: no ORA- or error store datasource errors on startup"
else
    log_fail "T1: errors on startup: ${ERRS:-error store datasource error}"
fi

# The table is created on the first saved entry.
log_info "T2: the first failed event creates the table; entries get increasing ids"
for i in 1 2 3; do
    post_event "${URL}" "{\"orderId\":\"${RUN_ID}-${i}\",\"amount\":${i}.5}" >/dev/null || true
    sleep 1
done
sleep 5
if [[ "$(oracle_query "SELECT COUNT(*) FROM user_tables WHERE table_name='${TABLE}';" | tr -d '[:space:]')" == "1" ]]; then
    log_pass "T2: ${TABLE} created in Oracle"
else
    log_fail "T2: ${TABLE} was not created in Oracle: $(ora_errors)"
    print_summary; exit 1
fi
if wait_table_rows 3 60; then
    log_pass "T2: 3 rows in ${TABLE}"
else
    log_fail "T2: expected 3 rows in ${TABLE}, got '$(table_rows)'"
fi
IDS=$(oracle_query "SELECT LISTAGG(id, ',') WITHIN GROUP (ORDER BY id) FROM ${TABLE};" | tr -d '[:space:]')
if [[ -n "${IDS}" ]] && awk -F, '{for (i = 2; i <= NF; i++) if ($i <= $(i-1)) exit 1}' <<< "${IDS}"; then
    log_pass "T2: ids are increasing (${IDS})"
else
    log_fail "T2: ids not increasing: '${IDS}'"
fi
MAX_ID="${IDS##*,}"
COUNT_BODY=$(api "${ERR_API}/error-entries/count?siddhiApp=${APP_NAME}")
if grep -qE '"entriesCount" *: *3' <<< "${COUNT_BODY}"; then
    log_pass "T2: error-handler API reports 3 entries"
else
    log_fail "T2: error-handler count API returned '${COUNT_BODY}'"
fi

log_info "T3: replaying the entries delivers them and removes them from the store"
cp "${SUITE_ROOT}/siddhi-apps/${RECV_FILE}" "${SI_SIDDHI_DIR}/"
wait_new_log 'TC60_ErrorStoreReceiver deployed successfully' 30 || log_fail "T3: receiver app did not deploy"
ENTRIES=$(api "${ERR_API}/error-entries?siddhiApp=${APP_NAME}&descriptive=true")
if new_log | grep -E 'ORA-17027' >/dev/null || [[ -z "${ENTRIES}" || "${ENTRIES}" == "[]" ]]; then
    log_fail "T3: listing entries failed$(new_log | grep -E 'ORA-17027' >/dev/null && echo ' with ORA-17027')"
    log_skip "T3: replay not attempted, the entries could not be listed"
    oracle_query "DELETE FROM ${TABLE};
COMMIT;" >/dev/null
else
    log_pass "T3: entries listed through the error-handler API"
    WRAPPED=$(python3 -c 'import json,sys; print(json.dumps([{"errorEntry": e, "isPayloadModifiable": False} for e in json.load(sys.stdin)]))' <<< "${ENTRIES}")
    STATUS=$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "${WRAPPED}" "${ERR_API}/")
    if [[ "${STATUS}" == "200" ]]; then
        log_pass "T3: replay request accepted (HTTP 200)"
    else
        log_fail "T3: replay request returned HTTP ${STATUS}"
    fi
    if wait_new_log "\[TC60-RECV\].*${RUN_ID}-1" 30 && wait_new_log "\[TC60-RECV\].*${RUN_ID}-2" 5 &&
            wait_new_log "\[TC60-RECV\].*${RUN_ID}-3" 5; then
        log_pass "T3: all 3 replayed events reached the receiver"
    else
        log_fail "T3: replayed events did not all reach the receiver"
    fi
    if wait_table_rows 0 30; then
        log_pass "T3: replayed entries removed from ${TABLE}"
    else
        log_fail "T3: ${TABLE} still has '$(table_rows)' rows after replay"
        oracle_query "DELETE FROM ${TABLE};
COMMIT;" >/dev/null
    fi
fi

log_info "T4: restart with the table already present"
rm -f "${SI_SIDDHI_DIR}/${RECV_FILE}"
stop_si
LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
if start_si; then
    log_pass "T4: server restarted and ${APP_NAME} deployed"
else
    log_fail "T4: server did not restart"
    print_summary; exit 1
fi
ERRS=$(ora_errors)
if [[ -z "${ERRS}" ]]; then
    log_pass "T4: no ORA- errors on restart"
else
    log_fail "T4: ORA- errors on restart: ${ERRS}"
fi
post_event "${URL}" "{\"orderId\":\"${RUN_ID}-4\",\"amount\":4.5}" >/dev/null || true
if wait_table_rows 1 60; then
    NEW_ID=$(oracle_query "SELECT MAX(id) FROM ${TABLE};" | tr -d '[:space:]')
    if [[ "${NEW_ID}" =~ ^[0-9]+$ && "${MAX_ID}" =~ ^[0-9]+$ ]] && (( NEW_ID > MAX_ID )); then
        log_pass "T4: new entry stored with id ${NEW_ID} > ${MAX_ID}"
    else
        log_fail "T4: new entry id '${NEW_ID}' is not above the previous maximum '${MAX_ID}'"
    fi
else
    log_fail "T4: expected 1 row after restart, got '$(table_rows)'"
fi

log_info "T5: purge by retention days"
STATUS=$(api -o /dev/null -w '%{http_code}' -X DELETE "${ERR_API}/error-entries?retentionDays=0")
sleep 3
PURGE_ERR=$(new_log | grep -E 'ORA-00997|Failed to purge the error store' | head -2 || true)
if [[ "${STATUS}" == "200" && -z "${PURGE_ERR}" ]] && wait_table_rows 0 10; then
    log_pass "T5: purge succeeded and ${TABLE} is empty"
else
    log_fail "T5: purge returned HTTP ${STATUS}, rows '$(table_rows)', errors: ${PURGE_ERR:-none}"
fi

print_summary; tc_exit_code
