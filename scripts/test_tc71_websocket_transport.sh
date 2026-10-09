#!/usr/bin/env bash
# TC71: siddhi-io-websocket client and server sinks and sources, over ws:// and wss://
#
# The websocket client (sink and source) connects once, when its app starts, and never reconnects
# (siddhi-io-websocket 3.0.3; SI 4.3.1 behaves the same). The server app is therefore deployed first, and
# T8 reports the reconnect behaviour as a known issue instead of failing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC71"

require_si_running

SERVER_FILE="TC71_WebsocketServer.siddhi"
SERVER_NAME="TC71_WebsocketServer"
CLIENT_FILE="TC71_WebsocketClient.siddhi"
CLIENT_NAME="TC71_WebsocketClient"
CLIENT_URL="http://localhost:${PORT_TC71}/${CLIENT_NAME}/TriggerStream"
PUSH_URL="http://localhost:${PORT_TC71}/${SERVER_NAME}/PushTriggerStream"
RUN_ID="tc71-$(date +%s)"
BURST=20

cleanup() { rm -f "${SI_SIDDHI_DIR}/${CLIENT_FILE}" "${SI_SIDDHI_DIR}/${SERVER_FILE}"; }
trap cleanup EXIT

send() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json; charset=utf-8' \
        -d "{\"event\":{\"id\":\"$2\",\"n\":$3,\"d\":$4}}" "$1" || true
}

# upgrade URL [curl options...] -> the HTTP status of a websocket upgrade request, or 000 when it can't connect
upgrade() {
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' -m 5 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$@" "${url}" || true
}

undeploy_app "${CLIENT_FILE}"
undeploy_app "${SERVER_FILE}"
RUN_MARK=${LOG_MARK}

log_info "T1: server app, then client app, deploy"
deploy_app "${SERVER_FILE}"
assert_app_deployed "T1: ${SERVER_NAME} deployed" "${SERVER_NAME}" 30 || { print_summary; tc_exit_code; exit $?; }
deploy_app "${CLIENT_FILE}"
assert_app_deployed "T1: ${CLIENT_NAME} deployed" "${CLIENT_NAME}" 30 || { print_summary; tc_exit_code; exit $?; }
sleep 2

log_info "T2: websocket sink -> websocket-server source over ws:// keeps every value"
mark_log
STATUS=$(send "${CLIENT_URL}" "${RUN_ID}-naïve-€" 9876543210 2.5)
[[ "${STATUS}" == "200" ]] || log_fail "T2: trigger returned ${STATUS}"
assert_log_contains "T2: ws:// event received with exact values" \
    "\[TC71-WS\].*data=\[${RUN_ID}-naïve-€, 9876543210, 2\.5\]" 15

log_info "T3: the same over wss:// with the pack's default keystore and truststore"
assert_log_contains "T3: wss:// event received with exact values" \
    "\[TC71-WSS\].*data=\[${RUN_ID}-naïve-€, 9876543210, 2\.5\]" 15

log_info "T4: websocket-server sink pushes text-mapped events to the websocket source"
mark_log
send "${PUSH_URL}" "${RUN_ID}-push" -42 -0.125 >/dev/null
assert_log_contains "T4: pushed event received by the client source" \
    "\[TC71-PUSH\].*data=\[${RUN_ID}-push, -42, -0\.125\]" 15

log_info "T5: a burst of ${BURST} events arrives complete over ws:// and wss://"
mark_log
for n in $(seq 1 "${BURST}"); do send "${CLIENT_URL}" "${RUN_ID}-burst" "${n}" 1.0 >/dev/null; done
sleep 4
for tag in WS WSS; do
    got=$(log_since_mark | grep -E "\[TC71-${tag}\]" | grep -oE "data=\[${RUN_ID}-burst, [0-9]+," | sort -u | wc -l | tr -d ' ')
    [[ "${got}" == "${BURST}" ]] && log_pass "T5: ${tag} received all ${BURST} distinct events" \
        || log_fail "T5: ${tag} received ${got} of ${BURST} distinct events"
done

log_info "T6: the wss:// listener speaks TLS and the ws:// listener does not"
STATUS=$(upgrade "https://localhost:${PORT_TC71_WSS}/tc71/wss" -k)
[[ "${STATUS}" == "101" ]] && log_pass "T6: TLS websocket upgrade on ${PORT_TC71_WSS} -> 101" \
    || log_fail "T6: TLS websocket upgrade on ${PORT_TC71_WSS} -> ${STATUS}"
STATUS=$(upgrade "http://localhost:${PORT_TC71_WSS}/tc71/wss")
[[ "${STATUS}" != "101" ]] && log_pass "T6: plain-text upgrade on the TLS port refused (${STATUS})" \
    || log_fail "T6: plain-text upgrade on the TLS port accepted"
STATUS=$(upgrade "http://localhost:${PORT_TC71_WS}/tc71/ws")
[[ "${STATUS}" == "101" ]] && log_pass "T6: plain websocket upgrade on ${PORT_TC71_WS} -> 101" \
    || log_fail "T6: plain websocket upgrade on ${PORT_TC71_WS} -> ${STATUS}"

log_info "T7: no class-loading errors"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T7: no class-loading errors during the run" \
    'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

log_info "T8: client reconnects after the server app is redeployed (known issue)"
undeploy_app "${SERVER_FILE}"
deploy_app "${SERVER_FILE}"
assert_app_deployed "T8: ${SERVER_NAME} redeployed" "${SERVER_NAME}" 30 || { print_summary; tc_exit_code; exit $?; }
mark_log
reconnected=false
for attempt in $(seq 1 10); do
    send "${CLIENT_URL}" "${RUN_ID}-redeploy-${attempt}" 1 1.0 >/dev/null
    sleep 2
    log_since_mark | grep -qE "\[TC71-WS\].*${RUN_ID}-redeploy" && { reconnected=true; break; }
done
if [[ "${reconnected}" == "true" ]]; then
    log_pass "T8: websocket sink delivered to the redeployed server"
else
    stale=$(log_since_mark | grep -c "Siddhi app '${SERVER_NAME}' is not running") || true
    log_warn "T8: websocket sink did not reconnect to the redeployed server within 20s (known, also in 4.3.1);" \
        "${stale} events went to the undeployed app's runtime ('is not running')"
fi

print_summary; tc_exit_code
