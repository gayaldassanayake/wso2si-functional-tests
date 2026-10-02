#!/usr/bin/env bash
# TC54: MongoDB store installed through the SI Extension Installer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC54"

require_si_running
require_mongodb_running

require_mongo_installer_artifacts() {
    local pattern mongo_version
    mongo_version=$(ext_dep_version "${SI_HOME}" mongodb mongodb-driver-sync)
    if [[ -z "${mongo_version}" ]]; then
        log_fail "Could not read the mongodb-driver-sync version for 'mongodb' from the pack's extensionDependencies.json"
        return 1
    fi
    for pattern in \
        'siddhi-store-mongodb-*.jar' \
        "mongodb_driver_sync_${mongo_version}_*.jar" \
        "mongodb_driver_core_${mongo_version}_*.jar" \
        "bson_${mongo_version}_*.jar" \
        "bson_record_codec_${mongo_version}_*.jar"; do
        if ! ls "${SI_HOME}/lib/"${pattern} 2>/dev/null | grep -q .; then
            log_fail "Required installer artifact is missing: ${pattern} in ${SI_HOME}/lib"
            return 1
        fi
    done
    log_pass "T1: Extension Installer produced MongoDB store and all driver runtime JARs"
}

MONGO_COLLECTION="TC54_MongoStore"
URL="http://localhost:${PORT_TC54}/TC54_MongoStore/CustomerStream"

require_mongo_installer_artifacts || { print_summary; exit 1; }

log_info "T2: Wait for TC54 MongoDB store app to start"
mongodb_eval "db.getCollection('${MONGO_COLLECTION}').drop()" >/dev/null || true
if ! redeploy_app "TC54_MongoStore.siddhi" TC54_MongoStore; then
    print_summary
    exit 1
fi

log_info "T3: POST 3 customer events"
post_event "${URL}" '{"customerId":"C1","name":"Ada","tier":"gold"}' >/dev/null
post_event "${URL}" '{"customerId":"C2","name":"Grace","tier":"silver"}' >/dev/null
post_event "${URL}" '{"customerId":"C3","name":"Linus","tier":"bronze"}' >/dev/null
assert_log_contains "T3: events logged with [TC54-MONGO] prefix" '\[TC54-MONGO\].*Ada' 25

log_info "T4: MongoDB has 3 persisted documents"
assert_mongodb_count "T4: MongoDB has 3 documents" "${MONGO_COLLECTION}" 3
assert_store_count "T4: Store API returns 3 documents" "TC54_MongoStore" \
    "from CustomerTable select customerId, name, tier" 3

log_info "T5: Upsert C1 with a new tier"
post_event "${URL}" '{"customerId":"C1","name":"Ada","tier":"platinum"}' >/dev/null
sleep 3
assert_mongodb_count "T5: MongoDB document count remains 3 after upsert" "${MONGO_COLLECTION}" 3
assert_mongodb_field "T5: MongoDB persisted the upserted tier" "${MONGO_COLLECTION}" "C1" "platinum"
assert_store_count "T5: Store API still returns 3 documents after upsert" "TC54_MongoStore" \
    "from CustomerTable select customerId, name, tier" 3

print_summary; tc_exit_code
