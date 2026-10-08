#!/usr/bin/env bash
# TC68: HTTPS, mutual TLS and basic authentication with siddhi-io-http
#
# siddhi-io-http 2.3.8 imports the HTTP transport and Netty from the platform instead of embedding them
# (siddhi-io/siddhi-io-http#227), so TLS here runs on the pack's own transport and Netty bundles.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC68"

require_si_running

APP_FILE="TC68_HttpsAndAuth.siddhi"
APP_NAME="TC68_HttpsAndAuth"
HTTPS_URL="https://localhost:${PORT_TC68}/${APP_NAME}/HttpsInStream"
MTLS_URL="https://localhost:${PORT_TC68_MTLS}/${APP_NAME}/MtlsInStream"
AUTH_URL="http://localhost:${PORT_TC68_AUTH}/${APP_NAME}/AuthInStream"
LOOP_URL="http://localhost:${PORT_TC68_LOOP}/${APP_NAME}/LoopInStream"
KEYSTORE="${SI_HOME}/resources/security/wso2carbon.jks"
RUN_ID="r$(date +%s)"
WORK_DIR=$(mktemp -d)

require_file "${KEYSTORE}"

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# post URL NAME [curl options...] -> HTTP status, or 000 when the connection or handshake fails
post() {
    local url="$1" name="$2"; shift 2
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"event\":{\"name\":\"${name}\",\"amount\":1.5}}" "$@" "${url}" || true
}

# The server trusts client-truststore.jks, which holds the pack's wso2carbon certificate, so that certificate
# doubles as the mutual TLS client certificate. macOS curl (SecureTransport) takes it as PKCS#12.
KEYTOOL="${JAVA_HOME:+${JAVA_HOME}/bin/}keytool"
"${KEYTOOL}" -importkeystore -srckeystore "${KEYSTORE}" -srcstorepass wso2carbon -srcalias wso2carbon \
    -destkeystore "${WORK_DIR}/client.p12" -deststoretype PKCS12 -deststorepass wso2carbon -noprompt &>/dev/null
if [[ ! -s "${WORK_DIR}/client.p12" ]]; then
    log_fail "T0: could not export a client certificate from ${KEYSTORE} with ${KEYTOOL}"
    print_summary; tc_exit_code
    exit $?
fi
CLIENT_CERT=(--cert-type P12 --cert "${WORK_DIR}/client.p12:wso2carbon")

log_info "T1: app with HTTPS, mutual TLS and basic auth sources deploys"
undeploy_app "${APP_FILE}"
RUN_MARK=${LOG_MARK}
deploy_app "${APP_FILE}"
if ! assert_app_deployed "T1: ${APP_NAME} deployed" "${APP_NAME}" 30; then
    print_summary; tc_exit_code
    exit $?
fi

log_info "T2: HTTPS source accepts an event over TLS"
mark_log
STATUS=$(post "${HTTPS_URL}" "https-${RUN_ID}" -k)
[[ "${STATUS}" == "200" ]] && log_pass "T2: HTTPS source returned 200" || log_fail "T2: HTTPS source returned ${STATUS}"
assert_log_contains "T2: https-${RUN_ID} received over HTTPS" "\[TC68-HTTPS\].*https-${RUN_ID}" 15

log_info "T3: mutual TLS source requires a client certificate"
mark_log
STATUS=$(post "${MTLS_URL}" "nocert-${RUN_ID}" -k)
[[ "${STATUS}" == "000" ]] && log_pass "T3: request without a client certificate rejected in the handshake" \
    || log_fail "T3: request without a client certificate returned ${STATUS}"
assert_log_contains "T3: server logged the missing client certificate" 'SSLHandshakeException: \(certificate_required\)' 10
STATUS=$(post "${MTLS_URL}" "mtls-${RUN_ID}" -k "${CLIENT_CERT[@]}")
[[ "${STATUS}" == "200" ]] && log_pass "T3: request with a client certificate returned 200" \
    || log_fail "T3: request with a client certificate returned ${STATUS}"
assert_log_contains "T3: mtls-${RUN_ID} received over mutual TLS" "\[TC68-MTLS\].*mtls-${RUN_ID}" 15
assert_log_not_contains "T3: event without a client certificate not processed" "nocert-${RUN_ID}" 0

log_info "T4: basic auth source rejects missing and wrong credentials"
mark_log
STATUS=$(post "${AUTH_URL}" "anon-${RUN_ID}")
[[ "${STATUS}" == "401" ]] && log_pass "T4: no credentials -> 401" || log_fail "T4: no credentials -> ${STATUS}"
STATUS=$(post "${AUTH_URL}" "wrong-${RUN_ID}" -u "${SI_STORE_API_USER}:wrong")
[[ "${STATUS}" == "401" ]] && log_pass "T4: wrong credentials -> 401" || log_fail "T4: wrong credentials -> ${STATUS}"
STATUS=$(post "${AUTH_URL}" "auth-${RUN_ID}" -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}")
[[ "${STATUS}" == "200" ]] && log_pass "T4: valid credentials -> 200" || log_fail "T4: valid credentials -> ${STATUS}"
assert_log_contains "T4: auth-${RUN_ID} received" "\[TC68-AUTH\].*auth-${RUN_ID}" 15
assert_log_not_contains "T4: unauthenticated events not processed" "\[TC68-AUTH\].*(anon|wrong)-${RUN_ID}" 0

log_info "T5: HTTPS sink with 'Name: value' headers delivers to the HTTPS source"
mark_log
STATUS=$(post "${LOOP_URL}" "loop-${RUN_ID}")
[[ "${STATUS}" == "200" ]] || log_fail "T5: loop input returned ${STATUS}"
assert_log_contains "T5: loop-${RUN_ID} sent by the HTTPS sink and received" "\[TC68-HTTPS\].*loop-${RUN_ID}" 15
assert_log_not_contains "T5: no header validation errors" 'prohibited character|Validation failed for header' 0

log_info "T6: SI REST API still answers on ${SI_REST_API_PORT} alongside the HTTP sources"
STATUS=$(curl -s -k -o "${WORK_DIR}/apps.json" -w '%{http_code}' -m 10 -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" \
    "https://localhost:${SI_REST_API_PORT}/siddhi-apps" || true)
if [[ "${STATUS}" == "200" ]] && grep -q "${APP_NAME}" "${WORK_DIR}/apps.json"; then
    log_pass "T6: /siddhi-apps returned 200 and lists ${APP_NAME}"
else
    log_fail "T6: /siddhi-apps returned ${STATUS}"
fi

log_info "T7: no class-loading errors"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T7: no class-loading errors during the run" \
    'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

print_summary; tc_exit_code
