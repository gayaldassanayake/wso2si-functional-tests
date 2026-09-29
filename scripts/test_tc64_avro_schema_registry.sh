#!/usr/bin/env bash
# TC64: Avro sink/source mapping with a Confluent Schema Registry (siddhi-map-avro)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC64"

require_si_running
require_kafka_running
require_schema_registry_running

APP="TC64_AvroSchemaRegistry.siddhi"
APP_MISSING="TC64_AvroSchemaRegistryMissing.siddhi"
URL="http://localhost:${PORT_TC64}/TC64_AvroSchemaRegistry/PaymentInStream"
RUN_ID="r$(date +%s)"
SUBJECT="tc64-${RUN_ID}-value"
TOPIC_IN="tc64-in-${RUN_ID}"
TOPIC_OUT="tc64-out-${RUN_ID}"
MISSING_ID=999999
SCHEMA='{"type":"record","name":"payment","namespace":"tc64","fields":[{"name":"name","type":"string"},{"name":"amount","type":"double"}]}'
KAFKA_OPTS="-X broker.address.family=v4"
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

# Avro binary encoding of the TC64 "payment" record: zigzag-varint string length, UTF-8 bytes, little-endian double.
# With a schema id, prefix the Confluent wire format header: magic byte 0 and the id as a big-endian int.
avro_encode() {
    python3 - "$1" "$2" "${3:-}" <<'EOF'
import struct, sys
name, amount, schema_id = sys.argv[1].encode(), float(sys.argv[2]), sys.argv[3]
n = len(name) << 1
out = bytearray()
while n > 0x7f:
    out.append((n & 0x7f) | 0x80)
    n >>= 7
out.append(n)
body = bytes(out) + name + struct.pack('<d', amount)
header = b'\x00' + struct.pack('>i', int(schema_id)) if schema_id else b''
sys.stdout.buffer.write(header + body)
EOF
}

render_app() {
    sed -e "s/@RUN_ID@/${RUN_ID}/g" -e "s/@SCHEMA_ID@/${SCHEMA_ID}/g" -e "s/@MISSING_ID@/${MISSING_ID}/g" \
        "${SUITE_ROOT}/siddhi-apps/$1" > "${SI_SIDDHI_DIR}/$1"
}

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP}" "${SI_SIDDHI_DIR}/${APP_MISSING}"
    for topic in "${TOPIC_IN}" "${TOPIC_OUT}"; do
        docker exec "${KAFKA_CONTAINER}" kafka-topics --bootstrap-server localhost:9092 \
            --delete --topic "${topic}" &>/dev/null || true
    done
    curl -s -X DELETE "${SCHEMA_REGISTRY_URL}/subjects/${SUBJECT}" &>/dev/null || true
    curl -s -X DELETE "${SCHEMA_REGISTRY_URL}/subjects/${SUBJECT}?permanent=true" &>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log_info "T1: schema registered in the Schema Registry"
python3 -c 'import json, sys; print(json.dumps({"schema": sys.argv[1]}))' "${SCHEMA}" > "${WORK_DIR}/register.json"
SCHEMA_ID=$(curl -s -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    --data @"${WORK_DIR}/register.json" "${SCHEMA_REGISTRY_URL}/subjects/${SUBJECT}/versions" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)
if [[ "${SCHEMA_ID}" =~ ^[0-9]+$ ]]; then
    log_pass "T1: ${SUBJECT} registered with schema id ${SCHEMA_ID}"
else
    log_fail "T1: could not register ${SUBJECT} at ${SCHEMA_REGISTRY_URL}"
    print_summary; tc_exit_code; exit
fi
if [[ "$(curl -s -o /dev/null -w '%{http_code}' "${SCHEMA_REGISTRY_URL}/schemas/ids/${MISSING_ID}")" != "404" ]]; then
    log_fail "T1: schema id ${MISSING_ID} exists in the registry; T5 needs an unused id"
fi

for topic in "${TOPIC_IN}" "${TOPIC_OUT}"; do
    docker exec "${KAFKA_CONTAINER}" kafka-topics --bootstrap-server localhost:9092 \
        --create --topic "${topic}" --partitions 1 --replication-factor 1 --if-not-exists &>/dev/null
done

log_info "T2: app with schema.registry and schema.id deploys (schema fetched from the registry)"
mark_log
RUN_START_OFFSET=${LOG_OFFSET}
render_app "${APP}"
if wait_new_log 'TC64_AvroSchemaRegistry deployed successfully' 30; then
    log_pass "T2: TC64_AvroSchemaRegistry deployed with schema id ${SCHEMA_ID}"
else
    log_fail "T2: TC64_AvroSchemaRegistry did not deploy"
    new_log | grep -E 'ERROR|Exception' | head -5 >&2
    print_summary; tc_exit_code; exit
fi

log_info "T3: registry source decodes a Confluent wire-format record"
NAME_WIRE="wire-${RUN_ID}"
avro_encode "${NAME_WIRE}" 12.5 "${SCHEMA_ID}" > "${WORK_DIR}/wire.bin"
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t "${TOPIC_IN}" -p 0 -P "${WORK_DIR}/wire.bin" 2>/dev/null \
    || log_fail "T3: kcat could not produce to ${TOPIC_IN}"
if wait_new_log "\[TC64-SR-IN\].*${NAME_WIRE}, 12\.5" 20; then
    log_pass "T3: ${NAME_WIRE} decoded through the registry"
else
    log_fail "T3: ${NAME_WIRE} not decoded by the registry source"
fi

log_info "T4: registry sink publishes plain Avro binary"
NAME_SINK="sink-${RUN_ID}"
STATUS=$(post_event "${URL}" "{\"name\":\"${NAME_SINK}\",\"amount\":33.75}")
[[ "${STATUS}" == "200" ]] || log_fail "T4: HTTP source returned ${STATUS}"
if wait_new_log "\[TC64-SR-OUT\].*${NAME_SINK}, 33\.75" 20; then
    log_pass "T4: ${NAME_SINK} published with the registry schema and decoded with schema.def"
else
    log_fail "T4: ${NAME_SINK} not decoded from ${TOPIC_OUT}"
fi
kcat -b "${KAFKA_BOOTSTRAP}" ${KAFKA_OPTS} -t "${TOPIC_OUT}" -C -e -o beginning -f '%s' \
    > "${WORK_DIR}/topic.bin" 2>/dev/null || true
avro_encode "${NAME_SINK}" 33.75 > "${WORK_DIR}/expected.bin"
if cmp -s "${WORK_DIR}/topic.bin" "${WORK_DIR}/expected.bin"; then
    log_pass "T4: ${TOPIC_OUT} holds exactly the Avro encoding of ${NAME_SINK}"
else
    log_fail "T4: ${TOPIC_OUT} does not hold the expected Avro encoding of ${NAME_SINK}"
fi

log_info "T5: unknown schema id fails deployment with the registry's error"
mark_log
render_app "${APP_MISSING}"
if wait_new_log "Schema ${MISSING_ID} not found" 30; then
    log_pass "T5: deployment reports schema ${MISSING_ID} not found"
else
    log_fail "T5: no 'Schema ${MISSING_ID} not found' error for TC64_AvroSchemaRegistryMissing"
fi
if new_log | grep -q 'TC64_AvroSchemaRegistryMissing deployed successfully'; then
    log_fail "T5: TC64_AvroSchemaRegistryMissing deployed with a schema id the registry doesn't have"
else
    log_pass "T5: TC64_AvroSchemaRegistryMissing not deployed"
fi

log_info "T6: no class-loading errors"
LOG_OFFSET=${RUN_START_OFFSET}
ERRORS=$(new_log | grep -E 'NoClassDefFoundError|ClassNotFoundException' | head -3 || true)
if [[ -z "${ERRORS}" ]]; then
    log_pass "T6: no NoClassDefFoundError or ClassNotFoundException during the run"
else
    log_fail "T6: class-loading errors in the log: ${ERRORS}"
fi

print_summary; tc_exit_code
