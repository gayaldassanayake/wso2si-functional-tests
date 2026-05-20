#!/usr/bin/env bash
# TC37: osgi-lib.sh — deploy a new JAR to the server runtime and verify bundles.info
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC37"

require_file "${TOOLS_PACK_HOME}/bin/osgi-lib.sh"

# osgi-lib.sh checks `java_version_formatted > 1100` and exits on JDK > 11.
# Override JAVA_HOME to a JDK 11 installation when the active JDK is newer.
_JAVA_MAJOR=$(java -version 2>&1 | awk -F '"' '/version/{print $2}' | cut -d. -f1)
if [[ "${_JAVA_MAJOR}" -gt 11 ]]; then
    JAVA11=/Library/Java/JavaVirtualMachines/graalvm-ce-java11-22.3.0/Contents/Home
    if [[ -x "${JAVA11}/bin/java" ]]; then
        export JAVA_HOME="${JAVA11}"
    else
        log_skip "osgi-lib.sh requires JDK ≤ 11 and no JDK 11 found — skipping TC37"
        exit 0
    fi
fi

BUNDLES_INFO="${TOOLS_PACK_HOME}/wso2/server/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
TEST_JAR="${TOOLS_PACK_HOME}/lib/tc21-test-probe.jar"

require_file "${BUNDLES_INFO}"

# Remove any leftover tc21.test.probe entry from a prior interrupted run so that
# osgi-lib.sh always sees it as a new (unregistered) bundle.
rm -f "${TEST_JAR}"
grep -v "tc21.test.probe" "${BUNDLES_INFO}" > "${BUNDLES_INFO}.tmp" \
    && mv "${BUNDLES_INFO}.tmp" "${BUNDLES_INFO}" || true

cleanup() {
    rm -f "${TEST_JAR}"
    rm -rf "${PROBE_TMPDIR:-}"
    # Remove the tc21.test.probe entry from bundles.info (portable grep -v)
    grep -v "tc21.test.probe" "${BUNDLES_INFO}" > "${BUNDLES_INFO}.tmp" \
        && mv "${BUNDLES_INFO}.tmp" "${BUNDLES_INFO}" || true
}
trap cleanup EXIT

# Build a minimal OSGi bundle with a unique Bundle-SymbolicName so the tool
# always sees it as a new registration (never a duplicate of an existing entry).
# Use 'zip' rather than 'jar' — jar overwrites MANIFEST.MF with its own headers.
PROBE_TMPDIR=$(mktemp -d)
mkdir -p "${PROBE_TMPDIR}/META-INF"
printf 'Manifest-Version: 1.0\nBundle-ManifestVersion: 2\nBundle-SymbolicName: tc21.test.probe\nBundle-Version: 1.0.0\nBundle-Name: TC37 Test Probe Bundle\n\n' \
    > "${PROBE_TMPDIR}/META-INF/MANIFEST.MF"
(cd "${PROBE_TMPDIR}" && zip -q "${TEST_JAR}" META-INF/MANIFEST.MF)
rm -rf "${PROBE_TMPDIR}"

BEFORE=$(wc -l < "${BUNDLES_INFO}")
log_info "T1: osgi-lib.sh server — register new JAR in server runtime bundles.info"
sh "${TOOLS_PACK_HOME}/bin/osgi-lib.sh" server 2>&1
AFTER=$(wc -l < "${BUNDLES_INFO}")

if grep -q "tc21.test.probe" "${BUNDLES_INFO}"; then
    log_pass "T1: bundles.info updated (${BEFORE} → ${AFTER} lines, tc21.test.probe registered)"
else
    log_fail "T1: tc21.test.probe not found in bundles.info after osgi-lib.sh"
fi

log_info "T2: test bundle symbolic name present in bundles.info"
if grep -q "tc21.test.probe" "${BUNDLES_INFO}"; then
    log_pass "T2: tc21.test.probe registered in bundles.info"
else
    log_fail "T2: tc21.test.probe not found in bundles.info"
fi

print_summary; tc_exit_code
