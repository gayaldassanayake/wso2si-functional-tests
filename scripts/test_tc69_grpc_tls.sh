#!/usr/bin/env bash
# TC69: gRPC source and sink over TLS and mutual TLS
#
# siddhi-io-grpc 1.0.15+ runs on the platform's Netty instead of grpc-netty-shaded (siddhi-io/siddhi-io-grpc#46),
# so the TLS handshake here runs on the pack's Netty bundles and the JDK's TLS provider.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC69"

require_si_running

SERVER_APP="TC69_GrpcTlsServer"
CLIENT_APP="TC69_GrpcTlsClient"
URL="http://localhost:${PORT_TC69}/${CLIENT_APP}/SendStream"
RUN_ID="r$(date +%s)"

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${CLIENT_APP}.siddhi" "${SI_SIDDHI_DIR}/${SERVER_APP}.siddhi"
}
trap cleanup EXIT

# Prints the TLS handshake summary openssl sees for host:port, offering HTTP/2 like a gRPC client.
tls_probe() {
    openssl s_client -connect "$1" -servername localhost -alpn h2 </dev/null 2>&1 || true
}

# Like tls_probe, but sends the HTTP/2 preface without a client certificate and reads the reply. With TLS 1.3 a
# server that requires a certificate sends its refusal only after the handshake, so a bare handshake succeeds.
tls_probe_send() {
    { sleep 1; printf 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'; sleep 2; } \
        | openssl s_client -connect "$1" -servername localhost -alpn h2 2>&1 || true
}

send() { post_event "${URL}" "{\"mode\":\"$1\",\"message\":\"$2\"}"; }

log_info "T1: TLS server and client apps deploy"
undeploy_app "${CLIENT_APP}.siddhi"
undeploy_app "${SERVER_APP}.siddhi"
RUN_MARK=${LOG_MARK}
# The client's sinks connect at deployment and don't reconnect on their own, so the server must be up first.
for app in "${SERVER_APP}" "${CLIENT_APP}"; do
    mark_log
    [[ "${app}" == "${CLIENT_APP}" ]] && CLIENT_MARK=${LOG_MARK}
    deploy_app "${app}.siddhi"
    if ! wait_for_log "Siddhi App ${app} deployed successfully" 60; then
        log_fail "T1: ${app} did not deploy within 60s"
        print_summary; tc_exit_code
        exit $?
    fi
    log_pass "T1: ${app} deployed"
done

log_info "T2: TLS port negotiates TLS with HTTP/2 and presents the pack's certificate"
PROBE=$(tls_probe "localhost:${GRPC_PORT_TC69_TLS}")
if grep -q 'ALPN protocol: h2' <<< "${PROBE}" && grep -q 'CN *= *localhost' <<< "${PROBE}"; then
    log_pass "T2: localhost:${GRPC_PORT_TC69_TLS} speaks TLS, ALPN h2, certificate CN=localhost"
else
    log_fail "T2: no TLS/h2 handshake on localhost:${GRPC_PORT_TC69_TLS}: $(grep -E 'ALPN|subject=|error' <<< "${PROBE}" | head -3 | tr '\n' ' ')"
fi

log_info "T3: event reaches the TLS source through the TLS sink"
mark_log
STATUS=$(send tls "tls-${RUN_ID}")
[[ "${STATUS}" == "200" ]] || log_fail "T3: HTTP source returned ${STATUS}"
assert_log_contains "T3: tls-${RUN_ID} delivered over TLS" "\[TC69-TLS\].*tls-${RUN_ID}" 20

log_info "T4: event reaches the mutual TLS source through the mutual TLS sink"
mark_log
STATUS=$(send mtls "mtls-${RUN_ID}")
[[ "${STATUS}" == "200" ]] || log_fail "T4: HTTP source returned ${STATUS}"
assert_log_contains "T4: mtls-${RUN_ID} delivered over mutual TLS" "\[TC69-MTLS\].*mtls-${RUN_ID}" 20

log_info "T5: only the mutual TLS port asks for a client certificate, and it refuses a client without one"
if grep -q 'No client certificate CA names sent' <<< "$(tls_probe "localhost:${GRPC_PORT_TC69_TLS}")"; then
    log_pass "T5: localhost:${GRPC_PORT_TC69_TLS} does not ask for a client certificate"
else
    log_fail "T5: localhost:${GRPC_PORT_TC69_TLS} asks for a client certificate although mutual TLS is off"
fi
if grep -q 'Acceptable client certificate CA names' <<< "$(tls_probe "localhost:${GRPC_PORT_TC69_MTLS}")"; then
    log_pass "T5: localhost:${GRPC_PORT_TC69_MTLS} asks for a client certificate"
else
    log_fail "T5: localhost:${GRPC_PORT_TC69_MTLS} does not ask for a client certificate"
fi
if grep -qiE 'certificate required|alert (handshake failure|bad certificate)' <<< "$(tls_probe_send "localhost:${GRPC_PORT_TC69_MTLS}")"; then
    log_pass "T5: localhost:${GRPC_PORT_TC69_MTLS} refuses a client without a certificate"
else
    log_fail "T5: localhost:${GRPC_PORT_TC69_MTLS} did not refuse a client without a certificate"
fi

log_info "T6: servers reject a plain-text client and a TLS client without a certificate"
# The sinks connect when the client app deploys, and that is when the servers refuse them; events sent to a
# refused sink are then dropped. The refusals show the absence checks below can't pass vacuously.
mark_log
T6_MARK=${LOG_MARK}
LOG_MARK=${CLIENT_MARK}
assert_log_contains "T6: TLS server refused the plain-text client" 'PlainToTlsSendStream: UNAVAILABLE' 15
assert_log_contains "T6: mutual TLS server refused the TLS client without a certificate" \
    'NoCertToMtlsSendStream: UNAVAILABLE' 15
LOG_MARK=${T6_MARK}
send plain-to-tls "plain-${RUN_ID}" >/dev/null
send nocert-to-mtls "nocert-${RUN_ID}" >/dev/null
assert_log_not_contains "T6: plain-text event did not reach the TLS source" "\[TC69-TLS\].*plain-${RUN_ID}" 10
assert_log_not_contains "T6: event without a client certificate did not reach the mutual TLS source" \
    "\[TC69-MTLS\].*nocert-${RUN_ID}" 0

log_info "T7: no class-loading or native TLS errors"
LOG_MARK=${RUN_MARK}
# Only WARN and ERROR entries count: Netty logs its failed native tcnative probe with a stack trace at DEBUG.
ERRORS=$(log_since_mark | awk '/^\[/{lvl=$3} lvl=="WARN" || lvl=="ERROR"' \
    | grep -E 'NoClassDefFoundError|ClassNotFoundException|UnsatisfiedLinkError|NoSuchMethodError' | head -3 || true)
if [[ -z "${ERRORS}" ]]; then
    log_pass "T7: no NoClassDefFoundError, ClassNotFoundException, UnsatisfiedLinkError or NoSuchMethodError"
else
    log_fail "T7: errors in the log: ${ERRORS}"
fi

print_summary; tc_exit_code
