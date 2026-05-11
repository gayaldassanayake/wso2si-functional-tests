#!/usr/bin/env bash
# TC35: server.sh start/stop lifecycle
#
# STANDALONE — do NOT run while SI is already running on port SI_HTTP_PORT.
# Run this before starting the main SI instance, or after stopping it.
#
# Usage:
#   TOOLS_PACK_HOME=/path/to/wso2si-4.4.0-SNAPSHOT bash scripts/test_tc35_server_lifecycle.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC35"

require_file "${TOOLS_PACK_HOME}/bin/server.sh"

TOOLS_LOG="${TOOLS_PACK_HOME}/wso2/server/logs/carbon.log"

if nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo "[ERROR] A server is already running on port ${SI_HTTP_PORT}. Stop it before running TC35."
    exit 1
fi

cleanup() {
    sh "${TOOLS_PACK_HOME}/bin/server.sh" stop 2>/dev/null || true
}
trap cleanup EXIT

log_info "T1: server.sh start — server must start cleanly on the current JDK"
sh "${TOOLS_PACK_HOME}/bin/server.sh" start 2>&1

ELAPSED=0
STARTED=false
while (( ELAPSED < 30 )); do
    if grep -q "WSO2 Streaming Integrator started" "${TOOLS_LOG}" 2>/dev/null; then
        STARTED=true
        break
    fi
    sleep 2
    (( ELAPSED += 2 )) || true
done

if $STARTED; then
    log_pass "T1: server started successfully"
else
    log_fail "T1: server did not start within 30s"
fi

log_info "T2: no Java version restriction message in log"
if grep -qE "unsupported JDK|CARBON is supported only" "${TOOLS_LOG}" 2>/dev/null; then
    log_fail "T2: version restriction message found in carbon.log"
else
    log_pass "T2: no version restriction message in carbon.log"
fi

log_info "T3: server.sh stop — port must close within 10s"
sh "${TOOLS_PACK_HOME}/bin/server.sh" stop 2>&1

ELAPSED=0
STOPPED=false
while (( ELAPSED < 10 )); do
    if ! nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
        STOPPED=true
        break
    fi
    sleep 1
    (( ELAPSED++ )) || true
done

if $STOPPED; then
    log_pass "T3: server stopped cleanly (port ${SI_HTTP_PORT} closed)"
else
    log_fail "T3: server still listening on port ${SI_HTTP_PORT} after stop"
fi

print_summary; tc_exit_code
