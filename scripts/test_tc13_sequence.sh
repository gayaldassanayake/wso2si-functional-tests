#!/usr/bin/env bash
# TC13: Sequence detection (consecutive temperature rises >= 5 degrees)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC13"

require_si_running
URL="http://localhost:${PORT_TC13}/TC13_Sequence/TemperatureStream"

log_info "T1 (positive): Send two consecutive readings from s1 with 5-degree rise"
post_event "${URL}" '{"sensorId":"s1","temperature":20.0,"location":"server-room"}' >/dev/null
sleep 0.3
post_event "${URL}" '{"sensorId":"s1","temperature":25.0,"location":"server-room"}' >/dev/null
assert_log_contains "T1: sequence fires for 5-degree rise" '\[TC13-RISE\].*s1' 20

log_info "T2: Verify s1 is in TempRiseTable"
sleep 3
assert_store_count "T2: s1 is in TempRiseTable" "TC13_Sequence" \
    "from TempRiseTable select * having sensorId == 's1'" 1

log_info "T3 (positive): Large rise for s2"
post_event "${URL}" '{"sensorId":"s2","temperature":15.0,"location":"datacenter"}' >/dev/null
sleep 0.3
post_event "${URL}" '{"sensorId":"s2","temperature":40.0,"location":"datacenter"}' >/dev/null
assert_log_contains "T3: sequence fires for s2 (25-degree rise)" '\[TC13-RISE\].*s2' 15
sleep 2
assert_store_count "T3: s2 is in TempRiseTable" "TC13_Sequence" \
    "from TempRiseTable select * having sensorId == 's2'" 1

log_info "T4 (negative): Send two readings with insufficient rise (< 5 degrees)"
post_event "${URL}" '{"sensorId":"s3","temperature":30.0,"location":"lab"}' >/dev/null
sleep 0.3
post_event "${URL}" '{"sensorId":"s3","temperature":33.0,"location":"lab"}' >/dev/null
# 33 - 30 = 3 degrees, which is < 5 - sequence should NOT fire
sleep "${PATTERN_WAIT_SECONDS}"
assert_store_count "T4: s3 not in TempRiseTable (rise < 5 degrees)" "TC13_Sequence" \
    "from TempRiseTable select * having sensorId == 's3'" 0

log_info "T5 (positive): Multiple events for s1 - new sequence fires on next 5+ degree rise"
post_event "${URL}" '{"sensorId":"s1","temperature":25.0,"location":"server-room"}' >/dev/null
sleep 0.3
post_event "${URL}" '{"sensorId":"s1","temperature":31.0,"location":"server-room"}' >/dev/null
assert_log_contains "T5: second sequence fires for s1" '\[TC13-RISE\].*s1' 15

print_summary; tc_exit_code
