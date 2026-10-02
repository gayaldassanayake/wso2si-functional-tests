#!/usr/bin/env bash
# TC56: Kafka source/sink options from deployment.yaml (EIINTERNAL-637)
#
# STANDALONE — do NOT run while SI is already running on port SI_HTTP_PORT.
# It appends a siddhi.extensions block to deployment.yaml, starts SI, and
# restores deployment.yaml and stops SI on exit.
#
# Usage:
#   SI_HOME=/path/to/wso2si-4.4.1-SNAPSHOT bash scripts/test_tc56_kafka_deployment_config.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC56"

APP_FILE="TC56_KafkaDeploymentConfig.siddhi"
DEPLOYMENT_YAML="${SI_HOME}/conf/server/deployment.yaml"
BACKUP_YAML="${DEPLOYMENT_YAML}.tc56.bak"
KAFKA_OPTS="-X broker.address.family=v4"
RUN_ID="tc56-$(date +%s)"

require_file "${SI_HOME}/bin/server.sh"
require_file "${DEPLOYMENT_YAML}"
require_kafka_running

if nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo "[ERROR] A server is already running on port ${SI_HTTP_PORT}. Stop it before running TC56."
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

cleanup() {
    sh "${SI_HOME}/bin/server.sh" stop >/dev/null 2>&1 || true
    local elapsed=0
    while nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null && (( elapsed < 30 )); do
        sleep 1
        (( elapsed++ )) || true
    done
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    [[ -f "${BACKUP_YAML}" ]] && mv "${BACKUP_YAML}" "${DEPLOYMENT_YAML}"
}
trap cleanup EXIT

for topic in si-test-tc56-input si-test-tc56-output; do
    docker exec "${KAFKA_CONTAINER}" kafka-topics --bootstrap-server localhost:9092 \
        --create --topic "${topic}" --partitions 1 --replication-factor 1 --if-not-exists >/dev/null 2>&1 || true
done

cp "${DEPLOYMENT_YAML}" "${BACKUP_YAML}" || { echo -e "${RED}[ERROR]${NC} Could not back up ${DEPLOYMENT_YAML}; not patching it"; exit 1; }
cat >> "${DEPLOYMENT_YAML}" <<'EOF'

siddhi:
  extensions:
    - extension:
        name: kafka
        namespace: source
        properties:
          optional.configuration: "client.id:tc56-cfgtest"
    - extension:
        name: kafka
        namespace: sink
        properties:
          bootstrap.servers: "127.0.0.1:9092"
EOF

cp "${SUITE_ROOT}/siddhi-apps/${APP_FILE}" "${SI_SIDDHI_DIR}/"

LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0)
# SI truncates carbon.log on startup, so read it whole once it is shorter than the recorded offset.
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
        new_log | grep -qE "${pattern}" && return 0
        sleep 2
        (( elapsed += 2 )) || true
    done
    return 1
}

log_info "T1: SI starts with the patched deployment.yaml and deploys the app"
sh "${SI_HOME}/bin/server.sh" start >/dev/null 2>&1
if wait_new_log 'WSO2 Streaming Integrator started' 180 &&
        wait_new_log 'TC56_KafkaDeploymentConfig.*deployed successfully' 60; then
    log_pass "T1: server started and TC56 app deployed"
else
    log_fail "T1: server did not start or TC56 app did not deploy"
    print_summary; exit 1
fi

log_info "T2: source consumer uses client.id from deployment.yaml optional.configuration"
CLIENT_IDS=""
for _ in $(seq 1 30); do
    CLIENT_IDS=$(docker exec "${KAFKA_CONTAINER}" kafka-consumer-groups --bootstrap-server localhost:9092 \
        --describe --group tc56-group --members 2>/dev/null | awk 'NR>1 && $1=="tc56-group" {print $4}')
    [[ -n "${CLIENT_IDS}" ]] && break
    sleep 2
done
if [[ "${CLIENT_IDS}" == "tc56-cfgtest" ]]; then
    log_pass "T2: consumer group tc56-group CLIENT-ID is tc56-cfgtest"
else
    log_fail "T2: expected CLIENT-ID tc56-cfgtest, got '${CLIENT_IDS:-<no members>}'"
fi

log_info "T3: events published to the input topic reach the source"
for item in "${RUN_ID}-a:10.5" "${RUN_ID}-b:20.0"; do
    printf '{"event":{"name":"%s","amount":%s}}\n' "${item%%:*}" "${item##*:}" |
        kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t si-test-tc56-input -P 2>/dev/null
done
if wait_new_log "\[TC56-KAFKA\].*${RUN_ID}-b" 30; then
    log_pass "T3: both events logged with [TC56-KAFKA] prefix"
else
    log_fail "T3: events not received by the Kafka source"
fi

log_info "T4: sink publishes through bootstrap.servers from deployment.yaml (app value is a closed port)"
OUTPUT=""
for _ in $(seq 1 15); do
    OUTPUT=$(kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t si-test-tc56-output -C -e -o beginning 2>/dev/null || true)
    grep -q "${RUN_ID}-b" <<< "${OUTPUT}" && break
    sleep 2
done
if grep -q "${RUN_ID}-a" <<< "${OUTPUT}" && grep -q "${RUN_ID}-b" <<< "${OUTPUT}"; then
    log_pass "T4: both events found in si-test-tc56-output"
else
    log_fail "T4: events missing from si-test-tc56-output"
fi

print_summary; tc_exit_code
