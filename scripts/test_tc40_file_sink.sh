#!/usr/bin/env bash
# TC40: File sink — write HTTP-triggered events to a CSV file
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC40"

require_si_running

cleanup() { rm -f "${FILE_SINK_PATH_TC40}"; }
trap cleanup EXIT

log_info "T1: TC40 app started"
undeploy_app "TC40_FileSink.siddhi"
deploy_app   "TC40_FileSink.siddhi"
assert_log_contains "T1: TC40 app started" 'TC40_FileSink.*deployed successfully' 30

log_info "T2: POST one event — output file created and contains the product name"
STATUS=$(post_event "http://localhost:${PORT_TC40}/TC40_FileSink/SalesInputStream" \
    '{"product":"apple","quantity":5,"price":1.99}')
if [[ "${STATUS}" != "200" ]]; then
    log_fail "T2: HTTP POST returned ${STATUS}, expected 200"
else
    sleep 3
    assert_file_exists "T2: output file created" "${FILE_SINK_PATH_TC40}"
    if grep -q "apple" "${FILE_SINK_PATH_TC40}" 2>/dev/null; then
        log_pass "T2: file contains 'apple'"
    else
        log_fail "T2: file does not contain 'apple'. Contents: $(cat "${FILE_SINK_PATH_TC40}" 2>/dev/null)"
    fi
fi

log_info "T3: POST two more events — file grows (append mode)"
post_event "http://localhost:${PORT_TC40}/TC40_FileSink/SalesInputStream" \
    '{"product":"banana","quantity":3,"price":0.89}' >/dev/null
post_event "http://localhost:${PORT_TC40}/TC40_FileSink/SalesInputStream" \
    '{"product":"cherry","quantity":12,"price":5.50}' >/dev/null
sleep 3
LINE_COUNT=$(wc -l < "${FILE_SINK_PATH_TC40}" | tr -d ' ')
if (( LINE_COUNT >= 3 )); then
    log_pass "T3: file has ${LINE_COUNT} lines (append mode working)"
else
    log_fail "T3: expected ≥3 lines, got ${LINE_COUNT}"
fi

log_info "T4: All three products present in output file"
for product in apple banana cherry; do
    if grep -q "${product}" "${FILE_SINK_PATH_TC40}"; then
        log_pass "T4: '${product}' found in output file"
    else
        log_fail "T4: '${product}' not found in output file"
    fi
done

log_info "T5: log sink also shows events processed"
assert_log_contains "T5: log sink shows apple" '\[TC40-FILE\].*apple' 5
assert_log_contains "T5: log sink shows banana" '\[TC40-FILE\].*banana' 5

print_summary; tc_exit_code
