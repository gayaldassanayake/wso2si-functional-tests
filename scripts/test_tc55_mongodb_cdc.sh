#!/usr/bin/env bash
# TC55: MongoDB change-stream CDC installed through the SI Extension Installer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC55"

require_si_running
require_mongodb_running

require_cdc_installer_artifacts() {
    local pattern cdc_jars cdc_version mongo_version
    cdc_version="${CDC_VERSION:-$(ext_dep_version "${SI_HOME}" cdc-mongodb siddhi-io-cdc)}"
    mongo_version=$(ext_dep_version "${SI_HOME}" cdc-mongodb mongodb-driver-sync)
    if [[ -z "${cdc_version}" || -z "${mongo_version}" ]]; then
        log_fail "Could not read the cdc-mongodb versions from the pack's extensionDependencies.json"
        return 1
    fi
    cdc_jars=$(ls "${SI_HOME}/lib/"siddhi-io-cdc-*.jar 2>/dev/null)
    if [[ "$(echo "${cdc_jars}" | grep -c .)" -ne 1 || "${cdc_jars}" != *"siddhi-io-cdc-${cdc_version}.jar" ]]; then
        log_fail "Expected exactly one siddhi-io-cdc-${cdc_version}.jar in ${SI_HOME}/lib, found: ${cdc_jars:-none}"
        return 1
    fi
    for pattern in \
        "mongodb_driver_sync_${mongo_version}_*.jar" \
        "mongodb_driver_core_${mongo_version}_*.jar" \
        "bson_${mongo_version}_*.jar" \
        "bson_record_codec_${mongo_version}_*.jar"; do
        if ! ls "${SI_HOME}/lib/"${pattern} 2>/dev/null | grep -q .; then
            log_fail "Required CDC installer artifact is missing: ${pattern} in ${SI_HOME}/lib"
            return 1
        fi
    done
    log_pass "T1: Extension Installer produced siddhi-io-cdc ${cdc_version} and MongoDB ${mongo_version} runtime JARs"
}

MONGO_COLLECTION="TC55_MongoCDC"
INSERT_APP="${SUITE_ROOT}/siddhi-apps/TC55_MongoCDCInsert.siddhi"
UPDATE_APP="${SUITE_ROOT}/siddhi-apps/TC55_MongoCDCUpdate.siddhi"

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/TC55_MongoCDCInsert.siddhi" "${SI_SIDDHI_DIR}/TC55_MongoCDCUpdate.siddhi"
    mongodb_eval "db.getCollection('${MONGO_COLLECTION}').drop()" >/dev/null || true
}
trap cleanup EXIT

log_lines() {
    wc -l < "${SI_LOG}" 2>/dev/null || echo 0
}

assert_log_since() {
    local baseline="$1" description="$2" pattern="$3" timeout="$4"
    local elapsed=0
    while (( elapsed < timeout )); do
        if tail -n +"$((baseline + 1))" "${SI_LOG}" 2>/dev/null | grep -E "${pattern}" > /dev/null; then
            log_pass "${description}"
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done
    log_fail "${description}: pattern '${pattern}' not found in log within ${timeout}s"
    return 1
}

deploy_cdc_app() {
    local app="$1"
    local app_name="$2"
    local baseline
    baseline=$(log_lines)
    cp "${app}" "${SI_SIDDHI_DIR}/"
    if ! assert_log_since "${baseline}" "${app_name} deployed" "Siddhi App ${app_name} deployed successfully" 45; then
        return 1
    fi
    # Give Debezium's embedded engine time to subscribe before mutating MongoDB.
    sleep 5
}

undeploy_cdc_app() {
    local app_name="$1"
    local baseline
    baseline=$(log_lines)
    rm -f "${SI_SIDDHI_DIR}/${app_name}.siddhi"
    assert_log_since "${baseline}" "${app_name} undeployed" "Siddhi App File ${app_name} undeployed successfully" 30
}

require_cdc_installer_artifacts || { print_summary; exit 1; }
undeploy_app "TC55_MongoCDCInsert.siddhi"
undeploy_app "TC55_MongoCDCUpdate.siddhi"
mongodb_eval "db.getCollection('${MONGO_COLLECTION}').drop()" >/dev/null

log_info "T2: Deploy the MongoDB insert CDC app"
deploy_cdc_app "${INSERT_APP}" "TC55_MongoCDCInsert" || { print_summary; exit 1; }

log_info "T3: Insert a MongoDB document and receive its change-stream event"
baseline=$(log_lines)
mongodb_eval "db.getCollection('${MONGO_COLLECTION}').insertOne({recordId: 'C1', name: 'Ada', tier: 'gold', price: 2.5})" >/dev/null
if ! assert_log_since "${baseline}" "T3: insert change event is logged with its decimal field" '\[TC55-INSERT\].*Ada.*gold.*2\.5' 45; then
    print_summary
    exit 1
fi

undeploy_cdc_app "TC55_MongoCDCInsert" || { print_summary; exit 1; }

log_info "T4: Deploy the MongoDB update CDC app"
deploy_cdc_app "${UPDATE_APP}" "TC55_MongoCDCUpdate" || { print_summary; exit 1; }

log_info "T5: Update the MongoDB document and receive its change-stream event"
baseline=$(log_lines)
mongodb_eval "db.getCollection('${MONGO_COLLECTION}').updateOne({recordId: 'C1'}, {\$set: {tier: 'platinum'}})" >/dev/null
if ! assert_log_since "${baseline}" "T5: update change event is logged" '\[TC55-UPDATE\].*data=\[[0-9a-f]{24}, platinum\]' 45; then
    print_summary
    exit 1
fi

print_summary; tc_exit_code
