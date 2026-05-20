#!/usr/bin/env bash
# TC43: Thrift DataBridge — verify libthrift 0.23.0 wire protocol end-to-end
#
# Architecture note: DataBridge Thrift uses TCP (7611) for data and SSL (7711)
# for auth only. The TCP sender exercises ALL four libthrift-upgrade code paths:
#   1. TServerSocket(TConfiguration, addr)         — TCP data server  (7611)
#   2. TSocket(TConfiguration, host, port, timeout) — TCP data client  (7611)
#   3. TSSLTransportFactory.getServerSocket(...)    — SSL auth server  (7711)
#   4. TSSLTransportFactory.getClientSocket(...)    — SSL auth client  (7711)
#
# Prerequisite: install siddhi-io-wso2event-5.0.2.jar + siddhi-map-wso2event-5.0.3.jar
# in ${SI_HOME}/wso2/lib/plugins/ and restart SI.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC43"

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

if ! find "${SI_HOME}" -maxdepth 6 \( -name 'wso2event*.jar' -o -name 'siddhi-io-wso2event*.jar' \) \
        2>/dev/null | grep -q .; then
    log_skip "siddhi-io-wso2event extension not found under ${SI_HOME} — skipping TC43"
    log_skip "  Install: jartobundle siddhi-io-wso2event-5.0.2.jar \${SI_HOME}/wso2/lib/plugins/"
    log_skip "           jartobundle siddhi-map-wso2event-5.0.3.jar \${SI_HOME}/wso2/lib/plugins/"
    log_skip "  Then restart SI."
    exit 0
fi
log_info "T0: wso2event extension present"

# ─── T1: verify receiver startup log lines ────────────────────────────────────
log_info "T1: checking Thrift receiver startup messages in carbon.log"
assert_log_contains "T1: Thrift TCP receiver bound"  'Thrift port : 7611'       5
assert_log_contains "T1: Thrift SSL receiver bound"  'Thrift SSL port : 7711'   5
assert_log_contains "T1: Thrift server started"      'Thrift Server started at' 5

# ─── T2: deploy Siddhi apps ───────────────────────────────────────────────────
log_info "T2: deploying TC43 Siddhi apps"
undeploy_app "TC43_ThriftSenderTCP.siddhi"
undeploy_app "TC43_ThriftSenderSSL.siddhi"    # clean up any leftover SSL sender from previous runs
undeploy_app "TC43_ThriftReceiver.siddhi"

deploy_app "TC43_ThriftReceiver.siddhi"   # subscribe first — avoids missing events
deploy_app "TC43_ThriftSenderTCP.siddhi"

assert_log_contains "T2: receiver app deployed"   'TC43_ThriftReceiver.*deployed successfully'  30
assert_log_contains "T2: TCP sender app deployed" 'TC43_ThriftSenderTCP.*deployed successfully' 30

# ─── T3: single event — TCP data + SSL auth ───────────────────────────────────
# Data flows via ThriftClientPoolFactory → TSocket(TConfiguration, host, port, timeout) → TCP 7611
# Auth flows via ThriftSecureClientPoolFactory → TSSLTransportFactory.getClientSocket() → SSL 7711
# Both code paths from the libthrift 0.23.0 upgrade are exercised here.
log_info "T3: publishing one event via TCP (auth via SSL)"
post_event "http://localhost:${PORT_TC43_TCP}/TC43_ThriftSenderTCP/InStream" \
    '{"transport":"TCP","symbol":"WSO2","price":42.5,"qty":1}' >/dev/null
assert_log_contains "T3: event received by DataBridge receiver" '\[TC43-RECV\].*TCP.*WSO2' 20

# ─── T4: burst of 10 events — validate sustained throughput ──────────────────
log_info "T4: publishing burst of 10 events"
for i in $(seq 1 10); do
    post_event "http://localhost:${PORT_TC43_TCP}/TC43_ThriftSenderTCP/InStream" \
        "{\"transport\":\"TCP\",\"symbol\":\"BURST\",\"price\":1.0,\"qty\":${i}}" >/dev/null
done
assert_log_contains "T4: burst events received" '\[TC43-RECV\].*TCP.*BURST' 20

# ─── T5: no transport / auth errors ──────────────────────────────────────────
assert_log_not_contains "T5: no Thrift transport errors" \
    'Cannot start Thrift server|Can not create and start Agent Server|Authentication failed for user admin' 3

print_summary; tc_exit_code
