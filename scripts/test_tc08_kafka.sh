#!/usr/bin/env bash
# TC08: Kafka source + filtered Kafka sink
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC08"

require_si_running
require_kafka_running

KAFKA_PRODUCER="docker exec -i ${KAFKA_CONTAINER} kafka-console-producer --bootstrap-server localhost:9092 --topic si-test-input"

log_info "T1: Wait for Kafka app to start (checking SI log)"
assert_log_contains "T1: Kafka app started" 'TC08_KafkaPassThrough.*Started Successfully' 30

log_info "T2: Produce 3 events (2 above filter threshold, 1 below)"
# Events: chocolate(50.0) passes, toffee(5.0) filtered, cake(200.0) passes
echo '{"event":{"name":"chocolate","amount":50.0}}' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 0.5
echo '{"event":{"name":"toffee","amount":5.0}}' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 0.5
echo '{"event":{"name":"cake","amount":200.0}}' | eval "${KAFKA_PRODUCER}" 2>/dev/null
sleep 2

log_info "T3: All 3 events appear in SI log (log sink fires before filter)"
assert_log_contains "T3a: chocolate in log" '\[TC08-KAFKA\].*chocolate' 20
assert_log_contains "T3b: toffee in log" '\[TC08-KAFKA\].*toffee' 10
assert_log_contains "T3c: cake in log" '\[TC08-KAFKA\].*cake' 10

log_info "T4: Consume output Kafka topic - only high-amount events should be there"
OUTPUT_FILE=$(mktemp)
timeout 15 docker exec "${KAFKA_CONTAINER}" \
    kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic si-test-output \
    --from-beginning \
    --timeout-ms 10000 \
    > "${OUTPUT_FILE}" 2>/dev/null || true

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
echo '{"event":{"name":"brownie","amount":75.0}}' | eval "${KAFKA_PRODUCER}" 2>/dev/null
assert_log_contains "T5: new event processed in real-time" '\[TC08-KAFKA\].*brownie' 20

print_summary; tc_exit_code
