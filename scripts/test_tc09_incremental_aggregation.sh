#!/usr/bin/env bash
# TC09: Incremental time-series aggregation with per-granularity retrieval
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC09"

require_si_running
SALES_URL="http://localhost:${PORT_TC09}/TC09_IncrementalAggregation/SalesStream"
QUERY_URL="http://localhost:${PORT_TC09}/TC09_IncrementalAggregation/QueryStream"

# Generate timestamps in epoch milliseconds
NOW_MS=$(python3 -c "import time; print(int(time.time() * 1000))")

log_info "T1: Ingest 5 events for 'chocolate' with current timestamps"
for amount in 10.0 20.0 30.0 15.0 25.0; do
    TS=$(python3 -c "import time; print(int(time.time() * 1000))")
    post_event "${SALES_URL}" "{\"name\":\"chocolate\",\"amount\":${amount},\"timestamp\":${TS}}" >/dev/null
    sleep 0.3
done
assert_log_contains "T1: events accepted by aggregation" '\[TC09-INPUT\].*chocolate' 20

log_info "T2: Ingest 3 events for 'toffee'"
for amount in 50.0 60.0 70.0; do
    TS=$(python3 -c "import time; print(int(time.time() * 1000))")
    post_event "${SALES_URL}" "{\"name\":\"toffee\",\"amount\":${amount},\"timestamp\":${TS}}" >/dev/null
    sleep 0.3
done
assert_log_contains "T2: toffee events processed" '\[TC09-INPUT\].*toffee' 15

log_info "T3: Wait for aggregation to settle, then query with within range"
sleep 3

# Build within range: 2 minutes ago to 1 minute from now (UTC)
START_TIME=$(python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) - timedelta(minutes=2)
print(t.strftime('%Y-%m-%d %H:%M:%S +00:00'))
")
END_TIME=$(python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) + timedelta(minutes=1)
print(t.strftime('%Y-%m-%d %H:%M:%S +00:00'))
")

log_info "  Querying: startTime='${START_TIME}', endTime='${END_TIME}'"

post_event "${QUERY_URL}" "{\"startTime\":\"${START_TIME}\",\"endTime\":\"${END_TIME}\",\"name\":\"chocolate\"}" >/dev/null
assert_log_contains "T3: aggregation result returned for chocolate" '\[TC09-RESULT\].*chocolate' 20

log_info "T4: Query aggregation for 'toffee'"
post_event "${QUERY_URL}" "{\"startTime\":\"${START_TIME}\",\"endTime\":\"${END_TIME}\",\"name\":\"toffee\"}" >/dev/null
assert_log_contains "T4: aggregation result returned for toffee" '\[TC09-RESULT\].*toffee' 15

log_info "T5: Verify result log shows correct min/max (toffee min=50.0, max=70.0)"
assert_log_contains "T5: toffee max=70.0 in aggregation result" '\[TC09-RESULT\].*70' 10

print_summary; tc_exit_code
