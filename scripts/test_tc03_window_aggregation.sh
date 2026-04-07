#!/usr/bin/env bash
# TC03: Window aggregations (time window + length-batch)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC03"

require_si_running
URL="http://localhost:${PORT_TC03}/TC03_WindowAggregation/SensorStream"

log_info "T1: Send 3 events (reading=10.0 each) - lengthBatch(3) should fire"
for i in 1 2 3; do
    post_event "${URL}" '{"sensorId":"s1","reading":10.0}' >/dev/null
    sleep 0.2
done
assert_log_contains "T1: batch window fires after 3 events" '\[TC03-BATCH\]' 20

log_info "T2: Verify batch total is 30.0 in log output"
assert_log_contains "T2: totalReading=30.0 in batch output" '\[TC03-BATCH\].*30' 10

log_info "T3: Send 3 more events (reading=20.0) - second batch fires"
for i in 1 2 3; do
    post_event "${URL}" '{"sensorId":"s1","reading":20.0}' >/dev/null
    sleep 0.2
done
assert_log_contains "T3: second batch fires (totalReading=60)" '\[TC03-BATCH\].*60' 15

log_info "T4: Time window fires for s2 - send events and wait"
for i in 1 2 3; do
    post_event "${URL}" '{"sensorId":"s2","reading":50.0}' >/dev/null
    sleep 0.2
done
assert_log_contains "T4: time window output for s2" '\[TC03-TIME\].*s2' 20

log_info "T5: Verify Store API batch result table"
assert_store_count "T5: WindowResultTable has batch entry" "TC03_WindowAggregation" \
    "from WindowResultTable select *" 1

print_summary; tc_exit_code
