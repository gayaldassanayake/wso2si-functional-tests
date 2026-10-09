#!/usr/bin/env bash
# TC73: siddhi-execution-json and siddhi-execution-list functions, stream processors and aggregations
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC73"

require_si_running

APP_FILE="TC73_JsonListFunctions.siddhi"
APP_NAME="TC73_JsonListFunctions"
BASE_URL="http://localhost:${PORT_TC73}/${APP_NAME}"
RUN_ID="tc73-$(date +%s)"

cleanup() { rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"; }
trap cleanup EXIT

undeploy_app "${APP_FILE}"
RUN_MARK=${LOG_MARK}
deploy_app "${APP_FILE}"

log_info "T1: app deploys"
assert_app_deployed "T1: ${APP_NAME} deployed" "${APP_NAME}" 30 || { print_summary; tc_exit_code; exit $?; }

DOC='{\"name\":\"John\",\"age\":30,\"big\":12345678901,\"salary\":1234.5,\"married\":true,\"address\":{\"city\":\"Colombo\"},\"tags\":[\"a\",\"b\",\"c\"]}'

log_info "T2: json:get* read typed values; isExists tells present from missing paths"
mark_log
post_event "${BASE_URL}/JsonStream" "{\"id\":\"${RUN_ID}-j1\",\"doc\":\"${DOC}\"}" >/dev/null
assert_log_contains "T2: string, int, long, double, bool and nested values read" \
    "\[TC73-JSON-GET\].*data=\[${RUN_ID}-j1, John, 30, 12345678901, 1234\.5, true, Colombo, true, false\]" 20

log_info "T3: json:setElement adds a key to an object from json:toObject"
assert_log_contains "T3: dept added and existing keys kept" \
    "\[TC73-JSON-SET\].*data=\[${RUN_ID}-j1, \{.*\"name\":\"John\".*\"dept\":\"ENG\"\}\]" 10

log_info "T4: json:tokenize emits one event per array element"
for tag in a b c; do
    assert_log_contains "T4: tag ${tag} emitted" "data=\[${RUN_ID}-j1, \"${tag}\"\]" 10
done

log_info "T5: json:group wraps a batch of two documents in the enclosing element"
post_event "${BASE_URL}/JsonStream" "{\"id\":\"${RUN_ID}-j2\",\"doc\":\"${DOC}\"}" >/dev/null
assert_log_contains "T5: two documents grouped under 'people'" \
    '\[TC73-JSON-GROUP\].*\{\\"people\\":\[\{.*\\"name\\":\\"John\\".*\},\{.*\\"name\\":\\"John\\".*\}\]\}' 20

log_info "T6: list functions on a list built with list:create"
mark_log
post_event "${BASE_URL}/ListStream" "{\"id\":\"${RUN_ID}-l1\",\"a\":\"alpha\",\"b\":\"beta\",\"c\":\"gamma\"}" >/dev/null
assert_log_contains "T6: size, get, contains, indexOf, isEmpty, isList, add, remove, sort; clone leaves the original intact" \
    "\[TC73-LIST\].*data=\[${RUN_ID}-l1, 3, beta, true, false, 2, false, true, 4, 2, 3, \[gamma, beta, alpha\]\]" 20

log_info "T7: list:tokenize emits each entry with its index"
assert_log_contains "T7: index 0 alpha" "data=\[${RUN_ID}-l1, 0, alpha\]" 10
assert_log_contains "T7: index 1 beta" "data=\[${RUN_ID}-l1, 1, beta\]" 5
assert_log_contains "T7: index 2 gamma" "data=\[${RUN_ID}-l1, 2, gamma\]" 5

log_info "T8: list:collect gathers a batch of four, and its distinct variant drops the repeat"
mark_log
for item in "${RUN_ID}-p" "${RUN_ID}-q" "${RUN_ID}-p" "${RUN_ID}-r"; do
    post_event "${BASE_URL}/ItemStream" "{\"id\":\"${RUN_ID}\",\"item\":\"${item}\"}" >/dev/null
done
assert_log_contains "T8: four items collected in order, three distinct" \
    "\[TC73-LIST-COLLECT\].*data=\[\[${RUN_ID}-p, ${RUN_ID}-q, ${RUN_ID}-p, ${RUN_ID}-r\], 3\]" 20

log_info "T9: no errors or class-loading failures"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T9: no errors in ${APP_NAME}" "Error in '${APP_NAME}'" 0
assert_log_not_contains "T9: no class-loading errors" 'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

print_summary; tc_exit_code
