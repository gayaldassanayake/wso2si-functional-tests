#!/usr/bin/env bash
# TC44: HTTP request/response — http-request sink + http-response source (sink.id),
#       http-service source + http-service-response sink (source.id/message.id)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC44"

require_si_running

TRIGGER_URL="http://localhost:${PORT_TC44}/TC44_HttpRequestResponse/TriggerStream"

log_info "T1: Wait for TC44 app to start"
assert_log_contains "T1: TC44 app deployed" 'TC44_HttpRequestResponse.*deployed successfully' 30

log_info "T2: POST to TriggerStream — fires http-request to http-service echo endpoint"
post_event "${TRIGGER_URL}" '{"name":"Sigma","value":3.14}' >/dev/null
# Log format: data=[Sigma, 3.14] — match on value not field=value
assert_log_contains "T2: http-service received request" '\[TC44-RECV\].*Sigma' 60

log_info "T3: http-service-response → http-response source captured the echo reply"
assert_log_contains "T3: http-response received reply" '\[TC44-RESPONSE\].*Sigma' 20

log_info "T4: Send a second event — verify both correlation paths remain live"
post_event "${TRIGGER_URL}" '{"name":"Delta","value":2.71}' >/dev/null
assert_log_contains "T4a: second event in RECV" '\[TC44-RECV\].*Delta' 20
assert_log_contains "T4b: second event in RESPONSE" '\[TC44-RESPONSE\].*Delta' 15

print_summary; tc_exit_code
