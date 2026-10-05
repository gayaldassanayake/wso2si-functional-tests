#!/usr/bin/env bash
# TC67: HTTP sink with OAuth 2.0 — password and client credentials grants, each replacing a rejected token
#
# siddhi-io-http parses every token endpoint response with the platform org.json bundle (HttpsClient), so
# this checks the sink against whichever org.json the pack ships. infra/oauth-mock rejects each sink's
# first access token with 401:
#   - the password-grant sink then uses its refresh token (refresh_token grant) and retries;
#   - the client-credentials sink has no refresh token, so it requests a new token and retries.
# The sink caches tokens per consumer key for the server's lifetime, so on a rerun the password-grant
# sink starts with a refresh_token grant instead of a password grant.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC67"

require_si_running

APP_FILE="TC67_HttpOAuthSink.siddhi"
BASE_URL="http://localhost:${PORT_TC67}/TC67_HttpOAuthSink"
STATE_DIR=$(mktemp -d)
RUN_ID="tc67-$(date +%s)"

if nc -z localhost "${PORT_TC67_MOCK}" 2>/dev/null; then
    log_fail "T0: port ${PORT_TC67_MOCK} is already in use; the OAuth mock can't start"
    print_summary; tc_exit_code
    exit $?
fi
python3 "${SUITE_ROOT}/infra/oauth-mock/server.py" "${PORT_TC67_MOCK}" "${STATE_DIR}" &
MOCK_PID=$!

cleanup() {
    kill "${MOCK_PID}" 2>/dev/null
    rm -f "${SI_SIDDHI_DIR}/${APP_FILE}"
    rm -rf "${STATE_DIR}"
}
trap cleanup EXIT

for _ in $(seq 1 20); do
    curl -sf "http://localhost:${PORT_TC67_MOCK}/health" >/dev/null && break
    sleep 0.5
done
if ! curl -sf "http://localhost:${PORT_TC67_MOCK}/health" >/dev/null; then
    log_fail "T0: OAuth mock did not start on port ${PORT_TC67_MOCK}"
    print_summary; tc_exit_code
    exit $?
fi
log_info "T0: OAuth mock listening on ${PORT_TC67_MOCK}"

# Waits until the API has accepted an event with id $1; prints the Authorization it was accepted with.
wait_received() {
    local id="$1" line=""
    for _ in $(seq 1 30); do
        line=$(grep "${id}" "${STATE_DIR}/received.log" 2>/dev/null | head -1)
        [[ -n "${line}" ]] && break
        sleep 1
    done
    echo "${line%%	*}"
}
grants_for() { grep "^$1 " "${STATE_DIR}/grants.log" 2>/dev/null | cut -d' ' -f2- | tr '\n' ',' ; }

undeploy_app "${APP_FILE}"
deploy_app "${APP_FILE}"

log_info "T1: app deploys"
assert_app_deployed "T1: TC67 deployed" TC67_HttpOAuthSink 30 || { print_summary; exit 1; }

log_info "T2: password grant — the first token is rejected, the sink refreshes it and retries"
post_event "${BASE_URL}/PasswordStream" "{\"id\":\"${RUN_ID}-pw1\",\"symbol\":\"WSO2\",\"price\":55.5}" >/dev/null
auth=$(wait_received "${RUN_ID}-pw1")
grants=$(grants_for tc67-password)
if [[ "${auth}" == "Bearer tok-2" ]]; then
    log_pass "T2: API accepted the event with the refreshed token tok-2"
else
    log_fail "T2: event not accepted with tok-2 (got '${auth}'); grants: ${grants}"
fi
# The sink switches to a refresh_token grant only once it has cached a refresh token parsed from a token
# response. siddhi-io-http sends its configured refresh.token option in that grant, which is empty here.
if [[ "${grants}" == "password -,refresh_token -,"* || "${grants}" == "refresh_token -,"* ]]; then
    log_pass "T2: sink parsed the refresh token and switched to a refresh_token grant (${grants})"
else
    log_fail "T2: unexpected grants for the password sink: ${grants}"
fi

log_info "T3: client credentials grant — the first token is rejected, the sink requests a new one and retries"
post_event "${BASE_URL}/ClientStream" "{\"id\":\"${RUN_ID}-cc1\",\"symbol\":\"IBM\",\"price\":12.25}" >/dev/null
auth=$(wait_received "${RUN_ID}-cc1")
grants=$(grants_for tc67-client)
if [[ "${auth}" =~ ^Bearer\ tok-c[2-9] ]]; then
    log_pass "T3: API accepted the event with a replacement token (${auth#Bearer })"
else
    log_fail "T3: event not accepted with a replacement token (got '${auth}'); grants: ${grants}"
fi
if [[ "${grants}" == "client_credentials -,client_credentials -,"* ]]; then
    log_pass "T3: token endpoint got two client_credentials grants"
else
    log_fail "T3: unexpected client_credentials grants: ${grants}"
fi

log_info "T4: both sinks report the requests as sent"
assert_log_contains "T4: sink reports success" "Request sent successfully to http://localhost:${PORT_TC67_MOCK}/api" 10

log_info "T5: a second event on the password sink reuses tok-2"
before=$(wc -l < "${STATE_DIR}/grants.log" | tr -d ' ')
post_event "${BASE_URL}/PasswordStream" "{\"id\":\"${RUN_ID}-pw2\",\"symbol\":\"WSO2\",\"price\":56.0}" >/dev/null
auth=$(wait_received "${RUN_ID}-pw2")
if [[ "${auth}" == "Bearer tok-2" ]]; then
    log_pass "T5: second event delivered with tok-2"
else
    log_fail "T5: second event not delivered with tok-2 (got '${auth}')"
fi
# The sink requests a token before each request; with a cached refresh token that's a refresh_token grant.
new_grants=$(tail -n +$((before + 1)) "${STATE_DIR}/grants.log" | cut -d' ' -f2 | sort -u | tr '\n' ' ')
if [[ -z "${new_grants// /}" || "${new_grants}" == "refresh_token " ]]; then
    log_pass "T5: no new password grant; the cached refresh token was used (${new_grants:-no grants})"
else
    log_fail "T5: unexpected grants for the second event: ${new_grants}"
fi

log_info "T6: no org.json errors while parsing token responses"
assert_log_not_contains "T6: no JSONException" 'JSONException'

print_summary; tc_exit_code
