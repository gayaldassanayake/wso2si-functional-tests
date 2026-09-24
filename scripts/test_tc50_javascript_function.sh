#!/usr/bin/env bash
# TC50: JavaScript script function extension
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC50"

require_si_running
URL="http://localhost:${PORT_TC50}/TC50_JavaScriptFunction/ProfileStream"

undeploy_app "TC50_JavaScriptFunction.siddhi"
deploy_app   "TC50_JavaScriptFunction.siddhi"
assert_log_contains "app deployed" 'TC50_JavaScriptFunction.*deployed successfully' 30

log_info "T1: JavaScript function trims and uppercases a name"
post_event "${URL}" '{"profileId":"p1","firstName":"  ada","lastName":"lovelace  "}' >/dev/null
assert_log_contains "T1: JavaScript greeting is emitted" '\[TC50-JS\].*p1.*HELLO ADA LOVELACE' 20

log_info "T2: JavaScript function handles another independent event"
post_event "${URL}" '{"profileId":"p2","firstName":"Grace","lastName":"Hopper"}' >/dev/null
assert_log_contains "T2: JavaScript greeting preserves event isolation" '\[TC50-JS\].*p2.*HELLO GRACE HOPPER' 20

print_summary; tc_exit_code
