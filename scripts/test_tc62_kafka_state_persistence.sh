#!/usr/bin/env bash
# TC62: Kafka source under periodic state persistence and restart (BNYMDMAPROD-250)
#
# STANDALONE — do NOT run while SI is already running on port SI_HTTP_PORT.
# It enables state.persistence in deployment.yaml, starts SI, and restores
# deployment.yaml and stops SI on exit. Takes about 6 minutes.
#
# Usage:
#   SI_HOME=/path/to/wso2si-4.4.1-SNAPSHOT bash scripts/test_tc62_kafka_state_persistence.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC62"

APP_FILE="TC62_KafkaPersistence.siddhi"
APP_NAME="TC62_KafkaPersistence"
DEPLOYMENT_YAML="${SI_HOME}/conf/server/deployment.yaml"
BACKUP_YAML="${DEPLOYMENT_YAML}.tc62.bak"
KAFKA_OPTS="-X broker.address.family=v4"
RUN_ID="r$(date +%s)"
TOPIC="si-test-tc62-${RUN_ID}"
OUT="${TC62_OUT_FILE}"

require_file "${SI_HOME}/bin/server.sh"
require_file "${DEPLOYMENT_YAML}"
require_kafka_running

if nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo "[ERROR] A server is already running on port ${SI_HTTP_PORT}. Stop it before running TC62."
    exit 1
fi

if ! ls "${SI_HOME}/lib/"*kafka*clients*.jar >/dev/null 2>&1; then
    log_skip "Kafka client bundles not found in \${SI_HOME}/lib/ - run extension-installer.sh install kafka first"
    exit "${SKIP_EXIT_CODE}"
fi

if [[ -f "${BACKUP_YAML}" ]]; then
    echo "[ERROR] ${BACKUP_YAML} exists from an earlier run. Restore it to deployment.yaml and delete it first."
    exit 1
fi

stop_si() {
    sh "${SI_HOME}/bin/server.sh" stop >/dev/null 2>&1 || true
    local elapsed=0
    while nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null && (( elapsed < 60 )); do
        sleep 1
        (( elapsed++ )) || true
    done
}

cleanup() {
    stop_si
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    [[ -f "${BACKUP_YAML}" ]] && mv "${BACKUP_YAML}" "${DEPLOYMENT_YAML}"
    docker exec "${KAFKA_CONTAINER}" kafka-topics --bootstrap-server localhost:9092 \
        --delete --topic "${TOPIC}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
# carbon.log may be truncated on startup.
new_log() {
    local size
    size=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
    if (( size < LOG_OFFSET )); then
        cat "${SI_LOG}"
    else
        tail -c "+$(( LOG_OFFSET + 1 ))" "${SI_LOG}"
    fi 2>/dev/null
}

wait_new_log() {
    local pattern="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        new_log | grep -E "${pattern}" >/dev/null && return 0
        sleep 2
        (( elapsed += 2 )) || true
    done
    return 1
}

start_si() {
    LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
    sh "${SI_HOME}/bin/server.sh" start >/dev/null 2>&1
    wait_new_log 'WSO2 Streaming Integrator started' 180 &&
        wait_new_log "${APP_NAME} deployed successfully" 60
}

send() {
    local i
    for i in $(seq "$1" "$2"); do
        printf '%s-%03d:{"event":{"id":"%s-%03d","seq":%d}}\n' "${RUN_ID}" "$i" "${RUN_ID}" "$i" "$i" |
            kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t "${TOPIC}" -K: -P 2>/dev/null || true
        sleep 1
    done
}
out_total() { [[ -f "${OUT}" ]] && { grep -c "${RUN_ID}-" "${OUT}" || true; } || echo 0; }
out_unique() { [[ -f "${OUT}" ]] && { grep -o "${RUN_ID}-[0-9]*" "${OUT}" | sort -u | wc -l | tr -d ' '; } || echo 0; }
wait_out() {
    local n="$1" timeout="$2" elapsed=0
    while (( $(out_total) < n && elapsed < timeout )); do
        sleep 2
        (( elapsed += 2 )) || true
    done
}
persist_count() { new_log | grep -c "Kafka Adapter paused for topic(s): ${TOPIC}" || true; }
wait_persist_above() {
    local n="$1" timeout="$2" elapsed=0
    while (( $(persist_count) <= n && elapsed < timeout )); do
        sleep 2
        (( elapsed += 2 )) || true
    done
    (( $(persist_count) > n ))
}
check_counts() {
    local label="$1" expected="$2" total unique
    total=$(out_total); unique=$(out_unique)
    if [[ "${total}" == "${expected}" && "${unique}" == "${expected}" ]]; then
        log_pass "${label}: ${total} events emitted, all unique"
    else
        log_fail "${label}: expected ${expected} events, got ${total} (${unique} unique)"
    fi
}

rm -f "${OUT}"
find "${SI_HOME}" -type d -name "${APP_NAME}" -path '*siddhi-app-persistence*' -prune -exec rm -rf {} + 2>/dev/null || true
docker exec "${KAFKA_CONTAINER}" kafka-topics --bootstrap-server localhost:9092 \
    --create --topic "${TOPIC}" --partitions 4 --replication-factor 1 >/dev/null 2>&1 || true

cp "${DEPLOYMENT_YAML}" "${BACKUP_YAML}"
perl -0pi -e 's/(state\.persistence:\n  enabled: )false/${1}true/' "${DEPLOYMENT_YAML}"
if ! { grep -A2 '^state.persistence:' "${DEPLOYMENT_YAML}" | grep -q 'enabled: true' &&
        grep -A2 '^state.persistence:' "${DEPLOYMENT_YAML}" | grep -q 'intervalInMin: 1'; }; then
    echo "[ERROR] deployment.yaml patch did not apply"
    exit 1
fi
sed "s/@RUN_ID@/${RUN_ID}/g" "${SUITE_ROOT}/siddhi-apps/${APP_FILE}" > "${SI_SIDDHI_DIR}/${APP_FILE}"

log_info "T1: SI starts with state persistence and the source is assigned all 4 partitions"
if start_si; then
    log_pass "T1: server started and ${APP_NAME} deployed"
else
    log_fail "T1: server did not start or ${APP_NAME} did not deploy"
    print_summary; exit 1
fi
if wait_new_log "Adding partitions \\[0, 1, 2, 3\\] for topic: ${TOPIC}" 30; then
    log_pass "T1: source assigned partitions 0-3"
else
    log_fail "T1: source did not assign partitions 0-3 of ${TOPIC}"
    print_summary; exit 1
fi

log_info "T2: 100 events at 1/s across persistence cycles are each emitted once"
P0=$(persist_count)
send 1 100
P_SENT=$(persist_count)
wait_persist_above "${P_SENT}" 75 || log_warn "T2: no persistence cycle after the last event"
wait_out 100 60
sleep 5
check_counts "T2" 100
CYCLES=$(( $(persist_count) - P0 ))
if (( CYCLES >= 2 )); then
    log_pass "T2: ${CYCLES} persistence cycles while events flowed"
else
    log_fail "T2: only ${CYCLES} persistence cycles while events flowed; the pause/resume path was not exercised"
fi
SEEKS=$(new_log | grep -c 'Seeking partition' || true)
if [[ "${SEEKS}" == "0" ]]; then
    log_pass "T2: no consumer seek-back on resume"
else
    log_fail "T2: consumer seeked back ${SEEKS} times during persistence cycles"
fi

log_info "T3: after a restart only the 10 new events are emitted"
stop_si
if start_si; then
    log_pass "T3: server restarted and ${APP_NAME} deployed"
else
    log_fail "T3: server did not restart"
    print_summary; exit 1
fi
if wait_new_log "State loaded for ${APP_NAME}" 30; then
    log_pass "T3: persisted state restored"
else
    log_fail "T3: no 'State loaded for ${APP_NAME}' in the log"
fi
send 101 110
wait_out 110 60
sleep 10
check_counts "T3" 110

log_info "T4: no late duplicates after the next persistence cycle"
P_NOW=$(persist_count)
if wait_persist_above "${P_NOW}" 90; then
    sleep 5
    check_counts "T4" 110
else
    log_skip "T4: no persistence cycle within 90s after the restart"
fi

print_summary; tc_exit_code
