#!/usr/bin/env bash
# TC58: Avro sink/source mapping over Kafka (siddhi-map-avro)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC58"

require_si_running
require_kafka_running

APP="TC58_AvroKafkaRoundTrip.siddhi"
URL="http://localhost:${PORT_TC58}/TC58_AvroKafkaRoundTrip/SweetInStream"
TOPIC="tc58-avro"
KAFKA_OPTS="-X broker.address.family=v4"
RUN_ID=$(date +%s)
WORK_DIR=$(mktemp -d)

LOG_OFFSET=0
mark_log() { LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0); }
new_log() { tail -c "+$(( LOG_OFFSET + 1 ))" "${SI_LOG}" 2>/dev/null; }

wait_new_log() {
    local pattern="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        new_log | grep -qE "${pattern}" && return 0
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

# Avro binary encoding of the TC58 "sweet" record: zigzag-varint string length, UTF-8 bytes, little-endian double.
avro_encode() {
    python3 - "$1" "$2" <<'EOF'
import struct, sys
name, amount = sys.argv[1].encode(), float(sys.argv[2])
n = len(name) << 1
out = bytearray()
while n > 0x7f:
    out.append((n & 0x7f) | 0x80)
    n >>= 7
out.append(n)
sys.stdout.buffer.write(bytes(out) + name + struct.pack('<d', amount))
EOF
}

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# run_all_tests.sh may have deployed the app already; wait for SI to drop it so T1 sees a fresh deployment.
if [[ -f "${SI_SIDDHI_DIR}/${APP}" ]]; then
    mark_log
    undeploy_app "${APP}"
    wait_new_log 'TC58_AvroKafkaRoundTrip undeployed successfully' 30 || log_warn "TC58 app undeploy not confirmed"
fi

log_info "T1: Avro mapped Kafka app deploys"
mark_log
deploy_app "${APP}"
if wait_new_log 'TC58_AvroKafkaRoundTrip.*deployed successfully' 30; then
    log_pass "T1: TC58_AvroKafkaRoundTrip deployed"
else
    log_fail "T1: TC58_AvroKafkaRoundTrip did not deploy"
    new_log | grep -E 'ERROR|Exception' | head -5 >&2
    print_summary; tc_exit_code; exit
fi

log_info "T2: HTTP event -> Avro Kafka sink -> Avro Kafka source -> log"
NAME_SINK="sink-${RUN_ID}"
STATUS=$(post_event "${URL}" "{\"name\":\"${NAME_SINK}\",\"amount\":50.25}")
[[ "${STATUS}" == "200" ]] || log_fail "T2: HTTP source returned ${STATUS}"
if wait_new_log "\[TC58-AVRO\].*${NAME_SINK}, 50\.25" 20; then
    log_pass "T2: ${NAME_SINK} round-tripped through Avro over Kafka"
else
    log_fail "T2: ${NAME_SINK} not decoded by the Avro Kafka source"
fi

log_info "T3: Kafka topic holds the Avro binary record, not JSON"
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t "${TOPIC}" -C -e -o beginning -f '%s' \
    > "${WORK_DIR}/topic.bin" 2>/dev/null || true
avro_encode "${NAME_SINK}" 50.25 > "${WORK_DIR}/expected.bin"
if python3 -c 'import sys; sys.exit(0 if open(sys.argv[2],"rb").read() in open(sys.argv[1],"rb").read() else 1)' \
        "${WORK_DIR}/topic.bin" "${WORK_DIR}/expected.bin"; then
    log_pass "T3: topic contains the exact Avro encoding of ${NAME_SINK}"
else
    log_fail "T3: Avro encoding of ${NAME_SINK} not found in ${TOPIC}"
fi
if grep -q "\"name\":\"${NAME_SINK}\"" "${WORK_DIR}/topic.bin"; then
    log_fail "T3: ${NAME_SINK} was published as JSON"
else
    log_pass "T3: ${NAME_SINK} not published as JSON"
fi

log_info "T4: externally produced Avro record is decoded by the source"
NAME_EXT="ext-${RUN_ID}"
avro_encode "${NAME_EXT}" 7.5 > "${WORK_DIR}/external.bin"
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t "${TOPIC}" -p 0 -P "${WORK_DIR}/external.bin" 2>/dev/null \
    || log_fail "T4: kcat could not produce to ${TOPIC}"
if wait_new_log "\[TC58-AVRO\].*${NAME_EXT}, 7\.5" 20; then
    log_pass "T4: ${NAME_EXT} decoded from a hand-encoded Avro record"
else
    log_fail "T4: ${NAME_EXT} not decoded"
fi

log_info "T5: no Avro mapping or class-loading errors"
ERRORS=$(new_log | grep -E 'NoClassDefFoundError|ClassNotFoundException|AvroRuntimeException|Error (when|occurred when) (converting|deserializing)' | head -3 || true)
if [[ -z "${ERRORS}" ]]; then
    log_pass "T5: no Avro or class-loading errors in the log"
else
    log_fail "T5: errors in the log: ${ERRORS}"
fi

print_summary; tc_exit_code
