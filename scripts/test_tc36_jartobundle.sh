#!/usr/bin/env bash
# TC36: jartobundle.sh — convert a directory of JARs to OSGi bundles
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC36"

require_file "${TOOLS_PACK_HOME}/bin/jartobundle.sh"

OUT_DIR="${TOOLS_TEST_TMP}/bundles"
rm -rf "${OUT_DIR}" && mkdir -p "${OUT_DIR}"

cleanup() { rm -rf "${OUT_DIR}"; }
trap cleanup EXIT

INPUT_COUNT=$(find "${TOOLS_PACK_HOME}/lib/" -maxdepth 1 -name "*.jar" | wc -l | tr -d ' ')
log_info "T1: convert ${INPUT_COUNT} JARs from lib/ to OSGi bundles"
sh "${TOOLS_PACK_HOME}/bin/jartobundle.sh" "${TOOLS_PACK_HOME}/lib/" "${OUT_DIR}/" 2>&1
assert_dir_file_count "T1: all input JARs converted" "${OUT_DIR}" "*.jar" "${INPUT_COUNT}"

log_info "T2: sample bundle contains OSGi Bundle-SymbolicName header"
SAMPLE=$(find "${OUT_DIR}" -maxdepth 1 -name "*.jar" | head -1)
if [[ -n "${SAMPLE}" ]] && unzip -p "${SAMPLE}" META-INF/MANIFEST.MF 2>/dev/null | grep -q "Bundle-SymbolicName"; then
    log_pass "T2: Bundle-SymbolicName present in $(basename "${SAMPLE}")"
else
    log_fail "T2: Bundle-SymbolicName missing or no bundles found"
fi

print_summary; tc_exit_code
