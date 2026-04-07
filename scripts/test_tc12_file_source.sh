#!/usr/bin/env bash
# TC12: File source in LINE/tailing mode
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC12"

require_si_running

# Ensure the file exists (deploy.sh creates it, but double-check)
if [[ ! -f "${FILE_SOURCE_PATH}" ]]; then
    touch "${FILE_SOURCE_PATH}"
    log_info "Created file source: ${FILE_SOURCE_PATH}"
fi

log_info "T1: Append one CSV line to file - SI should pick it up"
echo "chocolate,50.0" >> "${FILE_SOURCE_PATH}"
assert_log_contains "T1: file event logged [TC12-FILE]" '\[TC12-FILE\].*chocolate' 30

log_info "T2: Append 3 more lines rapidly"
echo "toffee,25.5" >> "${FILE_SOURCE_PATH}"
echo "cake,150.0" >> "${FILE_SOURCE_PATH}"
echo "marshmallow,12.0" >> "${FILE_SOURCE_PATH}"
assert_log_contains "T2: toffee line processed" '\[TC12-FILE\].*toffee' 20
assert_log_contains "T2: cake line processed" '\[TC12-FILE\].*cake' 10
assert_log_contains "T2: marshmallow line processed" '\[TC12-FILE\].*marshmallow' 10

log_info "T3: Verify Store API (FileSalesTable) - each product is present"
sleep 5
assert_store_count "T3: chocolate in FileSalesTable" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'chocolate'" 1
assert_store_count "T3: toffee in FileSalesTable" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'toffee'" 1
assert_store_count "T3: cake in FileSalesTable" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'cake'" 1
assert_store_count "T3: marshmallow in FileSalesTable" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'marshmallow'" 1

log_info "T4: Append a line for an existing product (toffee) - upsert in table"
echo "toffee,99.9" >> "${FILE_SOURCE_PATH}"
sleep 5
# Toffee should still be present (upserted, not duplicated)
assert_store_count "T4: toffee still present after upsert" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'toffee'" 1

log_info "T5: Append a new product"
echo "fudge,33.3" >> "${FILE_SOURCE_PATH}"
assert_log_contains "T5: fudge line processed" '\[TC12-FILE\].*fudge' 20
sleep 5
assert_store_count "T5: fudge now in FileSalesTable" "TC12_FileSource" \
    "from FileSalesTable select * having name == 'fudge'" 1

print_summary; tc_exit_code
