#!/usr/bin/env bash
# TC51: JavaScript js:eval extension
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC51"

require_si_running
URL="http://localhost:${PORT_TC51}/TC51_JavaScriptEval/ExpressionStream"

undeploy_app "TC51_JavaScriptEval.siddhi"
deploy_app   "TC51_JavaScriptEval.siddhi"
assert_app_deployed "app deployed" TC51_JavaScriptEval 30

log_info "T1: js:eval calculates an arithmetic expression and true condition"
post_event "${URL}" '{"expressionId":"calc-1","arithmeticExpression":"6 * 7","conditionExpression":"42 > 10"}' >/dev/null
assert_log_contains "T1: arithmetic expression evaluates to 42" '\[TC51-EVAL\].*data=\[calc-1, 42, ' 20
assert_log_contains "T1: boolean expression evaluates to true" '\[TC51-EVAL\].*data=\[calc-1, [^,]*, true\]' 10

log_info "T2: js:eval evaluates false independently"
post_event "${URL}" '{"expressionId":"calc-2","arithmeticExpression":"10 / 4","conditionExpression":"3 > 9"}' >/dev/null
assert_log_contains "T2: arithmetic expression evaluates to 2.5" '\[TC51-EVAL\].*data=\[calc-2, 2\.5, ' 20
assert_log_contains "T2: boolean expression evaluates to false" '\[TC51-EVAL\].*data=\[calc-2, [^,]*, false\]' 10

print_summary; tc_exit_code
