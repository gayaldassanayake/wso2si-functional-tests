#!/usr/bin/env bash
# TC43: Thrift DataBridge — verify the libthrift wire protocol end-to-end
#
# SI's wso2event sink publishes to its own DataBridge receiver: data over TCP 7611, login over
# SSL 7711. The Thrift agent supports only tcp:// data URLs; 7711 carries the login.
# An external publisher (infra/thrift-publisher) then publishes from a separate JVM, first with
# this pack's databridge agent and libthrift, then with an older pack's (THRIFT_LEGACY_CLIENT_HOME,
# e.g. SI 1.1.0 with libthrift 0.9.2), to check that older clients still interoperate.
#
# Needs siddhi-io-wso2event and siddhi-map-wso2event in ${SI_HOME}/lib. When they are missing, the
# test installs them from infra/wso2event and fails until SI is restarted, so TC43 never skips.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC43"
PUBLISHER="${SUITE_ROOT}/infra/thrift-publisher/publish.sh"

# Waits until the receiver has logged $2 events for transport $1 since the last mark.
assert_received_count() {
    local description="$1" transport="$2" expected="$3" timeout="${4:-30}" elapsed=0 got=0
    while (( elapsed < timeout )); do
        got=$(log_since_mark | grep -cE "\[TC43-RECV\].*${transport}" || true)
        (( got >= expected )) && break
        sleep 1
        (( elapsed++ )) || true
    done
    if (( got == expected )); then
        log_pass "${description}: ${got}/${expected} events received"
    else
        log_fail "${description}: ${got}/${expected} events received within ${timeout}s"
    fi
}

# ─── T0: preflight ────────────────────────────────────────────────────────────
require_si_running

if ! nc -z localhost 7611 2>/dev/null; then
    log_fail "T0: Thrift TCP port 7611 not bound — DataBridge receiver not started"
    print_summary; tc_exit_code
    exit $?
fi
if ! nc -z localhost 7711 2>/dev/null; then
    log_fail "T0: Thrift SSL port 7711 not bound — DataBridge receiver not started"
    print_summary; tc_exit_code
    exit $?
fi
log_info "T0: Thrift ports 7611/7711 open"

BUNDLES_INFO="${SI_HOME}/wso2/server/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
if ! ls "${SI_HOME}"/lib/siddhi-io-wso2event-*.jar "${SI_HOME}"/lib/siddhi-map-wso2event-*.jar >/dev/null 2>&1; then
    SI_HOME="${SI_HOME}" bash "${SUITE_ROOT}/infra/wso2event/install.sh" >/dev/null
    log_fail "T0: wso2event extensions were missing; now installed in \${SI_HOME}/lib. Restart SI and rerun TC43."
    print_summary; tc_exit_code
    exit $?
fi
if ! grep -qE '^siddhi-io-wso2event,' "${BUNDLES_INFO}" || ! grep -qE '^siddhi-map-wso2event,' "${BUNDLES_INFO}"; then
    log_fail "T0: wso2event extensions are in \${SI_HOME}/lib but not loaded. Restart SI and rerun TC43."
    print_summary; tc_exit_code
    exit $?
fi
log_info "T0: wso2event extension present"
log_info "T0: server libthrift: $(ls "${SI_HOME}"/wso2/lib/plugins/libthrift_*.jar 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"

# ─── T1: verify receiver startup log lines ────────────────────────────────────
log_info "T1: checking Thrift receiver startup messages in carbon.log"
assert_boot_log_contains "T1: Thrift TCP receiver bound" 'Thrift port : 7611'
assert_boot_log_contains "T1: Thrift SSL receiver bound" 'Thrift SSL port : 7711'
assert_boot_log_contains "T1: Thrift server started" 'Thrift Server started at'

# ─── T2: deploy Siddhi apps ───────────────────────────────────────────────────
log_info "T2: deploying TC43 Siddhi apps"
undeploy_app "TC43_ThriftSenderTCP.siddhi"
undeploy_app "TC43_ThriftSenderSSL.siddhi"    # clean up the SSL sender earlier versions deployed
undeploy_app "TC43_ThriftReceiver.siddhi"

deploy_app "TC43_ThriftReceiver.siddhi"   # subscribe first — avoids missing events
deploy_app "TC43_ThriftSenderTCP.siddhi"

assert_app_deployed "T2: receiver app deployed" TC43_ThriftReceiver 30
assert_app_deployed "T2: TCP sender app deployed" TC43_ThriftSenderTCP 30

# ─── T3: single event — TCP data + SSL auth ───────────────────────────────────
# Data: ThriftClientPoolFactory → TSocket → TServerSocket on 7611
# Login: ThriftSecureClientPoolFactory → TSSLTransportFactory.getClientSocket() → getServerSocket() on 7711
log_info "T3: publishing one event via TCP (auth via SSL)"
mark_log
post_event "http://localhost:${PORT_TC43_TCP}/TC43_ThriftSenderTCP/InStream" \
    '{"transport":"TCP","symbol":"WSO2","price":42.5,"qty":1}' >/dev/null
assert_log_contains "T3: event received by DataBridge receiver" '\[TC43-RECV\].*TCP.*WSO2' 20

# ─── T4: burst of 10 events — validate sustained throughput ──────────────────
log_info "T4: publishing burst of 10 events via TCP"
mark_log
for i in $(seq 1 10); do
    post_event "http://localhost:${PORT_TC43_TCP}/TC43_ThriftSenderTCP/InStream" \
        "{\"transport\":\"TCP\",\"symbol\":\"BURST\",\"price\":1.0,\"qty\":${i}}" >/dev/null
done
assert_received_count "T4: TCP burst" 'TCP.*BURST' 10 20

# ─── T5: external publisher, this pack's client ──────────────────────────────
if ! command -v javac >/dev/null 2>&1; then
    log_skip "T5/T6: javac not on PATH; external publisher checks skipped"
else
    log_info "T5: external JVM publishing 20 events with this pack's client"
    mark_log
    if out=$(SI_HOME="${SI_HOME}" CLIENT_HOME="${SI_HOME}" "${PUBLISHER}" tcp://localhost:7611 \
            ssl://localhost:7711 TC43Stream:1.0.0 EXT-CUR 20 2>&1); then
        log_info "T5: $(echo "${out}" | grep -E '^Client:')"
        assert_received_count "T5: external client" 'EXT-CUR' 20 30
    else
        log_fail "T5: external publisher failed: $(echo "${out}" | grep -E 'ERROR|Exception' | head -3)"
    fi

    # ─── T6: external publisher, an older pack's client ──────────────────────────
    if [[ -z "${THRIFT_LEGACY_CLIENT_HOME:-}" || ! -d "${THRIFT_LEGACY_CLIENT_HOME}/wso2/lib/plugins" ]]; then
        log_skip "T6: THRIFT_LEGACY_CLIENT_HOME not set to an SI pack; legacy client check skipped"
    else
        log_info "T6: external JVM publishing 20 events with the client from ${THRIFT_LEGACY_CLIENT_HOME}"
        mark_log
        if out=$(SI_HOME="${SI_HOME}" CLIENT_HOME="${THRIFT_LEGACY_CLIENT_HOME}" "${PUBLISHER}" \
                tcp://localhost:7611 ssl://localhost:7711 TC43Stream:1.0.0 EXT-OLD 20 2>&1); then
            log_info "T6: $(echo "${out}" | grep -E '^Client:')"
            assert_received_count "T6: legacy client" 'EXT-OLD' 20 30
        else
            log_fail "T6: legacy publisher failed: $(echo "${out}" | grep -E 'ERROR|Exception' | head -3)"
        fi
    fi
fi

# ─── T7: no transport / auth errors ──────────────────────────────────────────
sleep 3
assert_boot_log_not_contains "T7: no Thrift transport errors" \
    'Cannot start Thrift server|Can not create and start Agent Server|Authentication failed for user admin|TProtocolException'

print_summary; tc_exit_code
