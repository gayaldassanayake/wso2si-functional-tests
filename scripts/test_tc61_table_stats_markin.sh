#!/usr/bin/env bash
# TC61: table latency statistics while table operations fail (BNYMDMAPROD-231)
#
# Starts its own MySQL container, because the test stops the database.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC61"

require_si_running

APP_FILE="TC61_TableStatsMarkIn.siddhi"
APP_NAME="TC61_TableStatsMarkIn"
URL="http://localhost:${PORT_TC61}/TC61_TableStatsMarkIn/OpStream"
API="https://localhost:9443/siddhi-apps"
C="${TC61_MYSQL_CONTAINER}"
RUN_ID="tc61-$(date +%s)"

if ! ls "${SI_HOME}/lib/mysql-connector"*.jar >/dev/null 2>&1; then
    log_skip "MySQL JDBC driver not found in \${SI_HOME}/lib/ - skipping TC61"
    exit 0
fi

tc61_sql() { docker exec "${C}" mysql -usitest -psitest123 tc61 --skip-column-names -e "$1" 2>/dev/null || true; }
wait_mysql() {
    local elapsed=0
    until docker exec "${C}" mysql -usitest -psitest123 tc61 -e 'SELECT 1' >/dev/null 2>&1; do
        sleep 2
        (( elapsed += 2 )) || true
        (( elapsed > 120 )) && return 1
    done
    return 0
}
api() { curl -sk -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" --max-time 20 "$@" || true; }
post_batch() { curl -s -o /dev/null --max-time 10 -X POST -H 'Content-Type: application/json' -d "$1" "${URL}" || true; }
# One request per op, so a failed insert chunk doesn't drop the upserts and deletes.
events() {
    local op="$1" from="$2" to="$3" shift_by="$4" out="[" i sep=""
    for i in $(seq "$from" "$to"); do
        out+="${sep}{\"event\":{\"op\":\"${op}\",\"id\":\"${RUN_ID}-$(( i - shift_by ))\",\"qty\":$(( i * 2 ))}}"
        sep=","
    done
    echo "${out}]"
}
send_range() {
    local from="$1" to="$2" s e
    for (( s = from; s <= to; s += 50 )); do
        e=$(( s + 49 < to ? s + 49 : to ))
        post_batch "$(events insert "$s" "$e" 0)"
        post_batch "$(events insert "$s" "$e" 1)"
        post_batch "$(events upsert "$s" "$e" 0)"
        if (( s > 2 )); then
            post_batch "$(events delete "$s" "$e" 2)"
        fi
    done
}

LOG_OFFSET=0
mark_log() { LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0); }
new_log() { tail -c "+$(( LOG_OFFSET + 1 ))" "${SI_LOG}" 2>/dev/null; }
wait_new_log() {
    local pattern="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        new_log | grep -E "${pattern}" >/dev/null && return 0
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    docker rm -f "${C}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

IMAGE=$(docker inspect -f '{{.Config.Image}}' "${MYSQL_CONTAINER}" 2>/dev/null || echo "mysql:8.0")
docker rm -f "${C}" >/dev/null 2>&1 || true
docker run -d --name "${C}" -p "${TC61_MYSQL_PORT}:3306" -e MYSQL_ROOT_PASSWORD=root \
    -e MYSQL_DATABASE=tc61 -e MYSQL_USER=sitest -e MYSQL_PASSWORD=sitest123 "${IMAGE}" >/dev/null
if ! wait_mysql; then
    log_fail "throwaway MySQL container ${C} did not start"
    print_summary; exit 1
fi

log_info "T1: app deploys with statistics enabled"
undeploy_app "${APP_FILE}"
mark_log
deploy_app "${APP_FILE}"
if ! wait_new_log "${APP_NAME} deployed successfully" 30; then
    log_fail "T1: ${APP_NAME} did not deploy"
    print_summary; exit 1
fi
api -o /dev/null -X PUT -H 'Content-Type: application/json' -d '{"statsEnable":true}' "${API}/${APP_NAME}/statistics"
STATS=$(api "${API}/statistics" | python3 -c '
import json, sys
apps = json.load(sys.stdin)
print(next((a.get("isStatEnabled", "") for a in apps if a.get("appName") == sys.argv[1]), ""))' "${APP_NAME}" 2>/dev/null || true)
if [[ -n "${STATS}" && "${STATS}" != "OFF" ]]; then
    log_pass "T1: statistics level is ${STATS}"
else
    log_fail "T1: statistics not enabled for ${APP_NAME} (got '${STATS}')"
fi

log_info "T2: inserts, duplicate inserts, upserts and deletes for 250 ids"
send_range 1 250

# The RDBMS table blocks and retries while MySQL is down, so the outage itself raises no errors.
log_info "T3: MySQL outage and recovery"
docker stop "${C}" >/dev/null
send_range 251 350
docker start "${C}" >/dev/null
wait_mysql || log_fail "T3: MySQL did not come back"
RECOVERED=false
for _ in $(seq 1 60); do
    post_batch "[{\"event\":{\"op\":\"upsert\",\"id\":\"${RUN_ID}-probe\",\"qty\":1}}]"
    if [[ "$(tc61_sql "SELECT qty FROM TC61_ITEMS WHERE id='${RUN_ID}-probe'" | tr -d '[:space:]')" == "1" ]]; then
        RECOVERED=true
        break
    fi
    sleep 3
done
if [[ "${RECOVERED}" == "true" ]]; then
    log_pass "T3: table writes resume after the outage"
else
    log_fail "T3: table writes did not resume within 180s"
fi
send_range 351 500

log_info "T4: failing table operations did not leave a latency tracker marked in"
if new_log | grep -E 'Duplicate entry|SQLIntegrityConstraintViolation' >/dev/null; then
    log_pass "T4: duplicate-key failures occurred"
else
    log_fail "T4: no duplicate-key failure in the log; the failure path was not exercised"
fi
MARKIN=$(new_log | grep -c 'MarkIn consecutively' || true)
if [[ "${MARKIN}" == "0" ]]; then
    log_pass "T4: no 'MarkIn consecutively' errors"
else
    log_fail "T4: ${MARKIN} 'MarkIn consecutively' errors"
fi
post_batch "[{\"event\":{\"op\":\"done\",\"id\":\"${RUN_ID}-done\",\"qty\":0}}]"
if wait_new_log "\[TC61\].*${RUN_ID}-done" 20; then
    log_pass "T4: app still processes events"
else
    log_fail "T4: final event not processed"
fi
QTY=$(tc61_sql "SELECT qty FROM TC61_ITEMS WHERE id='${RUN_ID}-500'" | tr -d '[:space:]')
if [[ "${QTY}" == "1000" ]]; then
    log_pass "T4: last upsert after recovery landed (qty 1000)"
else
    log_fail "T4: expected qty 1000 for ${RUN_ID}-500, got '${QTY}'"
fi

undeploy_app "${APP_FILE}"
print_summary; tc_exit_code
