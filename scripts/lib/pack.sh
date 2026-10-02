#!/usr/bin/env bash
# pack.sh — identifies the SI pack under test; sourced by run_all_tests.sh and common.sh.

# Prints the pack's version line (e.g. "WSO2 Streaming Integrator v4.4.1"), or nothing.
pack_version() {
    local version_file="$1/bin/version.txt"
    [[ -f "${version_file}" ]] || return 0
    head -1 "${version_file}" | tr -d '\r'
}

# Prints why SI_HOME can't be tested, or nothing if it is a valid pack.
pack_problem() {
    local home="$1"
    if [[ -z "${home}" ]]; then
        echo "SI_HOME is not set. Export it or pass it inline: SI_HOME=/path/to/wso2si-<version> ./run_all_tests.sh"
    elif [[ ! -f "${home}/bin/version.txt" ]]; then
        echo "not an SI pack (no bin/version.txt): ${home}"
    fi
}

# Prints why the server on SI_HTTP_PORT is not the one started from SI_HOME,
# or nothing if it is. Another pack on the same port would otherwise be tested.
si_server_mismatch() {
    local pid_file="${SI_HOME}/wso2/server/runtime.pid"
    local pid=""
    pid=$(cat "${pid_file}" 2>/dev/null) || true
    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        echo "no SI server is running from SI_HOME (${pid_file} has no live PID)"
        return 0
    fi
    command -v lsof >/dev/null 2>&1 || return 0
    local owners=""
    owners=$(lsof -nP -t -iTCP:"${SI_HTTP_PORT}" -sTCP:LISTEN 2>/dev/null) || true
    if ! printf '%s\n' "${owners}" | grep -qx "${pid}"; then
        echo "port ${SI_HTTP_PORT} is held by PID $(echo ${owners}), not by the SI started from SI_HOME (PID ${pid})"
    fi
    return 0
}

# Prints the version of a dependency that the pack's Extension Installer
# installs for an extension (from extensionDependencies.json), or nothing.
#   ext_dep_version "${SI_HOME}" cdc-mongodb siddhi-io-cdc
ext_dep_version() {
    local json="$1/wso2/server/resources/extensionsInstaller/extensionDependencies.json"
    [[ -f "${json}" ]] || return 0
    python3 - "${json}" "$2" "$3" <<'PY' 2>/dev/null || true
import json, sys
deps = json.load(open(sys.argv[1])).get(sys.argv[2], {}).get("dependencies", [])
print(next((d.get("version", "") for d in deps if d.get("name") == sys.argv[3]), ""))
PY
}
