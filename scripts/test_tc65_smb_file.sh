#!/usr/bin/env bash
# TC65: SMB file sink and source over smb:// and smb2:// (siddhi-io-file)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC65"

require_si_running
require_samba_running

RUN_ID="tc65-$(date +%s)"
SMB_AUTHORITY="${SAMBA_USER}:${SAMBA_PASSWORD}@${SAMBA_HOST}"
[[ "${SAMBA_PORT}" != "445" ]] && SMB_AUTHORITY+=":${SAMBA_PORT}"
DEPLOYED_APPS=()

cleanup() {
    local app
    for app in "${DEPLOYED_APPS[@]+"${DEPLOYED_APPS[@]}"}"; do rm -f "${SI_SIDDHI_DIR}/${app}"; done
    docker exec "${SAMBA_CONTAINER}" rm -rf "${SAMBA_SHARE_PATH}/${RUN_ID}-smb" "${SAMBA_SHARE_PATH}/${RUN_ID}-smb2" 2>/dev/null || true
}
trap cleanup EXIT

# Waits up to $3 seconds for a file on the share and checks its content.
assert_share_file() {
    local description="$1" path="$2" timeout="$3" expected="$4" content="" elapsed=0
    while (( elapsed < timeout )); do
        content=$(docker exec "${SAMBA_CONTAINER}" cat "${SAMBA_SHARE_PATH}/${path}" 2>/dev/null) && break
        sleep 1; (( elapsed++ )) || true
    done
    if [[ "${content}" == "${expected}" ]]; then
        log_pass "${description}"
    elif [[ -z "${content}" ]]; then
        log_fail "${description}: ${path} not written to the share within ${timeout}s"
    else
        log_fail "${description}: ${path} contains '${content}', expected '${expected}'"
    fi
}

run_scheme() {
    local scheme="$1" app_name="$2" port="$3" prefix="$4"
    local app_file="${app_name}.siddhi" run_dir="${RUN_ID}-${scheme}"

    docker exec "${SAMBA_CONTAINER}" sh -c "mkdir -p '${SAMBA_SHARE_PATH}/${run_dir}/in' '${SAMBA_SHARE_PATH}/${run_dir}/out' \
        && printf 'alice,10.5\nbob,20.25\n' > '${SAMBA_SHARE_PATH}/${run_dir}/in/sales.csv' \
        && chmod -R 777 '${SAMBA_SHARE_PATH}/${run_dir}'"

    undeploy_app "${app_file}"
    sed -e "s|@SMB_BASE@|${scheme}://${SMB_AUTHORITY}/${SAMBA_SHARE}|g" -e "s|@RUN_ID@|${run_dir}|g" \
        "${SUITE_ROOT}/siddhi-apps/templates/${app_file}" > "${SI_SIDDHI_DIR}/${app_file}"
    DEPLOYED_APPS+=("${app_file}")
    log_info "Deployed ${app_file} for ${scheme}://${SAMBA_HOST}/${SAMBA_SHARE}/${run_dir}"

    log_info "${scheme}: app deploys"
    if ! assert_app_deployed "${scheme} T1: ${app_name} deployed" "${app_name}" 30; then
        local reason
        reason=$(log_since_mark | grep -oE "(Exception occurred when getting VFS manager|provided uri for '[a-z.]+' parameter '[^']*' is invalid|unknown protocol: [a-z0-9]+)" | sort -u | tr '\n' ';') || true
        [[ -n "${reason}" ]] && log_info "${scheme}: deployment failed with: ${reason}"
        return
    fi

    log_info "${scheme}: file sink writes an event to the share"
    post_event "http://localhost:${port}/${app_name}/WriteStream" \
        "{\"id\":\"${RUN_ID}-1\",\"payload\":\"hello ${scheme}\"}" >/dev/null
    assert_share_file "${scheme} T2: sink wrote out/${RUN_ID}-1.txt" "${run_dir}/out/${RUN_ID}-1.txt" 20 "hello ${scheme}"

    log_info "${scheme}: dir.uri file source reads a file from the share"
    assert_log_contains "${scheme} T3: source read alice" "\[${prefix}-IN\].*data=\[alice, 10\.5\]" 30
    assert_log_contains "${scheme} T3: source read bob" "\[${prefix}-IN\].*data=\[bob, 20\.25\]" 10

    log_info "${scheme}: no scheme or class-loading errors"
    assert_log_not_contains "${scheme} T4: no unknown-scheme or class-loading errors" \
        "MalformedURLException|unknown protocol: ${scheme}|NoClassDefFoundError|ClassNotFoundException"

    undeploy_app "${app_file}"
}

run_scheme smb TC65_SmbFile "${PORT_TC65}" TC65-SMB
run_scheme smb2 TC65_Smb2File "${PORT_TC65_SMB2}" TC65-SMB2

print_summary; tc_exit_code
