#!/usr/bin/env bash
# TC53: Distribution dependency hygiene — security version floors and bundles.info integrity
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC53"
require_tools_pack

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
missing="" old="" checked=0
for script in "${installer}/bin/extension-installer" "${installer}/bin/extension-installer.bat"; do
    for jar in $(grep -oE 'log4j-[a-z0-9-]+-[0-9][0-9.]*\.jar' "${script}" 2>/dev/null | sort -u); do
        (( checked++ )) || true
        [[ -f "${installer}/lib/${jar}" ]] || missing+=" $(basename "${script}"):${jar}"
        v=$(echo "${jar}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        version_ge "${v}" "${LOG4J_MIN_VERSION}" || old+=" ${jar}"
    done
done
if (( checked == 0 )); then
    log_fail "T4: no log4j jars named in ${installer}/bin/extension-installer{,.bat}; the check found nothing to inspect"
elif [[ -z "${missing}${old}" ]]; then
    log_pass "T4: installer classpath log4j jars present and >= ${LOG4J_MIN_VERSION} (${checked} checked)"
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

lib_jars=()
for jar in "${TOOLS_PACK_HOME}"/lib/*.jar; do [[ -f "${jar}" ]] && lib_jars+=("${jar}"); done
(( ${#lib_jars[@]} > 0 )) || log_fail "T8/T9: no jars in ${TOOLS_PACK_HOME}/lib; nothing to inspect"

log_info "T8: no lib/ bundle imports Gson's internal package"
gson_internal=""
for jar in ${lib_jars[@]+"${lib_jars[@]}"}; do
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
for jar in ${lib_jars[@]+"${lib_jars[@]}"}; do
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

log_info "T10: log4j embedded in pax-logging at or above ${LOG4J_MIN_VERSION}"
plugins="${TOOLS_PACK_HOME}/wso2/lib/plugins"
pax_jars=("${plugins}"/org.ops4j.pax.logging.pax-logging-api_*.jar "${plugins}"/org.ops4j.pax.logging.pax-logging-log4j2_*.jar)
pax_found=""
for jar in "${pax_jars[@]}"; do
    [[ -f "${jar}" ]] || continue
    pax_found=yes
    # pax-logging-api carries no log4j pom.properties, so log4j-api is read from its export version.
    while read -r artifact version; do
        if [[ "${version}" != "none" ]] && version_ge "${version}" "${LOG4J_MIN_VERSION}"; then
            log_pass "T10: $(basename "${jar}") embeds ${artifact} ${version}"
        else
            log_fail "T10: $(basename "${jar}") embeds ${artifact} ${version}, below ${LOG4J_MIN_VERSION}"
        fi
    done < <(python3 - "${jar}" <<'EOF'
import re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
if 'pax-logging-api' in sys.argv[1]:
    mf = re.sub(r'\r?\n ', '', z.read('META-INF/MANIFEST.MF').decode())
    m = re.search(r'(?:^|,)org\.apache\.logging\.log4j;version="([^"]+)"', mf.split('Export-Package:', 1)[-1])
    print('log4j-api', m.group(1) if m else 'none')
else:
    for a in ('log4j-core', 'log4j-layout-template-json'):
        p = 'META-INF/maven/org.apache.logging.log4j/%s/pom.properties' % a
        v = re.search(r'^version=(\S+)', z.read(p).decode(), re.M) if p in z.namelist() else None
        print(a, v.group(1) if v else 'none')
EOF
)
done
[[ -n "${pax_found}" ]] || log_fail "T10: no pax-logging bundles in wso2/lib/plugins"

log_info "T11: every bundle the launcher loads by filename exists"
launchers=("${TOOLS_PACK_HOME}"/bin/bootstrap/org.wso2.carbon.launcher-*.jar)
if [[ ! -f "${launchers[0]}" ]]; then
    log_fail "T11: no launcher jar in bin/bootstrap"
else
    missing_initial="" initial_count=0
    for entry in $(unzip -p "${launchers[0]}" launch.properties | tr -d '\\\r' \
            | grep -oE 'file:plugins/[^@,[:space:]]+\.jar'); do
        (( initial_count++ )) || true
        [[ -f "${plugins}/${entry#file:plugins/}" ]] || missing_initial+=" ${entry#file:plugins/}"
    done
    if (( initial_count == 0 )); then
        log_fail "T11: no file:plugins/*.jar entries found in launch.properties; the check found nothing to inspect"
    elif [[ -z "${missing_initial}" ]]; then
        log_pass "T11: $(basename "${launchers[0]}") initial bundles all present in wso2/lib/plugins"
    else
        log_fail "T11: $(basename "${launchers[0]}") loads missing jars:${missing_initial}"
    fi
fi

log_info "T12: extension installer's Kafka jars at or above ${KAFKA_CLIENTS_MIN_VERSION}"
ext_deps="${TOOLS_PACK_HOME}/wso2/server/resources/extensionsInstaller/extensionDependencies.json"
if [[ ! -f "${ext_deps}" ]]; then
    log_fail "T12: ${ext_deps} not found"
else
    while read -r dep version; do
        if [[ "${version}" != "none" ]] && version_ge "${version}" "${KAFKA_CLIENTS_MIN_VERSION}"; then
            log_pass "T12: installer list has ${dep} ${version}"
        else
            log_fail "T12: installer list has ${dep} ${version}, below ${KAFKA_CLIENTS_MIN_VERSION}"
        fi
    done < <(python3 - "${ext_deps}" <<'EOF2'
import json, sys
deps = {d['name']: d['version'] for d in json.load(open(sys.argv[1]))['kafka']['dependencies']}
for name in ('kafka-clients', 'kafka-2.13'):
    print(name, deps.get(name, 'none'))
EOF2
)
fi

log_info "T13: siddhi-map-avro embeds none of the old schema registry HTTP client libraries"
avro_jars=("${TOOLS_PACK_HOME}"/lib/siddhi-map-avro-*.jar)
if [[ ! -f "${avro_jars[0]}" ]]; then
    log_fail "T13: no siddhi-map-avro jar in lib/"
else
    # feign, okhttp 3.6.0, okio 1.11.0 (CVE-2023-3635) and org.json 20140107 (CVE-2022-45688, CVE-2023-5072)
    # were embedded for a feign client that no code path used.
    embedded=$(unzip -Z1 "${avro_jars[0]}" 2>/dev/null | grep -E '\.class$' \
        | grep -oE '^(feign|okhttp3|okio|org/json)/' | sort -u | sed 's|/$||' | tr '\n' ' ' || true)
    if [[ -z "${embedded}" ]]; then
        log_pass "T13: $(basename "${avro_jars[0]}") embeds no feign, okhttp3, okio or org.json classes"
    else
        log_fail "T13: $(basename "${avro_jars[0]}") embeds: ${embedded}"
    fi
fi

log_info "T14: commons-beanutils at or above ${BEANUTILS_MIN_VERSION}, no ServiceMix beanutils bundle"
assert_floor "T14: commons-beanutils" '^(commons-beanutils|org\.apache\.commons\.commons-beanutils)$' "${BEANUTILS_MIN_VERSION}"
servicemix=$(bundles_matching '^org\.apache\.servicemix\.bundles\.commons-beanutils$' | tr '\n' ' ')
if [[ -z "${servicemix}" ]]; then
    log_pass "T14: no ServiceMix commons-beanutils bundle installed"
else
    # The ServiceMix bundle repackages commons-beanutils 1.8.3 (CVE-2014-0114, CVE-2019-10086, CVE-2025-48734)
    # under coordinates that vulnerability scanners don't map to upstream.
    log_fail "T14: ServiceMix commons-beanutils installed: ${servicemix}"
fi

log_info "T15: siddhi-io-file embeds BouncyCastle >= ${BOUNCYCASTLE_MIN_VERSION}, no bcpkix and commons-net >= 3.9.0"
file_jars=("${TOOLS_PACK_HOME}"/lib/siddhi-io-file-*.jar)
if [[ ! -f "${file_jars[0]}" ]]; then
    log_fail "T15: no siddhi-io-file jar in lib/"
else
    # The commons-net check looks for FTPClient.setIpAddressFromPasvResponse, added in 3.9.0 for CVE-2021-37533.
    read -r bc_version pkix net_fix < <(python3 - "${file_jars[0]}" <<'EOF'
import re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
prov = 'org/bouncycastle/jce/provider/BouncyCastleProvider.class'
m = re.search(rb'BouncyCastle Security Provider v([0-9.]+)', z.read(prov)) if prov in names else None
pkix_re = re.compile(r'org/bouncycastle/(cert|cms|operator|openssl|pkcs|pkix|tsp|est|dvcs|eac|cmc|mime|voms|mozilla)/')
pkix = sorted({n.split('/')[2] for n in names if pkix_re.match(n)})
ftp = 'org/apache/commons/net/ftp/FTPClient.class'
net_fix = 'none' if ftp not in names else ('yes' if b'setIpAddressFromPasvResponse' in z.read(ftp) else 'no')
print(m.group(1).decode() if m else 'none', ','.join(pkix) or '-', net_fix)
EOF
)
    if [[ "${bc_version}" == "none" ]]; then
        log_fail "T15: $(basename "${file_jars[0]}") has no BouncyCastleProvider; the check found nothing to inspect"
    elif version_ge "${bc_version}" "${BOUNCYCASTLE_MIN_VERSION}"; then
        log_pass "T15: embedded BouncyCastle ${bc_version} >= ${BOUNCYCASTLE_MIN_VERSION}"
    else
        log_fail "T15: embedded BouncyCastle ${bc_version} below ${BOUNCYCASTLE_MIN_VERSION}"
    fi
    if [[ "${pkix}" == "-" ]]; then
        log_pass "T15: $(basename "${file_jars[0]}") embeds no bcpkix packages"
    else
        log_fail "T15: $(basename "${file_jars[0]}") embeds bcpkix packages: ${pkix}"
    fi
    case "${net_fix}" in
        yes) log_pass "T15: embedded commons-net has the CVE-2021-37533 fix" ;;
        no) log_fail "T15: embedded commons-net is older than 3.9.0 (CVE-2021-37533)" ;;
        *) log_fail "T15: $(basename "${file_jars[0]}") has no commons-net FTPClient; the check found nothing to inspect" ;;
    esac
fi

log_info "T16: siddhi-io-file's org.apache.commons.io import range accepts the installed commons-io bundle"
cio_version=$(bundles_matching '^commons-io$' | awk 'NR==1 {print $2}')
if [[ ! -f "${file_jars[0]}" || -z "${cio_version}" ]]; then
    log_fail "T16: siddhi-io-file jar or commons-io bundle missing; the check found nothing to inspect"
else
    # commons-io 2.x also exports its packages at 1.4.9999, and bnd can pick that and generate [1.4,2).
    cio_range=$(python3 - "${file_jars[0]}" <<'EOF'
import re, sys, zipfile
mf = re.sub(r'\r?\n ', '', zipfile.ZipFile(sys.argv[1]).read('META-INF/MANIFEST.MF').decode())
m = re.search(r'(?:^|,)org\.apache\.commons\.io;[^,]*?version="([^"]+)"', mf.split('Import-Package:', 1)[1].split('\n', 1)[0])
print(m.group(1) if m else 'none')
EOF
)
    if python3 - "${cio_range}" "${cio_version}" <<'EOF'
import re, sys
rng, ver = sys.argv[1], sys.argv[2]
key = lambda v: [int(x) for x in re.findall(r'\d+', v)[:3]]
m = re.match(r'([\[(])([^,]+),([^\])]+)([\])])', rng)
if not m:
    sys.exit(1)
lo_ok = key(ver) >= key(m.group(2)) if m.group(1) == '[' else key(ver) > key(m.group(2))
hi_ok = key(ver) < key(m.group(3)) if m.group(4) == ')' else key(ver) <= key(m.group(3))
sys.exit(0 if lo_ok and hi_ok else 1)
EOF
    then
        log_pass "T16: import range ${cio_range} accepts commons-io ${cio_version}"
    else
        log_fail "T16: import range ${cio_range} does not accept commons-io ${cio_version}"
    fi
fi

print_summary; tc_exit_code
