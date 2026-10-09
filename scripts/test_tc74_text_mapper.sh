#!/usr/bin/env bash
# TC74: siddhi-map-text source and sink mapping
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC74"

require_si_running

APP_FILE="TC74_TextMapper.siddhi"
APP_NAME="TC74_TextMapper"
BASE_URL="http://localhost:${PORT_TC74}/${APP_NAME}"
REGEX_URL="http://localhost:${PORT_TC74_REGEX}/${APP_NAME}/RegexStream"
RUN_ID="tc74$(date +%s)"
OUT_DIR=$(mktemp -d)

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    rm -rf "${OUT_DIR}"
}
trap cleanup EXIT

text() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: text/plain; charset=utf-8' \
        --data-binary "$2" "$1" || true
}

# assert_file_text DESCRIPTION FILE EXPECTED [TIMEOUT]: waits until FILE contains EXPECTED exactly
assert_file_text() {
    local description="$1" file="$2" expected="$3" timeout="${4:-15}" elapsed=0 content=""
    while (( elapsed < timeout )); do
        content=$(cat "${file}" 2>/dev/null) || true
        [[ "${content}" == "${expected}" ]] && break
        sleep 1; (( elapsed++ )) || true
    done
    if [[ "${content}" == "${expected}" ]]; then
        log_pass "${description}"
    else
        log_fail "${description}: ${file##*/} contains '${content}', expected '${expected}'"
    fi
}

undeploy_app "${APP_FILE}"
RUN_MARK=${LOG_MARK}
sed "s|@OUT_DIR@|${OUT_DIR}|g" "${SUITE_ROOT}/siddhi-apps/templates/${APP_FILE}" > "${SI_SIDDHI_DIR}/${APP_FILE}"
log_info "Deployed ${APP_FILE} writing to ${OUT_DIR}"

log_info "T1: app deploys"
assert_app_deployed "T1: ${APP_NAME} deployed" "${APP_NAME}" 30 || { print_summary; tc_exit_code; exit $?; }

log_info "T2: default 'name:value' format, including special characters and a long"
mark_log
text "${BASE_URL}/DefaultStream" $'symbol:"A&B",\nprice:55.5,\nqty:100' >/dev/null
text "${BASE_URL}/DefaultStream" $'symbol:"IBM",\nprice:-1.25,\nqty:7' >/dev/null
text "${BASE_URL}/DefaultStream" $'symbol:"'"${RUN_ID}"$' X",\nprice:0.0,\nqty:9876543210' >/dev/null
assert_log_contains "T2: ampersand kept" '\[TC74-DEFAULT\].*data=\[A&B, 55\.5, 100\]' 15
assert_log_contains "T2: negative double" '\[TC74-DEFAULT\].*data=\[IBM, -1\.25, 7\]' 5
assert_log_contains "T2: space in a string, long beyond int range" "\[TC74-DEFAULT\].*data=\[${RUN_ID} X, 0\.0, 9876543210\]" 5

log_info "T3: text sink groups a batch of three events with the delimiter"
assert_file_text "T3: three events separated by '----'" "${OUT_DIR}/grouped.txt" \
    $'symbol:"A&B",\nprice:55.5,\nqty:100\n----\nsymbol:"IBM",\nprice:-1.25,\nqty:7\n----\nsymbol:"'"${RUN_ID}"$' X",\nprice:0.0,\nqty:9876543210'

log_info "T4: regex groups map to attributes, and the @payload template renders them"
mark_log
text "${REGEX_URL}" "${RUN_ID} 55.6 qty=100" >/dev/null
assert_log_contains "T4: symbol, price and qty extracted" "\[TC74-REGEX\].*data=\[${RUN_ID}, 55\.6, 100\]" 15
assert_file_text "T4: template rendered" "${OUT_DIR}/template.txt" "Stock ${RUN_ID} at 55.6 x100"

log_info "T5: mustache escapes {{ }} and leaves {{{ }}} raw"
assert_file_text "T5: escaped and raw values" "${OUT_DIR}/mustache.txt" \
    $'escaped=A&amp;B raw=A&B\nescaped=IBM raw=IBM\nescaped='"${RUN_ID}"' X raw='"${RUN_ID}"$' X\nescaped='"${RUN_ID}"' raw='"${RUN_ID}"

log_info "T6: a message that doesn't match the regex is dropped with a mapping error"
mark_log
text "${REGEX_URL}" "no match ${RUN_ID}" >/dev/null
assert_log_contains "T6: mapping error logged" "Invalid format of event no match ${RUN_ID} .*fail on missing attribute is 'true'" 15
assert_log_not_contains "T6: unmatched message not emitted" "\[TC74-REGEX\].*no match" 0

log_info "T7: with fail.on.missing.attribute off, a missing group becomes null"
mark_log
text "${BASE_URL}/LenientStream" "${RUN_ID} 12.5 and no quantity" >/dev/null
assert_log_contains "T7: qty null" "\[TC74-LENIENT\].*data=\[${RUN_ID}, 12\.5, null\]" 15

log_info "T8: a grouped message becomes one event per delimited block"
mark_log
text "${BASE_URL}/GroupedStream" $'symbol:"'"${RUN_ID}"$'-1",\nprice:1.0,\nqty:1\n####\nsymbol:"'"${RUN_ID}"$'-2",\nprice:2.0,\nqty:2\n####\nsymbol:"'"${RUN_ID}"$'-3",\nprice:3.0,\nqty:3' >/dev/null
for n in 1 2 3; do
    assert_log_contains "T8: block ${n} emitted" "\[TC74-GROUPED-IN\].*data=\[${RUN_ID}-${n}, ${n}\.0, ${n}\]" 15
done

log_info "T9: the app still processes events after the mapping error"
mark_log
text "${REGEX_URL}" "${RUN_ID}after 1.5 qty=2" >/dev/null
assert_log_contains "T9: event after the error processed" "\[TC74-REGEX\].*data=\[${RUN_ID}after, 1\.5, 2\]" 15

log_info "T10: no class-loading errors"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T10: no class-loading errors during the run" \
    'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

print_summary; tc_exit_code
