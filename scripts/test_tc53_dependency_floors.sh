#!/usr/bin/env bash
# TC53: Distribution dependency hygiene — security version floors and bundles.info integrity
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC53"

BUNDLES_INFO="${TOOLS_PACK_HOME}/wso2/server/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
require_file "${BUNDLES_INFO}"

# Prints "<symbolic-name> <version>" for bundles matching a regex, one per line.
bundles_matching() {
    grep -vE '^#' "${BUNDLES_INFO}" | awk -F, -v re="$1" '$1 ~ re {print $1, $2}'
}

# Returns 0 when version $1 >= version $2 (numeric compare of the dotted prefix).
version_ge() {
    python3 - "$1" "$2" <<'EOF'
import re, sys
def key(v):
    return [int(x) for x in re.findall(r'\d+', v)[:3]]
sys.exit(0 if key(sys.argv[1]) >= key(sys.argv[2]) else 1)
EOF
}

assert_floor() {
    local label="$1" regex="$2" floor="$3"
    local below="" count=0 name version
    while read -r name version; do
        [[ -z "${name}" ]] && continue
        (( count++ )) || true
        version_ge "${version}" "${floor}" || below+=" ${name}:${version}"
    done < <(bundles_matching "${regex}")
    if [[ ${count} -eq 0 ]]; then
        log_fail "${label}: no bundles matched '${regex}'"
    elif [[ -z "${below}" ]]; then
        log_pass "${label}: all ${count} bundles >= ${floor}"
    else
        log_fail "${label}: below ${floor}:${below}"
    fi
}

log_info "T1: Netty modules at or above ${NETTY_MIN_VERSION}"
assert_floor "T1: Netty" '^io\.netty\.(buffer|codec|codec-http|codec-http2|codec-socks|common|handler|handler-proxy|resolver|transport|transport-native-unix-common)$' "${NETTY_MIN_VERSION}"

log_info "T2: Jackson core/databind/yaml at or above ${JACKSON_MIN_VERSION}"
assert_floor "T2: Jackson" '^com\.fasterxml\.jackson\.(core\.jackson-core|core\.jackson-databind|dataformat\.jackson-dataformat-yaml)$' "${JACKSON_MIN_VERSION}"

log_info "T3: apache-mime4j at or above ${MIME4J_MIN_VERSION}"
assert_floor "T3: apache-mime4j" '^apache-mime4j-core$' "${MIME4J_MIN_VERSION}"

log_info "T4: extension installer log4j jars exist and are at or above ${LOG4J_MIN_VERSION}"
installer="${TOOLS_PACK_HOME}/wso2/tools/extension-installer"
missing="" old=""
for script in "${installer}/bin/extension-installer" "${installer}/bin/extension-installer.bat"; do
    for jar in $(grep -oE 'log4j-[a-z0-9-]+-[0-9][0-9.]*\.jar' "${script}" | sort -u); do
        [[ -f "${installer}/lib/${jar}" ]] || missing+=" $(basename "${script}"):${jar}"
        v=$(echo "${jar}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        version_ge "${v}" "${LOG4J_MIN_VERSION}" || old+=" ${jar}"
    done
done
if [[ -z "${missing}${old}" ]]; then
    log_pass "T4: installer classpath log4j jars present and >= ${LOG4J_MIN_VERSION}"
else
    [[ -n "${missing}" ]] && log_fail "T4: classpath jars not in lib/:${missing}"
    [[ -n "${old}" ]] && log_fail "T4: below ${LOG4J_MIN_VERSION}:${old}"
fi

log_info "T5: no Netty or Jackson bundle installed at two versions"
dups=$(bundles_matching '^(io\.netty\.|com\.fasterxml\.jackson\.)' | awk '{print $1}' | sort | uniq -d | tr '\n' ' ')
if [[ -z "${dups}" ]]; then
    log_pass "T5: no duplicate Netty/Jackson bundles"
else
    log_fail "T5: installed at more than one version: ${dups}"
fi

log_info "T6: every bundles.info entry points at an existing file"
dangling=""
server_dir="${TOOLS_PACK_HOME}/wso2/server"
while IFS=, read -r name version path _; do
    [[ "${name}" == \#* || -z "${path}" ]] && continue
    [[ -e "${server_dir}/${path}" ]] || dangling+=" ${name}:${version}"
done < "${BUNDLES_INFO}"
if [[ -z "${dangling}" ]]; then
    log_pass "T6: no dangling bundles.info entries"
else
    log_fail "T6: entries without a jar:${dangling}"
fi

log_info "T7: siddhi-map-avro embeds snappy-java >= 1.1.10.4 and Avro >= ${AVRO_MIN_VERSION}"
avro_jars=("${TOOLS_PACK_HOME}"/lib/siddhi-map-avro-*.jar)
if [[ ! -f "${avro_jars[0]}" ]]; then
    log_fail "T7: no siddhi-map-avro jar in lib/"
else
    # snappy-java's VERSION file only carries the native library version (1.1.10 for every
    # 1.1.10.x), so the CVE-2024-36124 fix (1.1.10.4) is detected by the chunk-size limit it added.
    read -r snappy_fix avro_version < <(python3 - "${avro_jars[0]}" <<'EOF'
import re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
cls = 'org/xerial/snappy/SnappyInputStream.class'
fix = cls in names and b'max configured chunk size' in z.read(cls)
mf = re.sub(r'\r?\n ', '', z.read('META-INF/MANIFEST.MF').decode())
m = re.search(r'org\.apache\.avro;version="([^"]+)"', mf)
print('yes' if fix else 'no', m.group(1) if m else 'none')
EOF
)
    if [[ "${snappy_fix}" == "yes" ]]; then
        log_pass "T7: $(basename "${avro_jars[0]}") embeds snappy-java with the CVE-2024-36124 fix"
    else
        log_fail "T7: $(basename "${avro_jars[0]}") embeds snappy-java older than 1.1.10.4"
    fi
    if [[ "${avro_version}" != "none" ]] && version_ge "${avro_version}" "${AVRO_MIN_VERSION}"; then
        log_pass "T7: embedded Avro ${avro_version} >= ${AVRO_MIN_VERSION}"
    else
        log_fail "T7: embedded Avro ${avro_version} below ${AVRO_MIN_VERSION}"
    fi
fi

log_info "T8: no lib/ bundle imports Gson's internal package"
gson_internal=""
for jar in "${TOOLS_PACK_HOME}"/lib/*.jar; do
    unzip -p "${jar}" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r\n ' | grep -q 'com\.google\.gson\.internal[;,"]' \
        && gson_internal+=" $(basename "${jar}")"
done
if [[ -z "${gson_internal}" ]]; then
    log_pass "T8: no bundle in lib/ imports com.google.gson.internal"
else
    log_fail "T8: com.google.gson.internal is not exported by any Gson bundle, but imported by:${gson_internal}"
fi

log_info "T9: no lib/ bundle embeds its own Gson"
gson_bundled=""
for jar in "${TOOLS_PACK_HOME}"/lib/*.jar; do
    listing="$(unzip -Z1 "${jar}" 2>/dev/null)"
    grep -q '^com/google/gson/' <<<"${listing}" || continue
    case "$(basename "${jar}")" in
        siddhi-io-kafka-*) log_warn "T9: $(basename "${jar}") still bundles Gson (known, not a 1.1.0 regression)" ;;
        *) gson_bundled+=" $(basename "${jar}")" ;;
    esac
done
if [[ -z "${gson_bundled}" ]]; then
    log_pass "T9: no bundle in lib/ embeds com/google/gson apart from known exceptions"
else
    log_fail "T9: these bundles embed their own Gson copy:${gson_bundled}"
fi

print_summary; tc_exit_code
