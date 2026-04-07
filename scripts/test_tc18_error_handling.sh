#!/usr/bin/env bash
# TC18: Error routing via cast null-check (valid vs invalid event separation)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC18"

require_si_running
URL="http://localhost:${PORT_TC18}/TC18_ErrorHandling/InputStream"

log_info "T1: Send valid numeric string - should go to VALID stream"
post_event "${URL}" '{"eventId":"ev-1","numericValue":"123.45","category":"sensor"}' >/dev/null
assert_log_contains "T1: valid event logged [TC18-VALID]" '\[TC18-VALID\].*ev-1' 20

# Record log position before sending ev-2 so negative checks only scan NEW lines
LOG_BASELINE=$(wc -l < "${SI_LOG}" 2>/dev/null || echo 0)

log_info "T2: Send non-numeric string - should go to INVALID stream"
post_event "${URL}" '{"eventId":"ev-2","numericValue":"not-a-number","category":"sensor"}' >/dev/null
assert_log_contains "T2: invalid event logged [TC18-INVALID]" '\[TC18-INVALID\].*ev-2' 15

log_info "T3: [TC18-VALID] should NOT contain ev-2 (checking only new log lines)"
sleep 2
if tail -n +"$((LOG_BASELINE + 1))" "${SI_LOG}" 2>/dev/null | grep -E '\[TC18-VALID\]' | grep -q 'ev-2'; then
    log_fail "T3: ev-2 (invalid) incorrectly routed to VALID stream"
else
    log_pass "T3: ev-2 correctly absent from VALID stream"
fi

log_info "T4: [TC18-INVALID] should NOT contain ev-1"
if tail -n +"$((LOG_BASELINE + 1))" "${SI_LOG}" 2>/dev/null | grep -E '\[TC18-INVALID\]' | grep -q 'ev-1'; then
    log_fail "T4: ev-1 (valid) incorrectly routed to INVALID stream"
else
    log_pass "T4: ev-1 correctly absent from INVALID stream"
fi

log_info "T5: Send mixed batch (5 valid, 3 invalid)"
for val in "10.0" "20.5" "abc" "30.0" "NaN-text" "40.0" "fifty" "50.0"; do
    evid="ev-batch-${val//[^a-zA-Z0-9]/-}"
    post_event "${URL}" "{\"eventId\":\"${evid}\",\"numericValue\":\"${val}\",\"category\":\"batch\"}" >/dev/null
    sleep 0.2
done
sleep 3

log_info "T6: Verify ValidEventTable and InvalidEventTable counts"
# valid: ev-1, ev-batch-10-0, ev-batch-20-5, ev-batch-30-0, ev-batch-40-0, ev-batch-50-0 = 6
# invalid: ev-2, ev-batch-abc, ev-batch-NaN-text, ev-batch-fifty = 4
assert_store_count "T6a: ValidEventTable has 6 entries" "TC18_ErrorHandling" \
    "from ValidEventTable select *" 6

assert_store_count "T6b: InvalidEventTable has 4 entries" "TC18_ErrorHandling" \
    "from InvalidEventTable select *" 4

log_info "T7: Edge case - integer string is valid"
post_event "${URL}" '{"eventId":"ev-int","numericValue":"42","category":"edge"}' >/dev/null
assert_log_contains "T7: integer string routed to VALID" '\[TC18-VALID\].*ev-int' 15
sleep 3
assert_store_count "T7: ValidEventTable grows to 7" "TC18_ErrorHandling" \
    "from ValidEventTable select *" 7

log_info "T8: Edge case - empty string is invalid"
post_event "${URL}" '{"eventId":"ev-empty","numericValue":"","category":"edge"}' >/dev/null
assert_log_contains "T8: empty string routed to INVALID" '\[TC18-INVALID\].*ev-empty' 15
sleep 3
assert_store_count "T8: InvalidEventTable grows to 5" "TC18_ErrorHandling" \
    "from InvalidEventTable select *" 5

print_summary; tc_exit_code
