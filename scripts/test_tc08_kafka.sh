#!/usr/bin/env bash
# TC08: Kafka source + filtered Kafka sink
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC08"

require_si_running
require_kafka_running
if ! command -v kcat >/dev/null 2>&1; then
    log_fail "kcat is not installed; TC08 produces and consumes with it (brew install kcat)"
    print_summary; exit 1
fi

# si-test-output keeps every run's messages, so each run uses its own names.
RUN_ID="r$(date +%s)"

# Use kcat from the host (no JVM startup overhead, works from host via mapped port).
# broker.address.family=v4 prevents kcat from following the broker's advertised
# 'localhost' address to IPv6 ([::1]:9092), which is not reachable on this host.
KAFKA_OPTS="-X broker.address.family=v4"
produce() {
    printf '{"event":{"name":"%s-%s","amount":%s}}\n' "$1" "${RUN_ID}" "$2" |
        kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t si-test-input -P 2>/dev/null ||
        log_fail "kcat could not produce '$1' to si-test-input"
}

log_info "T1: Wait for Kafka app to start (checking SI log)"
redeploy_app "TC08_KafkaPassThrough.siddhi" TC08_KafkaPassThrough || { print_summary; exit 1; }

log_info "T2: Produce 3 events (2 above filter threshold, 1 below)"
# Events: chocolate(50.0) passes, toffee(5.0) filtered, cake(200.0) passes
produce chocolate 50.0
sleep 0.5
produce toffee 5.0
sleep 0.5
produce cake 200.0
sleep 2

log_info "T3: All 3 events appear in SI log (log sink fires before filter)"
assert_log_contains "T3a: chocolate in log" "\[TC08-KAFKA\].*chocolate-${RUN_ID}" 20
assert_log_contains "T3b: toffee in log" "\[TC08-KAFKA\].*toffee-${RUN_ID}" 15
assert_log_contains "T3c: cake in log" "\[TC08-KAFKA\].*cake-${RUN_ID}" 15

log_info "T4: Consume output Kafka topic - only high-amount events should be there"
OUTPUT_FILE=$(mktemp)
# Use kcat from host — fast native binary, no JVM startup delay
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t si-test-output -C -e -o beginning 2>/dev/null \
    > "${OUTPUT_FILE}" || true

if grep -q "chocolate-${RUN_ID}" "${OUTPUT_FILE}"; then
    log_pass "T4a: 'chocolate' (amount=50.0) in Kafka output"
else
    log_fail "T4a: 'chocolate' not found in Kafka output topic"
fi

if grep -q "cake-${RUN_ID}" "${OUTPUT_FILE}"; then
    log_pass "T4b: 'cake' (amount=200.0) in Kafka output"
else
    log_fail "T4b: 'cake' not found in Kafka output topic"
fi

if grep -q "toffee-${RUN_ID}" "${OUTPUT_FILE}"; then
    log_fail "T4c: 'toffee' (amount=5.0) should be FILTERED OUT but was found in output topic"
else
    log_pass "T4c: 'toffee' correctly filtered from Kafka output (amount <= 10.0)"
fi

rm -f "${OUTPUT_FILE}"

log_info "T5: Produce more events and verify real-time processing"
produce brownie 75.0
assert_log_contains "T5: new event processed in real-time" "\[TC08-KAFKA\].*brownie-${RUN_ID}" 20

print_summary; tc_exit_code
