#!/usr/bin/env bash
# TC17: Regex extension functions (find, matches, group)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC17"

require_si_running
URL="http://localhost:${PORT_TC17}/TC17_RegexFunctions/LogLineStream"

log_info "T1: Log line with email - verify email extraction"
post_event "${URL}" '{"lineId":"l1","logLine":"[INFO] User login: john.doe@example.com from 10.0.0.1"}' >/dev/null
assert_log_contains "T1: email found in line l1" '\[TC17-EMAIL\].*true' 20
assert_log_contains "T1: email address extracted" '\[TC17-EMAIL\].*john.doe@example.com' 10

log_info "T2: Log line with IP - verify IP extraction"
assert_log_contains "T2: IP found in line l1" '\[TC17-IP\].*true' 15
assert_log_contains "T2: IP address extracted" '\[TC17-IP\].*10.0.0.1' 10

log_info "T3: Severity extraction for [INFO] line"
assert_log_contains "T3: severity=INFO extracted" '\[TC17-SEVERITY\].*INFO' 15

log_info "T4: Log line without email - verify hasEmail=false"
post_event "${URL}" '{"lineId":"l2","logLine":"[WARN] Disk usage is at 90% capacity"}' >/dev/null
assert_log_contains "T4: no email in l2 (hasEmail=false)" '\[TC17-EMAIL\].*false' 20

log_info "T5: WARN severity extraction"
assert_log_contains "T5: severity=WARN for l2" '\[TC17-SEVERITY\].*WARN' 10

log_info "T6: ERROR severity extraction"
post_event "${URL}" '{"lineId":"l3","logLine":"[ERROR] Connection refused from 192.168.1.100: admin@corp.io"}' >/dev/null
assert_log_contains "T6: severity=ERROR for l3" '\[TC17-SEVERITY\].*ERROR' 20
assert_log_contains "T6: IP 192.168.1.100 extracted" '\[TC17-IP\].*192.168.1.100' 10

log_info "T7: Log line with neither email nor IP"
post_event "${URL}" '{"lineId":"l4","logLine":"System startup complete"}' >/dev/null
assert_log_contains "T7: no email (false) in l4" '\[TC17-EMAIL\].*false' 20
assert_log_contains "T7: severity=UNKNOWN for unstructured line" '\[TC17-SEVERITY\].*UNKNOWN' 10

log_info "T8: Verify RegexResultTable has 4 records"
sleep 3
assert_store_count "T8: RegexResultTable has 4 records" "TC17_RegexFunctions" \
    "from RegexResultTable select *" 4

print_summary; tc_exit_code
