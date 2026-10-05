#!/usr/bin/env bash
# TC66: siddhi-execution-map JSON and XML functions on the org.json and commons-lang3 copies it embeds
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC66"

require_si_running

APP_FILE="TC66_MapFunctions.siddhi"
BASE_URL="http://localhost:${PORT_TC66}/TC66_MapFunctions"
RUN_ID="tc66-$(date +%s)"

cleanup() { rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"; }
trap cleanup EXIT

undeploy_app "${APP_FILE}"
deploy_app "${APP_FILE}"

log_info "T1: app deploys"
assert_app_deployed "T1: TC66 deployed" TC66_MapFunctions 30 || { print_summary; exit 1; }

log_info "T2: createFromJSON keeps Integer, Long and Double values"
post_event "${BASE_URL}/JsonStream" "{\"id\":\"${RUN_ID}-types\",\"json\":\"{'count':1,'volume':12345678901,'price':1.5,'big':12345678901234567890,'nested':{'rate':0.25},'symbol':'WSO2'}\"}" >/dev/null
assert_log_contains "T2: count Integer, volume Long; price, big and nested rate Double" \
    "\[TC66-JSON\].*data=\[${RUN_ID}-types, true, true, true, true, true, WSO2\]" 20

log_info "T3: createFromJSON rejects deeply nested JSON without a StackOverflowError"
deep=$(python3 -c "print(\"{'a':\" * 10000 + '1' + '}' * 10000)")
# siddhi-execution-map 5.0.7 overflows the stack here and the request never returns.
curl -s -o /dev/null --max-time 30 -X POST -H "Content-Type: application/json" \
    -d "{\"event\":{\"id\":\"${RUN_ID}-deep\",\"json\":\"${deep}\"}}" "${BASE_URL}/JsonStream" ||
    log_fail "T3: deep JSON request got no response within 30s"
assert_log_contains "T3: createFromJSON reports the event it can't parse" "Error in 'TC66_MapFunctions' .*Cannot create JSON from" 20
assert_log_contains "T3: nesting depth reported as a JSONException" 'JSONException: JSON Array or Object depth too large to process' 5

log_info "T4: the app still processes events after the deep JSON"
post_event "${BASE_URL}/JsonStream" "{\"id\":\"${RUN_ID}-after\",\"json\":\"{'count':2,'volume':3,'price':4.5,'big':5.5,'nested':{'rate':6.5},'symbol':'IBM'}\"}" >/dev/null
assert_log_contains "T4: event after the deep JSON processed" "\[TC66-JSON\].*data=\[${RUN_ID}-after, true, false, true, true, true, IBM\]" 20

log_info "T5: toJSON keeps null values"
post_event "${BASE_URL}/ToJsonStream" "{\"id\":\"${RUN_ID}-null\",\"symbol\":\"WSO2\",\"note\":null}" >/dev/null
assert_log_contains "T5: null note written as null" "\[TC66-TOJSON\].*data=\[${RUN_ID}-null, .*\"note\":null" 20
assert_log_contains "T5: symbol written" "\[TC66-TOJSON\].*data=\[${RUN_ID}-null, .*\"symbol\":\"WSO2\"" 5

log_info "T6: toJSON writes non-null values"
post_event "${BASE_URL}/ToJsonStream" "{\"id\":\"${RUN_ID}-value\",\"symbol\":\"IBM\",\"note\":\"hi\"}" >/dev/null
assert_log_contains "T6: note written" "\[TC66-TOJSON\].*data=\[${RUN_ID}-value, .*\"note\":\"hi\"" 20

log_info "T7: createFromXML detects numbers; a leading '+' stays a string"
post_event "${BASE_URL}/XmlStream" "{\"id\":\"${RUN_ID}-xml\",\"xml\":\"<r><neg>-2</neg><dec>1.5</dec><plus>+1</plus></r>\"}" >/dev/null
assert_log_contains "T7: neg Long, dec Double, plus String '+1'" "\[TC66-XML\].*data=\[${RUN_ID}-xml, true, true, true, \+1\]" 20

print_summary; tc_exit_code
