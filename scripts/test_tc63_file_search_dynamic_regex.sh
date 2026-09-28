#!/usr/bin/env bash
# TC63: file:search uses each event's regex when it comes from an attribute (wso2/product-integrator-si#377)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC63"

require_si_running

APP_FILE="TC63_FileSearchDynamicRegex.siddhi"
URL="http://localhost:${PORT_TC63}/TC63_FileSearchDynamicRegex/SearchStream"
RUN_ID="tc63-$(date +%s)"

cleanup() { rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"; rm -rf "${TC63_SEARCH_DIR}"; }
trap cleanup EXIT

rm -rf "${TC63_SEARCH_DIR}"
mkdir -p "${TC63_SEARCH_DIR}/sub"
touch "${TC63_SEARCH_DIR}/alpha.txt" "${TC63_SEARCH_DIR}/beta.csv" "${TC63_SEARCH_DIR}/sub/gamma.txt"

undeploy_app "${APP_FILE}"
deploy_app "${APP_FILE}"

log_info "T1: app deploys"
assert_log_contains "T1: TC63 deployed" 'TC63_FileSearchDynamicRegex.*deployed successfully' 30 || { print_summary; exit 1; }

log_info "T2: first event's regex finds its file"
post_event "${URL}" "{\"id\":\"${RUN_ID}-1\",\"regex\":\"alpha\"}" >/dev/null
assert_log_contains "T2: exclude.subdirectories finds alpha.txt" "\[TC63-FLAT\].*${RUN_ID}-1, \[[^]]*/alpha\.txt\]" 20
assert_log_contains "T2: subdirectory.depth finds alpha.txt" "\[TC63-DEPTH\].*${RUN_ID}-1, \[[^]]*/alpha\.txt\]" 20

log_info "T3: second event's regex is used, not the first one's"
post_event "${URL}" "{\"id\":\"${RUN_ID}-2\",\"regex\":\"beta\"}" >/dev/null
assert_log_contains "T3: exclude.subdirectories finds beta.csv" "\[TC63-FLAT\].*${RUN_ID}-2, \[[^]]*/beta\.csv\]" 20
assert_log_contains "T3: subdirectory.depth finds beta.csv" "\[TC63-DEPTH\].*${RUN_ID}-2, \[[^]]*/beta\.csv\]" 20

log_info "T4: a subdirectory file is found only by the depth search"
post_event "${URL}" "{\"id\":\"${RUN_ID}-3\",\"regex\":\"gamma\"}" >/dev/null
assert_log_contains "T4: subdirectory.depth finds sub/gamma.txt" "\[TC63-DEPTH\].*${RUN_ID}-3, \[[^]]*/sub/gamma\.txt\]" 20
assert_log_contains "T4: exclude.subdirectories returns []" "\[TC63-FLAT\].*${RUN_ID}-3, \[\]\]" 20

log_info "T5: a regex with no match returns []"
post_event "${URL}" "{\"id\":\"${RUN_ID}-4\",\"regex\":\"no-match\"}" >/dev/null
assert_log_contains "T5: exclude.subdirectories returns []" "\[TC63-FLAT\].*${RUN_ID}-4, \[\]\]" 20
assert_log_contains "T5: subdirectory.depth returns []" "\[TC63-DEPTH\].*${RUN_ID}-4, \[\]\]" 20

print_summary; tc_exit_code
