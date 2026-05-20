#!/usr/bin/env bash
# TC47: XML emit via HTTP sink — XPath ingest, http sink XML output, self-loop round-trip,
#       ifThenElse classification
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC47"

require_si_running

INGEST_URL="http://localhost:${PORT_TC47}/TC47_XmlEmit/XmlInStream"

log_info "T1: Wait for TC47 app to start"
assert_log_contains "T1: TC47 app deployed" 'TC47_XmlEmit.*deployed successfully' 30

log_info "T2: POST XML payload (price=25.5 → priceTag=premium)"
post_raw "${INGEST_URL}" "application/xml" \
    '<product id="P1"><name>Widget</name><price>25.5</price></product>' >/dev/null

log_info "T3: XPath ingest parsed correctly and ifThenElse classified as premium"
# Log format: data=[P1, Widget, 25.5, premium] — match on values not field=value
assert_log_contains "T3: XML parsed — premium" '\[TC47-XML-PARSED\].*P1.*premium' 60

log_info "T4: HTTP sink emitted XML; self-loop echo receiver parsed it correctly"
assert_log_contains "T4: XML echo received — premium" '\[TC47-XML-ECHO\].*P1.*premium' 20

log_info "T5: POST XML payload (price=10.0 → priceTag=standard)"
post_raw "${INGEST_URL}" "application/xml" \
    '<product id="P2"><name>Cheapo</name><price>10.0</price></product>' >/dev/null
assert_log_contains "T5a: XML parsed — standard" '\[TC47-XML-PARSED\].*P2.*standard' 20
assert_log_contains "T5b: XML echo received — standard" '\[TC47-XML-ECHO\].*P2.*standard' 15

print_summary; tc_exit_code
