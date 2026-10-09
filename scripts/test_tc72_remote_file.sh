#!/usr/bin/env bash
# TC72: siddhi-io-file over FTP and SFTP (password and key authentication)
#
# siddhi-io-file 2.0.30 runs on the WSO2 VFS 2.10 fork. TC65 covers SMB; this covers the other remote schemes.
#
# FTP runs twice, the second time in a directory created after the first pass. VFS caches FTP directory listings
# across deployments, so one of the two moves fails until that is fixed (also in 4.3.1; SI-WEBSOCKET-FTP-BUGS.md).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC72"

require_si_running
require_ftp_running

TEMPLATE="${SUITE_ROOT}/siddhi-apps/templates/TC72_RemoteFile.siddhi"
RUN_ID="tc72-$(date +%s)"
KEY_DIR_NAME="${RUN_ID}-key"
KEY_DIR="${SI_HOME}/wso2/server/${KEY_DIR_NAME}"
DEPLOYED_APPS=()

cleanup() {
    local app
    for app in "${DEPLOYED_APPS[@]+"${DEPLOYED_APPS[@]}"}"; do rm -f "${SI_SIDDHI_DIR}/${app}"; done
    rm -rf "${KEY_DIR}"
    docker exec "${FTP_CONTAINER}" rm -rf "${FTP_HOME}/${RUN_ID}-ftp" "${FTP_HOME}/${RUN_ID}-ftp2" 2>/dev/null || true
    docker exec "${SFTP_CONTAINER}" sh -c "rm -rf '${SFTP_HOME}/${RUN_ID}-sftp' '${SFTP_HOME}/${RUN_ID}-sftpkey'; \
        sed -i '/${RUN_ID}/d' /home/${SFTP_USER}/.ssh/authorized_keys" 2>/dev/null || true
}
trap cleanup EXIT

post() {
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' -d "{\"event\":$2}" "$1" || true
}

# remote_cat CONTAINER PATH: the file's content, or nothing when it doesn't exist
remote_cat() { docker exec "$1" cat "$2" 2>/dev/null || true; }

# assert_remote_file DESCRIPTION CONTAINER PATH EXPECTED [TIMEOUT]
assert_remote_file() {
    local description="$1" container="$2" path="$3" expected="$4" timeout="${5:-15}" elapsed=0 content=""
    while (( elapsed < timeout )); do
        content=$(remote_cat "${container}" "${path}")
        [[ "${content}" == "${expected}" ]] && break
        sleep 1; (( elapsed++ )) || true
    done
    if [[ "${content}" == "${expected}" ]]; then
        log_pass "${description}"
    elif [[ -z "${content}" ]]; then
        log_fail "${description}: ${path} not found within ${timeout}s"
    else
        log_fail "${description}: ${path} contains '${content}', expected '${expected}'"
    fi
}

# run_remote LABEL APP PORT CONTAINER DIR BASE_URI OPTS SEED_CMD_OWNER
#   DIR is the run directory inside CONTAINER, BASE_URI the same directory as SI addresses it.
run_remote() {
    local label="$1" app="$2" port="$3" container="$4" dir="$5" base="$6" opts="$7" owner="$8"
    local app_file="${app}.siddhi" tag="TC72-${label}" url="http://localhost:${port}/${app}"

    docker exec "${container}" sh -c "mkdir -p '${dir}/in' && printf 'alice,10.5\nbob,20.25\n' > '${dir}/in/sales.csv' \
        && chown -R ${owner} '${dir}'"

    undeploy_app "${app_file}"
    sed -e "s|@APP@|${app}|g" -e "s|@PORT@|${port}|g" -e "s|@BASE@|${base}|g" -e "s|@OPTS@|${opts}|g" \
        -e "s|@TAG@|${tag}|g" "${TEMPLATE}" > "${SI_SIDDHI_DIR}/${app_file}"
    DEPLOYED_APPS+=("${app_file}")
    log_info "${label}: deployed ${app_file} on ${base%%@*}@…${base#*@}"

    if ! assert_app_deployed "${label} T1: ${app} deployed" "${app}" 30; then
        undeploy_app "${app_file}"
        return
    fi

    log_info "${label}: line source reads the remote file and moves it after processing"
    assert_log_contains "${label} T2: first line read" "\[${tag}-READ\].*data=\[alice, 10\.5\]" 30
    assert_log_contains "${label} T2: second line read" "\[${tag}-READ\].*data=\[bob, 20\.25\]" 10
    local moved=false elapsed=0
    while (( elapsed < 15 )); do
        [[ "$(remote_cat "${container}" "${dir}/processed/sales.csv")" == $'alice,10.5\nbob,20.25' ]] && { moved=true; break; }
        sleep 1; (( elapsed++ )) || true
    done
    if [[ "${moved}" == "true" ]] && ! docker exec "${container}" test -e "${dir}/in/sales.csv"; then
        log_pass "${label} T3: file moved from in/ to processed/"
    elif log_since_mark | grep -qE "Could not create (FTP directory|folder) \"${base%%://*}://[^\"]*/${dir##*/}\""; then
        log_fail "${label} T3: move failed creating the existing run directory (VFS FTP caches the parent" \
            "listing across deployments, so a directory created after the first FTP use looks missing)"
    else
        log_fail "${label} T3: file not moved from in/ to processed/ within 15s"
    fi

    log_info "${label}: file sink appends to a remote file"
    post "${url}/WriteStream" "{\"name\":\"${RUN_ID}-carol\",\"amount\":30.5}" >/dev/null
    post "${url}/WriteStream" "{\"name\":\"${RUN_ID}-dave\",\"amount\":-1.25}" >/dev/null
    assert_remote_file "${label} T4: two rows appended" "${container}" "${dir}/out/sales.csv" \
        "${RUN_ID}-carol,30.5"$'\n'"${RUN_ID}-dave,-1.25"

    log_info "${label}: file:isExist and file:size on remote URIs"
    mark_log
    post "${url}/CheckStream" "{\"id\":\"${RUN_ID}-present\",\"path\":\"${base}/out/sales.csv\"}" >/dev/null
    post "${url}/CheckStream" "{\"id\":\"${RUN_ID}-absent\",\"path\":\"${base}/out/none.csv\"}" >/dev/null
    local size
    size=$(remote_cat "${container}" "${dir}/out/sales.csv" | wc -c | tr -d ' ')
    post "${url}/SizeStream" "{\"id\":\"${RUN_ID}-size\",\"path\":\"${base}/out/sales.csv\"}" >/dev/null
    assert_log_contains "${label} T5: existing file reported present" "\[${tag}-EXISTS\].*data=\[${RUN_ID}-present, true\]" 20
    assert_log_contains "${label} T5: missing file reported absent" "\[${tag}-EXISTS\].*data=\[${RUN_ID}-absent, false\]" 10
    assert_log_contains "${label} T5: size matches the remote file (${size} bytes)" "\[${tag}-SIZE\].*data=\[${RUN_ID}-size, ${size}\]" 10

    undeploy_app "${app_file}"
}

RUN_MARK=${LOG_MARK}

run_remote FTP TC72_FtpFile "${PORT_TC72_FTP}" "${FTP_CONTAINER}" "${FTP_HOME}/${RUN_ID}-ftp" \
    "ftp://${FTP_USER}:${FTP_PASSWORD}@${FTP_HOST}:${FTP_PORT}/${RUN_ID}-ftp" "PASSIVE_MODE:true" "${FTP_USER}"
run_remote FTP2 TC72_FtpFile "${PORT_TC72_FTP}" "${FTP_CONTAINER}" "${FTP_HOME}/${RUN_ID}-ftp2" \
    "ftp://${FTP_USER}:${FTP_PASSWORD}@${FTP_HOST}:${FTP_PORT}/${RUN_ID}-ftp2" "PASSIVE_MODE:true" "${FTP_USER}"

SFTP_OPTS="USER_DIR_IS_ROOT:false,AVOID_PERMISSION_CHECK:true"
SFTP_CHROOT_DIR="/${SFTP_HOME#/home/${SFTP_USER}/}"
run_remote SFTP TC72_SftpFile "${PORT_TC72_SFTP}" "${SFTP_CONTAINER}" "${SFTP_HOME}/${RUN_ID}-sftp" \
    "sftp://${SFTP_USER}:${SFTP_PASSWORD}@${SFTP_HOST}:${SFTP_PORT}${SFTP_CHROOT_DIR}/${RUN_ID}-sftp" "${SFTP_OPTS}" 1001:1001

log_info "SFTPKEY: RSA key in PEM format, passed as IDENTITY relative to wso2/server"
mkdir -p "${KEY_DIR}"
ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -C "${RUN_ID}" -f "${KEY_DIR}/id_rsa"
docker exec "${SFTP_CONTAINER}" sh -c "mkdir -p /home/${SFTP_USER}/.ssh && chown 1001:1001 /home/${SFTP_USER}/.ssh \
    && chmod 700 /home/${SFTP_USER}/.ssh"
docker exec -i "${SFTP_CONTAINER}" sh -c "cat >> /home/${SFTP_USER}/.ssh/authorized_keys \
    && chown 1001:1001 /home/${SFTP_USER}/.ssh/authorized_keys && chmod 600 /home/${SFTP_USER}/.ssh/authorized_keys" \
    < "${KEY_DIR}/id_rsa.pub"
run_remote SFTPKEY TC72_SftpKeyFile "${PORT_TC72_SFTP}" "${SFTP_CONTAINER}" "${SFTP_HOME}/${RUN_ID}-sftpkey" \
    "sftp://${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}${SFTP_CHROOT_DIR}/${RUN_ID}-sftpkey" \
    "${SFTP_OPTS},IDENTITY:${KEY_DIR_NAME}/id_rsa" 1001:1001

log_info "T6: no class-loading errors"
LOG_MARK=${RUN_MARK}
assert_log_not_contains "T6: no class-loading errors during the run" \
    'NoClassDefFoundError|ClassNotFoundException|NoSuchMethodError' 0

print_summary; tc_exit_code
