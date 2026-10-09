#!/usr/bin/env bash
# common.sh — shared utilities for SI test scripts
# Source this file at the top of each test script:
#   source "$(dirname "$0")/lib/common.sh"

# No errexit: a failed assertion returns 1, and the test must keep going so the
# remaining checks run and print_summary reports every failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load configuration
source "${SUITE_ROOT}/config.env"
source "${SCRIPT_DIR}/pack.sh"

# ─── Counters ────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
# A test that cannot run (missing driver, extension, tool) exits with this code
# so run_all_tests.sh reports it as skipped instead of passed.
SKIP_EXIT_CODE=77
# A test that ran but skipped some of its checks (log_skip) exits with this code.
PARTIAL_SKIP_EXIT_CODE=78
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
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; ((SKIP_COUNT++)) || true; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

print_summary() {
    echo ""
    local total=$(( PASS_COUNT + FAIL_COUNT ))
    local skipped=""
    (( SKIP_COUNT > 0 )) && skipped=", ${SKIP_COUNT} SKIPPED"
    if [[ $FAIL_COUNT -eq 0 && $SKIP_COUNT -eq 0 ]]; then
        echo -e "${GREEN}=== ${CURRENT_TC}: ${PASS_COUNT}/${total} PASSED ===${NC}"
    elif [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${YELLOW}=== ${CURRENT_TC}: ${PASS_COUNT}/${total} PASSED${skipped} ===${NC}"
    else
        echo -e "${RED}=== ${CURRENT_TC}: ${PASS_COUNT} PASSED, ${FAIL_COUNT} FAILED${skipped} ===${NC}"
    fi
    echo ""
}

# Returns 1 if any check failed, SKIP_EXIT_CODE if every check was skipped,
# PARTIAL_SKIP_EXIT_CODE if some were skipped, 0 otherwise.
tc_exit_code() {
    (( FAIL_COUNT > 0 )) && return 1
    (( SKIP_COUNT > 0 && PASS_COUNT == 0 )) && return "${SKIP_EXIT_CODE}"
    (( SKIP_COUNT > 0 )) && return "${PARTIAL_SKIP_EXIT_CODE}"
    return 0
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────
require_si_running() {
    local problem
    problem=$(pack_problem "${SI_HOME}")
    if [[ -n "${problem}" ]]; then
        echo -e "${RED}[ERROR]${NC} ${problem}"
        exit 1
    fi
    if ! nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} SI is not running on port ${SI_HTTP_PORT}."
        echo "  Start it with: \${SI_HOME}/bin/server.sh"
        exit 1
    fi
    problem=$(si_server_mismatch)
    if [[ -n "${problem}" ]]; then
        echo -e "${RED}[ERROR]${NC} The SI on port ${SI_HTTP_PORT} is not the pack under test: ${problem}"
        echo "  SI_HOME: ${SI_HOME}"
        exit 1
    fi
}

# For tests that inspect TOOLS_PACK_HOME without a running server (TC36–TC38, TC53).
require_tools_pack() {
    local problem
    problem=$(pack_problem "${TOOLS_PACK_HOME}")
    if [[ -n "${problem}" ]]; then
        echo -e "${RED}[ERROR]${NC} TOOLS_PACK_HOME: ${problem}"
        exit 1
    fi
    log_info "Inspecting $(pack_version "${TOOLS_PACK_HOME}") at ${TOOLS_PACK_HOME}"
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

require_schema_registry_running() {
    require_docker_container "${SCHEMA_REGISTRY_CONTAINER}"
    if ! curl -sf -m 5 "${SCHEMA_REGISTRY_URL}/subjects" >/dev/null; then
        echo -e "${RED}[ERROR]${NC} Schema Registry is not reachable at ${SCHEMA_REGISTRY_URL}. Run: ./scripts/setup.sh --kafka"
        exit 1
    fi
}

require_rabbitmq_running() {
    require_docker_container "${RABBITMQ_CONTAINER}"
}

require_redis_running() {
    require_docker_container "${REDIS_CONTAINER}"
}

require_samba_running() {
    require_docker_container "${SAMBA_CONTAINER}"
}

require_ftp_running() {
    require_docker_container "${FTP_CONTAINER}"
    require_docker_container "${SFTP_CONTAINER}"
}

require_mongodb_running() {
    require_docker_container "${MONGODB_CONTAINER}"
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
    if ! cp "${src}" "${SI_SIDDHI_DIR}/"; then
        echo -e "${RED}[ERROR]${NC} Could not copy ${src} to ${SI_SIDDHI_DIR}"
        exit 1
    fi
    log_info "Deployed ${app_file}. Waiting ${DEPLOY_WAIT_SECONDS}s for SI pickup..."
    sleep "${DEPLOY_WAIT_SECONDS}"
}

# Waits for SI to finish undeploying, then moves the log mark past it, so the
# old app's shutdown errors can't fail a later assertion.
undeploy_app() {
    local app_file="$1"
    local was_deployed=false
    [[ -f "${SI_SIDDHI_DIR}/${app_file}" ]] && was_deployed=true
    rm -f "${SI_SIDDHI_DIR}/${app_file}"
    if [[ "${was_deployed}" == "true" ]] &&
       ! wait_for_log "Siddhi App File ${app_file%.siddhi} undeployed successfully" 30; then
        log_warn "SI did not confirm undeploying ${app_file} within 30s"
    fi
    sleep 1
    _set_log_mark
    log_info "Undeployed ${app_file}"
}

# ─── Log assertion helpers ───────────────────────────────────────────────────
# Log assertions only see what SI logged after LOG_MARK, so lines left by
# earlier runs or earlier tests can't satisfy them. Each test script sources
# this file in a fresh process, which marks the log at test start.

LOG_MARK=0

# Some tests define their own mark_log; the helpers here use _set_log_mark so
# they never move a test's private offset.
_set_log_mark() {
    LOG_MARK=0
    [[ -f "${SI_LOG}" ]] || return 0
    LOG_MARK=$(wc -c < "${SI_LOG}" | tr -d ' ') || LOG_MARK=0
    [[ -n "${LOG_MARK}" ]] || LOG_MARK=0
}

mark_log() { _set_log_mark; }

# Prints the SI log from LOG_MARK onward. A log shorter than the mark has
# rotated, so it is read from the start.
log_since_mark() {
    [[ -f "${SI_LOG}" ]] || return 0
    local size
    size=$(wc -c < "${SI_LOG}" | tr -d ' ') || return 0
    if (( ${size:-0} < LOG_MARK )); then
        cat "${SI_LOG}" 2>/dev/null
    else
        tail -c +"$(( LOG_MARK + 1 ))" "${SI_LOG}" 2>/dev/null
    fi
    return 0
}

_set_log_mark

# Prints the SI log from the start of the current server boot, for lines SI
# writes only at startup. The WebSocket line is the earliest one SI logs on every
# start; the launcher's updateOSGiLib line only appears when lib/ changed.
log_since_boot() {
    [[ -f "${SI_LOG}" ]] || return 0
    awk '/WebSocketServerSC.*All required capabilities/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "${SI_LOG}"
}

# Poll the SI log until pattern appears or timeout expires.
# Returns 0 on match, 1 on timeout.
wait_for_log() {
    local pattern="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if log_since_mark | grep -E "${pattern}" > /dev/null; then
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

# Assert that the app logged "deployed successfully" since the mark and that
# none of its sources or sinks failed to start (SI logs both lines then).
assert_app_deployed() {
    local description="$1"
    local app_name="$2"
    local timeout="${3:-30}"
    if ! wait_for_log "Siddhi App ${app_name} deployed successfully" "${timeout}"; then
        log_fail "${description}: '${app_name} deployed successfully' not logged within ${timeout}s"
        return 1
    fi
    local err
    err=$(log_since_mark | grep -E "Error (starting Siddhi App|on) '${app_name}'" | head -1) || true
    if [[ -n "${err}" ]]; then
        log_fail "${description}: ${app_name} deployed but failed to start: ${err#*\} - }"
        return 1
    fi
    log_pass "${description}"
}

# Undeploy and deploy an app so the test starts with fresh state and its own
# deployment line, then assert it started.
redeploy_app() {
    local app_file="$1"
    local app_name="$2"
    undeploy_app "${app_file}"
    deploy_app "${app_file}"
    assert_app_deployed "${app_name} deployed" "${app_name}" 30
}

# Assert that a line SI writes at startup is present in the current boot.
assert_boot_log_contains() {
    local description="$1"
    local pattern="$2"
    if log_since_boot | grep -E "${pattern}" > /dev/null; then
        log_pass "${description}"
        return 0
    fi
    log_fail "${description}: pattern '${pattern}' not found since the server started"
    return 1
}

assert_boot_log_not_contains() {
    local description="$1"
    local pattern="$2"
    if log_since_boot | grep -E "${pattern}" > /dev/null; then
        log_fail "${description}: pattern '${pattern}' was found since the server started but should NOT be"
        return 1
    fi
    log_pass "${description}"
}

# Assert that pattern does NOT appear in the log since the mark.
# Used for negative tests (wait a moment first, then check absence).
assert_log_not_contains() {
    local description="$1"
    local pattern="$2"
    local wait_secs="${3:-3}"
    sleep "${wait_secs}"
    if log_since_mark | grep -E "${pattern}" > /dev/null; then
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

# ─── Helm chart assertion helpers ────────────────────────────────────────────

# Render helm templates and return the YAML output (stdout).
# Usage: helm_template [--set key=val ...] [--values file.yaml]
helm_template() {
    helm template si-test "${HELM_SI_CHART}" "$@" 2>&1
}

# Assert helm lint passes for the chart (with optional --set overrides).
assert_helm_lint() {
    local description="$1"; shift
    local output
    if output=$(helm lint "${HELM_SI_CHART}" "$@" 2>&1); then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}"
        echo "${output}" >&2
        return 1
    fi
}

# Assert that a rendered string of YAML contains a grep-compatible pattern.
assert_yaml_contains() {
    local description="$1"
    local yaml="$2"
    local pattern="$3"
    if echo "${yaml}" | grep -qE "${pattern}"; then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}: pattern '${pattern}' not found in rendered YAML"
        return 1
    fi
}

# Assert that a rendered string of YAML does NOT contain a grep-compatible pattern.
assert_yaml_not_contains() {
    local description="$1"
    local yaml="$2"
    local pattern="$3"
    if echo "${yaml}" | grep -qE "${pattern}"; then
        log_fail "${description}: pattern '${pattern}' was found in rendered YAML but should not be"
        return 1
    else
        log_pass "${description}"
        return 0
    fi
}

# Assert that helm template fails and the error output matches a pattern.
assert_helm_template_fails() {
    local description="$1"
    local expected_pattern="$2"; shift 2
    local output
    if output=$(helm template si-test "${HELM_SI_CHART}" "$@" 2>&1); then
        log_fail "${description}: expected helm template to fail but it succeeded"
        return 1
    else
        if echo "${output}" | grep -qE "${expected_pattern}"; then
            log_pass "${description}"
            return 0
        else
            log_fail "${description}: helm template failed but with unexpected error"
            echo "  Expected pattern : ${expected_pattern}" >&2
            echo "  Actual output    : ${output}" >&2
            return 1
        fi
    fi
}

# ─── Kubernetes live-cluster helpers ─────────────────────────────────────────

# Assert a kubectl-gettable resource exists in the test namespace.
assert_k8s_resource_exists() {
    local description="$1"
    local resource="$2"           # e.g. "gateway/si-gateway" or "statefulset"
    local namespace="${3:-${K8S_TEST_NAMESPACE}}"
    if kubectl get "${resource}" -n "${namespace}" >/dev/null 2>&1; then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}: ${resource} not found in namespace ${namespace}"
        return 1
    fi
}

# Poll until a resource exists, then return 0; return 1 on timeout.
wait_for_k8s_resource() {
    local resource="$1"
    local namespace="${2:-${K8S_TEST_NAMESPACE}}"
    local timeout="${3:-${K8S_RESOURCE_TIMEOUT:-60}}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if kubectl get "${resource}" -n "${namespace}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5; (( elapsed += 5 )) || true
    done
    return 1
}

# Read a jsonpath expression from a resource.
k8s_jsonpath() {
    local resource="$1"
    local jsonpath="$2"
    local namespace="${3:-${K8S_TEST_NAMESPACE}}"
    kubectl get "${resource}" -n "${namespace}" -o "jsonpath=${jsonpath}" 2>/dev/null
}

# Assert a jsonpath value equals an expected string.
assert_k8s_field() {
    local description="$1"
    local resource="$2"
    local jsonpath="$3"
    local expected="$4"
    local namespace="${5:-${K8S_TEST_NAMESPACE}}"
    local actual
    actual=$(k8s_jsonpath "${resource}" "${jsonpath}" "${namespace}")
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}: expected '${expected}', got '${actual}'"
        return 1
    fi
}

# Assert a jsonpath value matches a regex pattern.
assert_k8s_field_matches() {
    local description="$1"
    local resource="$2"
    local jsonpath="$3"
    local pattern="$4"
    local namespace="${5:-${K8S_TEST_NAMESPACE}}"
    local actual
    actual=$(k8s_jsonpath "${resource}" "${jsonpath}" "${namespace}")
    if echo "${actual}" | grep -qE "${pattern}"; then
        log_pass "${description}"
        return 0
    else
        log_fail "${description}: '${actual}' does not match pattern '${pattern}'"
        return 1
    fi
}

# Poll until a resource status condition type reaches status=True.
wait_for_k8s_condition() {
    local resource="$1"
    local condition_type="$2"
    local namespace="${3:-${K8S_TEST_NAMESPACE}}"
    local timeout="${4:-${K8S_GATEWAY_TIMEOUT:-120}}"
    local elapsed=0
    while (( elapsed < timeout )); do
        local status
        status=$(kubectl get "${resource}" -n "${namespace}" \
            -o "jsonpath={.status.conditions[?(@.type=='${condition_type}')].status}" 2>/dev/null)
        [[ "${status}" == "True" ]] && return 0
        sleep 10; (( elapsed += 10 )) || true
    done
    return 1
}

# Assert a resource condition is True (waiting up to timeout seconds).
assert_k8s_condition() {
    local description="$1"
    local resource="$2"
    local condition_type="$3"
    local namespace="${4:-${K8S_TEST_NAMESPACE}}"
    local timeout="${5:-${K8S_GATEWAY_TIMEOUT:-120}}"
    if wait_for_k8s_condition "${resource}" "${condition_type}" "${namespace}" "${timeout}"; then
        log_pass "${description}"
        return 0
    else
        local reason
        reason=$(kubectl get "${resource}" -n "${namespace}" \
            -o "jsonpath={.status.conditions[?(@.type=='${condition_type}')].reason}" 2>/dev/null)
        log_fail "${description}: condition ${condition_type} not True after ${timeout}s (reason: ${reason:-unknown})"
        return 1
    fi
}

# Poll until a StatefulSet has all replicas ready.
wait_for_statefulset_ready() {
    local name="$1"
    local namespace="${2:-${K8S_TEST_NAMESPACE}}"
    local timeout="${3:-${K8S_POD_TIMEOUT:-360}}"
    local replicas="${4:-1}"
    local elapsed=0
    while (( elapsed < timeout )); do
        local ready
        ready=$(kubectl get statefulset "${name}" -n "${namespace}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        [[ "${ready}" == "${replicas}" ]] && return 0
        sleep 15; (( elapsed += 15 )) || true
    done
    return 1
}

# Assert a StatefulSet has all replicas ready.
assert_statefulset_ready() {
    local description="$1"
    local name="$2"
    local namespace="${3:-${K8S_TEST_NAMESPACE}}"
    local timeout="${4:-${K8S_POD_TIMEOUT:-360}}"
    local replicas="${5:-1}"
    if wait_for_statefulset_ready "${name}" "${namespace}" "${timeout}" "${replicas}"; then
        log_pass "${description}"
        return 0
    else
        local ready
        ready=$(kubectl get statefulset "${name}" -n "${namespace}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        log_fail "${description}: only ${ready:-0}/${replicas} ready after ${timeout}s"
        kubectl describe statefulset "${name}" -n "${namespace}" 2>/dev/null | tail -20 >&2 || true
        return 1
    fi
}

# Assert an HTTPS endpoint returns the expected HTTP status code.
# Skips TLS certificate verification (-k).
assert_https_status() {
    local description="$1"
    local url="$2"
    local expected_status="$3"
    shift 3
    local actual_status
    actual_status=$(curl -sk -o /dev/null -w "%{http_code}" "$@" "${url}" 2>/dev/null || echo "000")
    if [[ "${actual_status}" == "${expected_status}" ]]; then
        log_pass "${description} (HTTP ${actual_status})"
        return 0
    else
        log_fail "${description}: expected HTTP ${expected_status}, got ${actual_status}"
        return 1
    fi
}

# ─── File/directory assertion helpers ────────────────────────────────────────

assert_file_exists() {
    local description="$1" path="$2"
    if [[ -f "${path}" ]]; then
        log_pass "${description}"; return 0
    else
        log_fail "${description}: file not found: ${path}"; return 1
    fi
}

assert_dir_file_count() {
    local description="$1" dir="$2" pattern="$3" expected="$4"
    local actual
    actual=$(find "${dir}" -maxdepth 1 -name "${pattern}" | wc -l | tr -d ' ')
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (${actual} files)"; return 0
    else
        log_fail "${description}: expected ${expected} matching '${pattern}', got ${actual}"; return 1
    fi
}

# ─── RabbitMQ helpers ────────────────────────────────────────────────────────

# Publish a JSON payload to a RabbitMQ exchange via rabbitmqadmin inside the container.
rabbitmq_publish() {
    local exchange="$1"
    local routing_key="$2"
    local payload="$3"
    docker exec "${RABBITMQ_CONTAINER}" \
        rabbitmqadmin publish exchange="${exchange}" routing_key="${routing_key}" \
        payload="${payload}" 2>/dev/null
}

# Drop every message left in a queue by earlier runs.
rabbitmq_purge() {
    local queue="$1"
    docker exec "${RABBITMQ_CONTAINER}" rabbitmqctl purge_queue "${queue}" >/dev/null 2>&1 ||
        log_warn "Could not purge RabbitMQ queue ${queue}"
}

# Consume (get) up to N messages from a RabbitMQ queue. Returns raw rabbitmqadmin table output.
rabbitmq_get() {
    local queue="$1"
    local count="${2:-5}"
    docker exec "${RABBITMQ_CONTAINER}" \
        rabbitmqadmin get queue="${queue}" count="${count}" ackmode=ack_requeue_false 2>/dev/null || true
}

# ─── Redis helpers ────────────────────────────────────────────────────────────

# Run a redis-cli command inside the Redis container.
redis_cli() {
    docker exec "${REDIS_CONTAINER}" redis-cli "$@" 2>/dev/null
}

# Assert that Redis DBSIZE is at least the expected number.
assert_redis_key_count_gte() {
    local description="$1"
    local expected="$2"
    local actual
    actual=$(redis_cli DBSIZE | tr -d '[:space:]')
    if [[ "${actual}" -ge "${expected}" ]] 2>/dev/null; then
        log_pass "${description} (Redis DBSIZE=${actual})"
        return 0
    else
        log_fail "${description}: expected DBSIZE >= ${expected}, got '${actual}'"
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

# ─── MongoDB helpers (TC54) ─────────────────────────────────────────────────
mongodb_eval() {
    local expression="$1"
    docker exec "${MONGODB_CONTAINER}" mongosh --quiet --username "${MONGODB_USER}" --password "${MONGODB_PASS}" \
        --authenticationDatabase admin "${MONGODB_DB}" --eval "${expression}" 2>/dev/null
}

assert_mongodb_count() {
    local description="$1"
    local collection="$2"
    local expected="$3"
    local actual
    actual=$(mongodb_eval "db.getCollection('${collection}').countDocuments({})" | tr -d '[:space:]')
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (MongoDB ${collection} count = ${actual})"
        return 0
    fi
    log_fail "${description}: expected ${expected} documents in ${collection}, got '${actual}'"
    return 1
}

assert_mongodb_field() {
    local description="$1"
    local collection="$2"
    local customer_id="$3"
    local expected_tier="$4"
    local actual
    actual=$(mongodb_eval "const d = db.getCollection('${collection}').findOne({customerId: '${customer_id}'}); print(d ? d.tier : '');" | tr -d '[:space:]')
    if [[ "${actual}" == "${expected_tier}" ]]; then
        log_pass "${description} (tier = ${actual})"
        return 0
    fi
    log_fail "${description}: expected tier '${expected_tier}', got '${actual}'"
    return 1
}

# ─── PostgreSQL helpers (TC48, TC49) ─────────────────────────────────────────
require_postgres_running() {
    require_docker_container "${POSTGRES_CONTAINER}"
}

postgres_query() {
    local sql="$1"
    docker exec "${POSTGRES_CONTAINER}" \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tA -c "${sql}" 2>/dev/null
}

assert_postgres_count() {
    local description="$1"
    local table="$2"
    local expected="$3"
    local actual
    actual=$(postgres_query "SELECT COUNT(*) FROM ${table};" | tr -d '[:space:]')
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (Postgres ${table} count = ${actual})"
        return 0
    else
        log_fail "${description}: expected ${expected} rows in ${table}, got '${actual}'"
        return 1
    fi
}

# Drop the Debezium replication slot so repeated runs do not exhaust
# max_replication_slots. Inactive slots also pin WAL segments on disk.
drop_pg_replication_slots() {
    local slots=""
    slots=$(postgres_query "SELECT slot_name FROM pg_replication_slots WHERE plugin='pgoutput';") || true
    local s
    for s in ${slots}; do
        postgres_query "SELECT pg_drop_replication_slot('${s}');" >/dev/null 2>&1 || true
    done
}

# These helpers never return non-zero, so a test can use them in a bare
# assignment without the result depending on the shell's errexit setting.
pgjdbc_jar() {
    local j=""
    j=$(ls "${SI_HOME}/lib/postgresql-"*.jar 2>/dev/null | head -1) || true
    printf '%s' "${j}"
}

pgjdbc_version() {
    local jar="$1"
    local v=""
    v=$(unzip -p "${jar}" META-INF/MANIFEST.MF 2>/dev/null \
        | tr -d '\r' | awk -F': ' '/^Implementation-Version:/{print $2; exit}') || true
    printf '%s' "${v}"
}

# The capability the driver must have, tested directly rather than by version
# string: Debezium 3.6.1 calls ChainedCommonStreamBuilder.withAutomaticFlush(boolean),
# absent before pgjdbc 42.7.11. A version string can lie (repackaged or vendor
# builds); the method either is in the jar or is not.
pgjdbc_has_automatic_flush() {
    local jar="$1"
    unzip -p "${jar}" org/postgresql/replication/fluent/ChainedCommonStreamBuilder.class 2>/dev/null \
        | LC_ALL=C grep -aq 'withAutomaticFlush'
}

# ─── Oracle + LDAP helpers (TC52) ────────────────────────────────────────────
require_oracle_ldap_running() {
    require_docker_container "${ORACLE_CONTAINER}"
    require_docker_container "${LDAP_CONTAINER}"
}

oracle_query() {
    local sql="$1"
    printf 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0\n%s\nEXIT\n' "${sql}" \
        | docker exec -i "${ORACLE_CONTAINER}" \
            sqlplus -s "${ORACLE_USER}/${ORACLE_PASS}@localhost:1521/${ORACLE_SERVICE}" 2>/dev/null
}

assert_oracle_count() {
    local description="$1"
    local table="$2"
    local expected="$3"
    local actual
    actual=$(oracle_query "SELECT COUNT(*) FROM ${table};" | tr -d '[:space:]')
    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "${description} (Oracle ${table} count = ${actual})"
        return 0
    else
        log_fail "${description}: expected ${expected} rows in ${table}, got '${actual}'"
        return 1
    fi
}
