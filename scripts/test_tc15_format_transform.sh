#!/usr/bin/env bash
# TC15: Data format transformation (XML XPath, JSON custom attrs, CSV)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC15"

require_si_running
XML_URL="http://localhost:${PORT_TC15}/TC15_FormatTransform/XmlStream"
JSON_CUSTOM_URL="http://localhost:${PORT_TC15}/TC15_FormatTransform/JsonCustomStream"
CSV_URL="http://localhost:${PORT_TC15}/TC15_FormatTransform/CsvStream"

log_info "T1: XML input with XPath custom mapping"
XML_BODY='<events><event><product id="xml-p1"><name>Laptop</name><price>1200.0</price></product></event></events>'
post_raw "${XML_URL}" "application/xml" "${XML_BODY}" >/dev/null
assert_log_contains "T1: XML event mapped and logged" '\[TC15-XML-IN\].*xml-p1' 20

log_info "T2: Verify XML event in FormatTestTable"
sleep 3
response=$(store_query "TC15_FormatTransform" "from FormatTestTable select * having productId == 'xml-p1'")
actual=$(_parse_record_count "${response}")
if [[ "${actual}" == "1" ]]; then
    log_pass "T2: XML event stored in FormatTestTable"
else
    log_fail "T2: expected 1 XML record, got ${actual}. Response: ${response}"
fi

log_info "T3: JSON input with custom @attributes mapping (non-default field path)"
# The mapper maps: $.item.ref -> productId, $.item.label -> name, $.item.cost -> price
JSON_CUSTOM_BODY='{"item":{"ref":"json-p2","label":"Phone","cost":800.0}}'
curl -s -o /dev/null -X POST -H "Content-Type: application/json" \
    -d "${JSON_CUSTOM_BODY}" "${JSON_CUSTOM_URL}" >/dev/null
assert_log_contains "T3: JSON custom-mapped event logged" '\[TC15-JSON-CUSTOM\].*json-p2' 20

log_info "T4: Verify JSON custom event in table"
sleep 3
response=$(store_query "TC15_FormatTransform" "from FormatTestTable select * having productId == 'json-p2'")
actual=$(_parse_record_count "${response}")
if [[ "${actual}" == "1" ]]; then
    log_pass "T4: JSON custom event stored in FormatTestTable"
else
    log_fail "T4: expected 1 JSON-custom record, got ${actual}. Response: ${response}"
fi

log_info "T5: CSV input with default column-order mapping (productId,name,price)"
CSV_BODY="csv-p3,Tablet,450.0"
post_raw "${CSV_URL}" "text/plain" "${CSV_BODY}" >/dev/null
assert_log_contains "T5: CSV event logged" '\[TC15-CSV-IN\].*csv-p3' 20

log_info "T6: Verify all 3 events are in FormatTestTable"
sleep 3
assert_store_count "T6: FormatTestTable has 3 records (xml, json-custom, csv)" \
    "TC15_FormatTransform" "from FormatTestTable select *" 3

log_info "T7: Send another XML event to test repeat ingestion"
XML_BODY2='<events><event><product id="xml-p4"><name>Monitor</name><price>350.0</price></product></event></events>'
post_raw "${XML_URL}" "application/xml" "${XML_BODY2}" >/dev/null
assert_log_contains "T7: second XML event processed" '\[TC15-XML-IN\].*xml-p4' 15
sleep 3
assert_store_count "T7: FormatTestTable grows to 4" \
    "TC15_FormatTransform" "from FormatTestTable select *" 4

print_summary; tc_exit_code
