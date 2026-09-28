#!/usr/bin/env bash
# TC59: Siddhi keywords (offset, in, per, at, set) as attribute names (EIINTERNAL-1239)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC59"

require_si_running

APP_FILE="TC59_KeywordAttributeNames.siddhi"
URL="http://localhost:${PORT_TC59}/TC59_KeywordAttributeNames/KeywordStream"
RUN_ID="tc59-$(date +%s)"

cleanup() { rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"; }
trap cleanup EXIT

undeploy_app "${APP_FILE}"
deploy_app "${APP_FILE}"

log_info "T1: app using keyword attribute names deploys"
assert_log_contains "T1: TC59 deployed" 'TC59_KeywordAttributeNames.*deployed successfully' 30 || { print_summary; exit 1; }
assert_log_not_contains "T1: no parser error" 'SiddhiParserException.*TC59|mismatched input.*offset' 1

log_info "T2: filter and select on keyword attributes"
post_event "${URL}" "{\"offset\":7,\"name\":\"${RUN_ID}\",\"in\":\"x\",\"per\":3,\"at\":1700000000000,\"set\":\"s1\"}" >/dev/null
assert_log_contains "T2: event logged with all keyword attributes" "\[TC59\].*data=\[7, ${RUN_ID}, x, 3, 1700000000000, s1\]" 20

log_info "T3: on-demand query selects and filters on offset"
RESULT=$(store_query "TC59_KeywordAttributeNames" "from KeywordTable on offset == 7 select offset, name")
if grep -q "${RUN_ID}" <<< "${RESULT}"; then
    log_pass "T3: store query returned the row by offset"
else
    log_fail "T3: store query did not return the row: ${RESULT}"
fi

print_summary; tc_exit_code
