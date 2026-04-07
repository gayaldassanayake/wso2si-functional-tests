#!/usr/bin/env bash
# common.sh — shared utilities for SI test scripts
# Source this file at the top of each test script:
#   source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load configuration
source "${SUITE_ROOT}/config.env"

# ─── Counters ────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TC="${CURRENT_TC:-TEST}"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Logging helpers ─────────────────────────────────────────────────────────
log_info()  { echo -e "${CYAN}[${CURRENT_TC} INFO]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS_COUNT++)) || true; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; ((FAIL_COUNT++)) || true; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

print_summary() {
    echo ""
    local total=$(( PASS_COUNT + FAIL_COUNT ))
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}=== ${CURRENT_TC}: ${PASS_COUNT}/${total} PASSED ===${NC}"
    else
        echo -e "${RED}=== ${CURRENT_TC}: ${PASS_COUNT} PASSED, ${FAIL_COUNT} FAILED ===${NC}"
    fi
    echo ""
}

# Returns 0 if TC passed overall, 1 if any failures
tc_exit_code() {
    [[ $FAIL_COUNT -eq 0 ]] && return 0 || return 1
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────
require_si_running() {
    if ! nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} SI is not running on port ${SI_HTTP_PORT}."
        echo "  Start it with: \${SI_HOME}/bin/server.sh"
        exit 1
    fi
}

require_docker_container() {
    local container="$1"
    if ! docker inspect "${container}" --format '{{.State.Status}}' 2>/dev/null | grep -q 'running'; then
        echo -e "${RED}[ERROR]${NC} Docker container '${container}' is not running."
        echo "  Run: ./scripts/setup.sh --mysql  (or --kafka, or --all)"
        exit 1
    fi
}

require_mysql_running() {
    require_docker_container "${MYSQL_CONTAINER}"
}

require_kafka_running() {
    require_docker_container "${KAFKA_CONTAINER}"
}

require_file() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        echo -e "${RED}[ERROR]${NC} Required file not found: ${path}"
        exit 1
    fi
}

# ─── Deployment helpers ──────────────────────────────────────────────────────
deploy_app() {
    local app_file="$1"
    local src="${SUITE_ROOT}/siddhi-apps/${app_file}"
    if [[ ! -f "${src}" ]]; then
        echo -e "${RED}[ERROR]${NC} Siddhi app not found: ${src}"
        exit 1
    fi
    cp "${src}" "${SI_SIDDHI_DIR}/"
    log_info "Deployed ${app_file}. Waiting ${DEPLOY_WAIT_SECONDS}s for SI pickup..."
    sleep "${DEPLOY_WAIT_SECONDS}"
}

undeploy_app() {
    local app_file="$1"
    rm -f "${SI_SIDDHI_DIR}/${app_file}"
    log_info "Undeployed ${app_file}"
    sleep 2
}

# ─── Log assertion helpers ───────────────────────────────────────────────────

# Poll the SI log until pattern appears or timeout expires.
# Returns 0 on match, 1 on timeout.
wait_for_log() {
    local pattern="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if tail -n "${LOG_TAIL_LINES}" "${SI_LOG}" 2>/dev/null | grep -qE "${pattern}"; then
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

# Assert that pattern appears in SI log within timeout seconds.
assert_log_contains() {
    local description="$1"
    local pattern="$2"
    local timeout="${3:-30}"
    if wait_for_log "${pattern}" "${timeout}"; then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}: pattern '${pattern}' not found in log within ${timeout}s"
        return 1
    fi
}

# Assert that pattern does NOT appear in the last LOG_TAIL_LINES of the log.
# Used for negative tests (wait a moment first, then check absence).
assert_log_not_contains() {
    local description="$1"
    local pattern="$2"
    local wait_secs="${3:-3}"
    sleep "${wait_secs}"
    if tail -n "${LOG_TAIL_LINES}" "${SI_LOG}" 2>/dev/null | grep -qE "${pattern}"; then
        log_fail "${description}: pattern '${pattern}' was found in log but should NOT be"
        return 1
    else
        log_pass "${description}"
        return 0
    fi
}

# ─── HTTP helpers ────────────────────────────────────────────────────────────

# POST a JSON event to an SI HTTP source.
# The body format follows Siddhi default JSON mapper: {"event": {...}}
post_event() {
    local url="$1"
    local json_payload="$2"   # just the inner object, e.g. '{"symbol":"AAPL","price":150.0}'
    local body="{\"event\":${json_payload}}"
    curl -s -o /dev/null -w "%{http_code}" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "${body}" \
         "${url}"
}

# POST a raw body (non-JSON-wrapped) to an SI HTTP source.
post_raw() {
    local url="$1"
    local content_type="$2"
    local body="$3"
    curl -s -o /dev/null -w "%{http_code}" \
         -X POST \
         -H "Content-Type: ${content_type}" \
         -d "${body}" \
         "${url}"
}

# Assert that an HTTP POST returns the expected status code.
assert_post_status() {
    local description="$1"
    local url="$2"
    local payload="$3"
    local expected_status="$4"
    local actual_status
    actual_status=$(post_event "${url}" "${payload}")
    if [[ "${actual_status}" == "${expected_status}" ]]; then
        log_pass "${description} (HTTP ${actual_status})"
        return 0
    else
        log_fail "${description}: expected HTTP ${expected_status}, got ${actual_status}"
        return 1
    fi
}

# ─── Store API helpers ───────────────────────────────────────────────────────

# Execute a Siddhi Store Query. Returns the raw JSON response body.
store_query() {
    local app_name="$1"
    local query="$2"
    local body="{\"appName\":\"${app_name}\",\"query\":\"${query}\"}"
    curl -s \
         -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "${body}" \
         "http://localhost:${SI_STORE_API_PORT}/stores/query"
}

# Execute a Store Query and return just the HTTP status code.
store_query_status() {
    local app_name="$1"
    local query="$2"
    local body="{\"appName\":\"${app_name}\",\"query\":\"${query}\"}"
    curl -s -o /dev/null -w "%{http_code}" \
         -u "${SI_STORE_API_USER}:${SI_STORE_API_PASS}" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "${body}" \
         "http://localhost:${SI_STORE_API_PORT}/stores/query"
}

# Parse the record count from a Store API JSON response.
# Handles both {"records": [[...], ...]} and {"data": [...]} shapes.
_parse_record_count() {
    local response="$1"
    python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    r = d.get('records', d.get('data', []))
    print(len(r))
except Exception as e:
    print(-1)
" "${response}" 2>/dev/null
}

# Assert that a Store API query returns exactly N records.
assert_store_count() {
    local description="$1"
    local app_name="$2"
    local query="$3"
    local expected="$4"
    local response
    response=$(store_query "${app_name}" "${query}")
    local actual
    actual=$(_parse_record_count "${response}")
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (${actual} records)"
        return 0
    else
        log_fail "${description}: expected ${expected} records, got '${actual}'. Response: ${response}"
        return 1
    fi
}

# Assert that a Store API call returns a specific HTTP status.
assert_store_status() {
    local description="$1"
    local app_name="$2"
    local query="$3"
    local expected_status="$4"
    local actual_status
    actual_status=$(store_query_status "${app_name}" "${query}")
    if [[ "${actual_status}" == "${expected_status}" ]]; then
        log_pass "${description} (HTTP ${actual_status})"
        return 0
    else
        log_fail "${description}: expected HTTP ${expected_status}, got ${actual_status}"
        return 1
    fi
}

# ─── MySQL helper ────────────────────────────────────────────────────────────

# Run a SQL query inside the MySQL Docker container and return the output.
mysql_query() {
    local sql="$1"
    docker exec "${MYSQL_CONTAINER}" \
        mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" \
        --skip-column-names -e "${sql}" 2>/dev/null
}

# Assert MySQL row count for a table.
assert_mysql_count() {
    local description="$1"
    local table="$2"
    local expected="$3"
    local actual
    actual=$(mysql_query "SELECT COUNT(*) FROM ${table};" | tr -d '[:space:]')
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (MySQL ${table} count = ${actual})"
        return 0
    else
        log_fail "${description}: expected ${expected} rows in ${table}, got '${actual}'"
        return 1
    fi
}
