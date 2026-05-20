#!/usr/bin/env bash
# TC45: RabbitMQ source + filter + sink pass-through
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC45"

require_si_running
require_rabbitmq_running

# Skip if the siddhi-io-rabbitmq extension JARs are not installed
if ! ls "${SI_HOME}/lib/"*rabbitmq*.jar "${SI_HOME}/wso2/lib/plugins/"*rabbitmq*.jar 2>/dev/null | grep -q .; then
    log_skip "siddhi-io-rabbitmq JARs not found in \${SI_HOME}/lib/ or \${SI_HOME}/wso2/lib/plugins/ — skipping TC45"
    exit 0
fi

IN_EXCHANGE="si-test-rmq-in"
IN_ROUTING_KEY="si-test-rmq-in-q"
OUT_QUEUE="si-test-rmq-out-q"

log_info "T1: Wait for TC45 RabbitMQ app to start"
assert_log_contains "T1: TC45 app deployed" 'TC45_RabbitMQPassThrough.*deployed successfully' 30

log_info "T2: Publish 2 events — cake(50.0) above filter, toffee(5.0) below"
rabbitmq_publish "${IN_EXCHANGE}" "${IN_ROUTING_KEY}" '{"event":{"name":"cake","amount":50.0}}'
sleep 0.5
rabbitmq_publish "${IN_EXCHANGE}" "${IN_ROUTING_KEY}" '{"event":{"name":"toffee","amount":5.0}}'
sleep 2

log_info "T3: Both events appear in SI log (log sink fires before filter)"
assert_log_contains "T3a: cake in SI log" '\[TC45-RABBIT\].*cake' 20
assert_log_contains "T3b: toffee in SI log" '\[TC45-RABBIT\].*toffee' 15

log_info "T4: Consume output queue — cake (50.0 > 10) must be there, toffee (5.0 <= 10) must be absent"
sleep 2
OUTPUT=$(rabbitmq_get "${OUT_QUEUE}" 10)

if echo "${OUTPUT}" | grep -q 'cake'; then
    log_pass "T4a: 'cake' (amount=50.0) present in output queue"
else
    log_fail "T4a: 'cake' not found in RabbitMQ output queue"
fi

if echo "${OUTPUT}" | grep -q 'toffee'; then
    log_fail "T4b: 'toffee' (amount=5.0) should be FILTERED OUT but was found in output queue"
else
    log_pass "T4b: 'toffee' correctly filtered from output queue (amount <= 10.0)"
fi

log_info "T5: Publish another event and verify real-time processing"
rabbitmq_publish "${IN_EXCHANGE}" "${IN_ROUTING_KEY}" '{"event":{"name":"brownie","amount":75.0}}'
assert_log_contains "T5: new event processed" '\[TC45-RABBIT\].*brownie' 20

print_summary; tc_exit_code
