#!/usr/bin/env bash
# TC70: siddhi-io-tcp sinks and sources with the binary, text and JSON mappers
#
# Every tcp source shares the pack's TCP server on TCP_PORT (9892) and is addressed by its context.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC70"

require_si_running

APP_FILE="TC70_TcpTransport.siddhi"
APP_NAME="TC70_TcpTransport"
TRIGGER_URL="http://localhost:${PORT_TC70}/${APP_NAME}/TriggerStream"
RUN_ID="tc70-$(date +%s)"
BURST=50

cleanup() { rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"; }
trap cleanup EXIT

trigger() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json; charset=utf-8' \
        -d "{\"event\":$1}" "${TRIGGER_URL}" || true
}

undeploy_app "${APP_FILE}"
RUN_MARK=${LOG_MARK}
deploy_app "${APP_FILE}"

log_info "T1: app deploys and its sinks reach the TCP server"
# assert_app_deployed treats the sinks' expected "will retry" connection errors as a failed start.
if wait_for_log "Siddhi App ${APP_NAME} deployed successfully" 30; then
    log_pass "T1: ${APP_NAME} deployed"
else
    log_fail "T1: ${APP_NAME} not deployed within 30s"
    print_summary; tc_exit_code; exit $?
fi
# The sinks connect before the app's tcp sources open their contexts, so they retry every 5s and drop events
# until they reconnect. Send warm-up events until one arrives on every context.
ready=false
for attempt in $(seq 1 15); do
    trigger "{\"id\":\"${RUN_ID}-warmup-${attempt}\",\"i\":0,\"l\":0,\"d\":0.0,\"f\":0.0,\"b\":false}" >/dev/null
    sleep 2
    if log_since_mark | grep -qE "\[TC70-BINARY\].*${RUN_ID}-warmup" &&
       log_since_mark | grep -qE "\[TC70-TEXT\].*${RUN_ID}-warmup" &&
       log_since_mark | grep -qE "\[TC70-JSON\].*${RUN_ID}-warmup" &&
       log_since_mark | grep -qE "\[TC70-SYNC\].*${RUN_ID}-warmup"; then
        ready=true; break
    fi
done
if [[ "${ready}" == "true" ]]; then
    log_pass "T1: all four tcp sinks delivered a warm-up event"
else
    log_fail "T1: tcp sinks did not deliver within 30s"
    print_summary; tc_exit_code; exit $?
fi

log_info "T2: every attribute type survives each mapper, including non-ASCII text"
mark_log
STATUS=$(trigger "{\"id\":\"${RUN_ID}-naïve-€\",\"i\":42,\"l\":9876543210,\"d\":3.25,\"f\":1.5,\"b\":true}")
[[ "${STATUS}" == "200" ]] || log_fail "T2: trigger returned ${STATUS}"
for mapper in BINARY TEXT JSON SYNC; do
    assert_log_contains "T2: ${mapper} carries string, int, long, double, float and bool" \
        "\[TC70-${mapper}\].*data=\[${RUN_ID}-naïve-€, 42, 9876543210, 3\.25, 1\.5, true\]" 15
done

log_info "T3: negative numbers, false and spaces"
mark_log
trigger "{\"id\":\"${RUN_ID} spaced\",\"i\":-7,\"l\":-1,\"d\":-0.5,\"f\":-2.25,\"b\":false}" >/dev/null
for mapper in BINARY TEXT JSON SYNC; do
    assert_log_contains "T3: ${mapper} keeps negative values, false and spaces" \
        "\[TC70-${mapper}\].*data=\[${RUN_ID} spaced, -7, -1, -0\.5, -2\.25, false\]" 15
done

log_info "T4: a burst of ${BURST} events arrives complete on the binary and sync contexts"
mark_log
for n in $(seq 1 "${BURST}"); do
    trigger "{\"id\":\"${RUN_ID}-burst\",\"i\":${n},\"l\":${n},\"d\":1.0,\"f\":1.0,\"b\":true}" >/dev/null
done
sleep 5
for mapper in BINARY SYNC; do
    got=$(log_since_mark | grep -E "\[TC70-${mapper}\]" | grep -oE "data=\[${RUN_ID}-burst, [0-9]+," | sort -u | wc -l | tr -d ' ')
    [[ "${got}" == "${BURST}" ]] && log_pass "T4: ${mapper} received all ${BURST} distinct events" \
        || log_fail "T4: ${mapper} received ${got} of ${BURST} distinct events"
done

log_info "T5: the TCP server survives a client that sends bytes that are not a frame"
mark_log
if command -v nc >/dev/null; then
    printf 'this is not a siddhi tcp frame\r\n\0\0\0\0garbage' | nc -w 2 localhost "${TCP_PORT}" >/dev/null 2>&1 || true
    sleep 2
    trigger "{\"id\":\"${RUN_ID}-after-garbage\",\"i\":1,\"l\":2,\"d\":3.0,\"f\":4.0,\"b\":true}" >/dev/null
    assert_log_contains "T5: binary context still delivers after the bad client" \
        "\[TC70-BINARY\].*data=\[${RUN_ID}-after-garbage, 1, 2, 3\.0, 4\.0, true\]" 20
    assert_log_contains "T5: sync context still delivers after the bad client" \
        "\[TC70-SYNC\].*data=\[${RUN_ID}-after-garbage, 1, 2, 3\.0, 4\.0, true\]" 10
else
    log_skip "T5: nc not found"
fi

log_info "T6: no class-loading errors"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T6: no class-loading errors during the run" \
    'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

print_summary; tc_exit_code
