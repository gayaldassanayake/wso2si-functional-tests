#!/usr/bin/env bash
# TC08: Kafka source + filtered Kafka sink
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC08"

require_si_running
require_kafka_running

# Use kcat from the host (no JVM startup overhead, works from host via mapped port).
# broker.address.family=v4 prevents kcat from following the broker's advertised
# 'localhost' address to IPv6 ([::1]:9092), which is not reachable on this host.
KAFKA_OPTS="-X broker.address.family=v4"
KAFKA_PRODUCER="kcat -b ${KAFKA_BOOTSTRAP} ${KAFKA_OPTS} -t si-test-input -P"

log_info "T1: Wait for Kafka app to start (checking SI log)"
assert_log_contains "T1: Kafka app started" 'TC08_KafkaPassThrough.*deployed successfully' 30

log_info "T2: Produce 3 events (2 above filter threshold, 1 below)"
# Events: chocolate(50.0) passes, toffee(5.0) filtered, cake(200.0) passes
printf '{"event":{"name":"chocolate","amount":50.0}}\n' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 0.5
printf '{"event":{"name":"toffee","amount":5.0}}\n' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 0.5
printf '{"event":{"name":"cake","amount":200.0}}\n' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 2

log_info "T3: All 3 events appear in SI log (log sink fires before filter)"
assert_log_contains "T3a: chocolate in log" '\[TC08-KAFKA\].*chocolate' 20
assert_log_contains "T3b: toffee in log" '\[TC08-KAFKA\].*toffee' 15
assert_log_contains "T3c: cake in log" '\[TC08-KAFKA\].*cake' 15

log_info "T4: Consume output Kafka topic - only high-amount events should be there"
OUTPUT_FILE=$(mktemp)
# Use kcat from host — fast native binary, no JVM startup delay
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t si-test-output -C -e -o beginning 2>/dev/null \
    > "${OUTPUT_FILE}" || true

if grep -q 'chocolate' "${OUTPUT_FILE}"; then
    log_pass "T4a: 'chocolate' (amount=50.0) in Kafka output"
else
    log_fail "T4a: 'chocolate' not found in Kafka output topic"
fi

if grep -q 'cake' "${OUTPUT_FILE}"; then
    log_pass "T4b: 'cake' (amount=200.0) in Kafka output"
else
    log_fail "T4b: 'cake' not found in Kafka output topic"
fi

if grep -q 'toffee' "${OUTPUT_FILE}"; then
    log_fail "T4c: 'toffee' (amount=5.0) should be FILTERED OUT but was found in output topic"
else
    log_pass "T4c: 'toffee' correctly filtered from Kafka output (amount <= 10.0)"
fi

rm -f "${OUTPUT_FILE}"

log_info "T5: Produce more events and verify real-time processing"
printf '{"event":{"name":"brownie","amount":75.0}}\n' | eval "${KAFKA_PRODUCER}" 2>/dev/null
assert_log_contains "T5: new event processed in real-time" '\[TC08-KAFKA\].*brownie' 20

print_summary; tc_exit_code
