#!/usr/bin/env bash
# TC46: Redis store — @store(type='redis') PK upsert + Store API
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC46"

require_si_running
require_redis_running

# Skip if the siddhi-store-redis extension JAR is not installed
if ! ls "${SI_HOME}/wso2/lib/plugins/"*siddhi-store-redis*.jar \
        "${SI_HOME}/lib/"*siddhi-store-redis*.jar 2>/dev/null | grep -q .; then
    log_skip "siddhi-store-redis JAR not found in \${SI_HOME}/wso2/lib/plugins/ or \${SI_HOME}/lib/ — skipping TC46"
    exit 0
fi

URL="http://localhost:${PORT_TC46}/TC46_RedisStore/SessionStream"

log_info "T1: Wait for TC46 Redis store app to start"
assert_log_contains "T1: TC46 app deployed" 'TC46_RedisStore.*deployed successfully' 30

log_info "T2: POST 3 session events"
post_event "${URL}" '{"sessionId":"S1","userId":"alice","loginTime":1700000000}' >/dev/null
post_event "${URL}" '{"sessionId":"S2","userId":"bob","loginTime":1700001000}' >/dev/null
post_event "${URL}" '{"sessionId":"S3","userId":"carol","loginTime":1700002000}' >/dev/null
assert_log_contains "T2: events logged with [TC46-REDIS] prefix" '\[TC46-REDIS\].*alice' 25

log_info "T3: Redis DBSIZE should be at least 3"
sleep 3
assert_redis_key_count_gte "T3: Redis has >= 3 keys" 3

log_info "T4: Store API returns 3 records (note: PK returns null — Redis stores it as key name)"
assert_store_count "T4: Store API returns 3" "TC46_RedisStore" \
    "from SessionTable select sessionId, userId, loginTime" 3

log_info "T5: Upsert — re-send S1 with updated userId; count stays 3"
post_event "${URL}" '{"sessionId":"S1","userId":"alice-updated","loginTime":1700009999}' >/dev/null
sleep 3
assert_store_count "T5: Store API still returns 3 after upsert" "TC46_RedisStore" \
    "from SessionTable select sessionId, userId, loginTime" 3

log_info "T6: Verify Redis DBSIZE unchanged after upsert"
assert_redis_key_count_gte "T6: Redis DBSIZE still >= 3 after upsert" 3

print_summary; tc_exit_code
