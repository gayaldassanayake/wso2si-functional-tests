#!/usr/bin/env bash
# run_all_tests.sh — WSO2 SI Functional Test Suite Orchestrator
#
# Usage:
#   ./run_all_tests.sh                    # Core tests (no external infra)
#   ./run_all_tests.sh --with-kafka       # Core + Kafka tests
#   ./run_all_tests.sh --with-mysql       # Core + MySQL tests (TC07, TC11, TC39, TC61)
#   ./run_all_tests.sh --with-rabbitmq    # Core + RabbitMQ tests (TC45)
#   ./run_all_tests.sh --with-redis       # Core + Redis tests (TC46)
#   ./run_all_tests.sh --with-samba       # Core + SMB file tests (TC65)
#   ./run_all_tests.sh --with-ftp         # Core + FTP/SFTP file tests (TC72)
#   ./run_all_tests.sh --with-mongodb     # Core + MongoDB store/CDC tests (TC54, TC55)
#   ./run_all_tests.sh --with-postgres    # Core + PostgreSQL CDC tests (TC48, TC49)
#   ./run_all_tests.sh --with-oracle-ldap # Core + Oracle via LDAP naming (TC52)
#   ./run_all_tests.sh --with-thrift      # Core + Thrift DataBridge tests (TC43)
#   ./run_all_tests.sh --with-helm        # Core + Helm chart Gateway API tests (TC19-TC27)
#   ./run_all_tests.sh --with-k8s         # Core + Kubernetes live Gateway API tests (TC28-TC34)
#   ./run_all_tests.sh --all              # All test cases
#   ./run_all_tests.sh --all --skip-helm  # All except Helm chart tests (also skips K8s tests)
#   ./run_all_tests.sh --all --skip-k8s   # All except Kubernetes live tests
#   ./run_all_tests.sh --all --skip-helm --skip-k8s  # All except Helm and K8s tests
#   ./run_all_tests.sh --skip-deploy      # Skip deploying apps (already deployed)
#   ./run_all_tests.sh --with-tools       # Core + distribution tool tests (TC36–38)
#   ./run_all_tests.sh TC01 TC04 TC06     # Run specific test cases
#   ./run_all_tests.sh --all --fail-on-skip  # Exit non-zero if any test was skipped
#
# Prerequisites:
#   1. SI server must be running: ${SI_HOME}/bin/server.sh
#   2. Set SI_HOME to the pack under test: export SI_HOME=/path/to/wso2si-<version>
#      (required; TOOLS_PACK_HOME defaults to it)
#   3. For --with-kafka, --with-mysql, --with-rabbitmq, --with-redis: run ./scripts/setup.sh first
#   4. --with-tools inspects TOOLS_PACK_HOME, which defaults to SI_HOME
#      TC35 (server lifecycle) is standalone — run it separately before starting SI
#   5. TC56 (Kafka deployment.yaml config) is standalone — run it with SI stopped:
#      SI_HOME=... bash scripts/test_tc56_kafka_deployment_config.sh
#   6. TC60 (Oracle error store) is standalone — run it with SI stopped:
#      SI_HOME=... bash scripts/test_tc60_oracle_error_store.sh
#   7. TC62 (Kafka state persistence) is standalone — run it with SI stopped:
#      SI_HOME=... bash scripts/test_tc62_kafka_state_persistence.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/scripts/lib/pack.sh"

WITH_KAFKA=false
WITH_MYSQL=false
WITH_RABBITMQ=false
WITH_REDIS=false
WITH_SAMBA=false
WITH_FTP=false
WITH_MONGODB=false
WITH_POSTGRES=false
WITH_ORACLE_LDAP=false
WITH_THRIFT=false
WITH_HELM=false
WITH_K8S=false
WITH_TOOLS=false
SKIP_DEPLOY=false
SKIP_HELM=false
SKIP_K8S=false
FAIL_ON_SKIP=false
SPECIFIC_TCS=()

for arg in "$@"; do
    case "$arg" in
        --with-kafka)     WITH_KAFKA=true ;;
        --with-mysql)     WITH_MYSQL=true ;;
        --with-rabbitmq)  WITH_RABBITMQ=true ;;
        --with-redis)     WITH_REDIS=true ;;
        --with-samba)     WITH_SAMBA=true ;;
        --with-ftp)       WITH_FTP=true ;;
        --with-mongodb)   WITH_MONGODB=true ;;
        --with-postgres)  WITH_POSTGRES=true ;;
        --with-oracle-ldap) WITH_ORACLE_LDAP=true ;;
        --with-thrift)    WITH_THRIFT=true ;;
        --with-helm)      WITH_HELM=true ;;
        --with-k8s)       WITH_K8S=true ;;
        --with-tools)     WITH_TOOLS=true ;;
        --all)            WITH_KAFKA=true; WITH_MYSQL=true; WITH_RABBITMQ=true; WITH_REDIS=true; WITH_SAMBA=true; WITH_FTP=true; WITH_MONGODB=true; WITH_THRIFT=true; WITH_HELM=true; WITH_K8S=true; WITH_TOOLS=true; WITH_POSTGRES=true; WITH_ORACLE_LDAP=true ;;
        --skip-helm)      SKIP_HELM=true ;;
        --skip-k8s)       SKIP_K8S=true ;;
        --skip-deploy)    SKIP_DEPLOY=true ;;
        --fail-on-skip)   FAIL_ON_SKIP=true ;;
        TC*)              SPECIFIC_TCS+=("$arg") ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -30
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_TCS=()
SKIPPED_TCS=()
PARTIAL_TCS=()
SKIP_EXIT_CODE=77
PARTIAL_SKIP_EXIT_CODE=78

# Core tests (always run unless specific TCs are given)
CORE_TCS=(TC01 TC02 TC03 TC04 TC05 TC06 TC09 TC10 TC12 TC13 TC14 TC15 TC16 TC17 TC18 TC40 TC41 TC42 TC44 TC47 TC50 TC51 TC57 TC59 TC63 TC66 TC67 TC68 TC69 TC70 TC71 TC73 TC74)

# Optional infra-dependent tests
KAFKA_TCS=(TC08 TC58 TC64)
MYSQL_TCS=(TC07 TC11 TC39 TC61)
RABBITMQ_TCS=(TC45)
REDIS_TCS=(TC46)
SAMBA_TCS=(TC65)
FTP_TCS=(TC72)
POSTGRES_TCS=(TC48 TC49)
ORACLE_LDAP_TCS=(TC52)
MONGODB_TCS=(TC54 TC55)
THRIFT_TCS=(TC43)
HELM_TCS=(TC19 TC20 TC21 TC22 TC23 TC24 TC25 TC26 TC27)
K8S_TCS=(TC28 TC29 TC30 TC31 TC32 TC33 TC34)
TOOLS_TCS=(TC36 TC37 TC38 TC53)  # TC35 is standalone — run before starting SI

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Records every TC in a group as skipped, with the reason, so a missing
# prerequisite shows up in the final summary instead of vanishing.
skip_group() {
    local reason="$1"; shift
    local tc
    for tc in "$@"; do
        SKIPPED_TCS+=("${tc} (${reason})")
        (( TOTAL_SKIP++ )) || true
    done
    echo -e "${YELLOW}[SKIP]${NC} $* — ${reason}"
}

# ─── Pre-flight: SI must be running ──────────────────────────────────────────
echo -e "${BOLD}WSO2 SI Functional Test Suite${NC}"

PACK_PROBLEM=$(pack_problem "${SI_HOME}")
if [[ -n "${PACK_PROBLEM}" ]]; then
    echo -e "${RED}[ERROR]${NC} SI_HOME: ${PACK_PROBLEM}"
    exit 1
fi
echo "Pack under test: $(pack_version "${SI_HOME}")"
echo "SI_HOME:         ${SI_HOME}"
if [[ "${TOOLS_PACK_HOME}" != "${SI_HOME}" ]]; then
    TOOLS_PROBLEM=$(pack_problem "${TOOLS_PACK_HOME}")
    echo -e "${YELLOW}[WARN]${NC} TOOLS_PACK_HOME differs from SI_HOME; TC35–TC38 and TC53 inspect it instead:"
    echo "       $(pack_version "${TOOLS_PACK_HOME}")${TOOLS_PROBLEM:+ (${TOOLS_PROBLEM})} at ${TOOLS_PACK_HOME}"
fi
echo ""

if ! nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} SI server is not running on port ${SI_HTTP_PORT}."
    echo "  Start it with: \${SI_HOME}/bin/server.sh"
    echo "  Then wait for 'WSO2 Streaming Integrator started' in the console."
    exit 1
fi
SERVER_PROBLEM=$(si_server_mismatch)
if [[ -n "${SERVER_PROBLEM}" ]]; then
    echo -e "${RED}[ERROR]${NC} The SI on port ${SI_HTTP_PORT} is not the pack under test: ${SERVER_PROBLEM}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} SI server from SI_HOME is running on port ${SI_HTTP_PORT}"

# Verify Store API
if nc -z localhost "${SI_STORE_API_PORT}" 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Store API is available on port ${SI_STORE_API_PORT}"
else
    echo -e "${YELLOW}[WARN]${NC} Store API port ${SI_STORE_API_PORT} is not reachable. TC06+ may fail."
fi

echo ""

# ─── Pre-flight: check optional SI-side JARs before deploying ────────────────
# Deploying an app whose required JARs are absent causes SI to fail that app,
# which can destabilise other running apps (store API returns "currently shut
# down").  Guard the deploy — not just the test — so only deployable apps land
# in SI's hot-deploy directory.

_has_mysql_jdbc() {
    ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | grep -q .
}

_has_kafka_jars() {
    # Kafka OSGi bundles placed in SI lib by the jartobundle.sh conversion step.
    # jartobundle.sh converts hyphens to underscores: kafka-clients-*.jar → kafka_clients_*.jar
    ls "${SI_HOME}/lib/"*kafka-clients*.jar 2>/dev/null | grep -q . ||
    ls "${SI_HOME}/lib/"*kafka_clients*.jar 2>/dev/null | grep -q . ||
    ls "${SI_HOME}/lib/"*kafka_2.*.jar      2>/dev/null | grep -q .
}

_has_pg_jdbc() {
    ls "${SI_HOME}/lib/postgresql-"*.jar 2>/dev/null | grep -q .
}

_has_rabbitmq_jars() {
    ls "${SI_HOME}/lib/"*rabbitmq*.jar          2>/dev/null | grep -q . ||
    ls "${SI_HOME}/wso2/lib/plugins/"*rabbitmq*.jar 2>/dev/null | grep -q .
}

_has_redis_extension() {
    ls "${SI_HOME}/wso2/lib/plugins/"*siddhi-store-redis*.jar 2>/dev/null | grep -q . ||
    ls "${SI_HOME}/lib/"*siddhi-store-redis*.jar              2>/dev/null | grep -q .
}

_has_mongodb_installer_artifacts() {
    local cdc mongo
    cdc="${CDC_VERSION:-$(ext_dep_version "${SI_HOME}" cdc-mongodb siddhi-io-cdc)}"
    mongo=$(ext_dep_version "${SI_HOME}" mongodb mongodb-driver-sync)
    [[ -n "${cdc}" && -n "${mongo}" ]] &&
    ls "${SI_HOME}/lib/"siddhi-store-mongodb-*.jar 2>/dev/null | grep -q . &&
    ls "${SI_HOME}/lib/"siddhi-io-cdc-${cdc}.jar 2>/dev/null | grep -q . &&
    ls "${SI_HOME}/lib/"mongodb_driver_sync_${mongo}_*.jar 2>/dev/null | grep -q . &&
    ls "${SI_HOME}/lib/"mongodb_driver_core_${mongo}_*.jar 2>/dev/null | grep -q . &&
    ls "${SI_HOME}/lib/"bson_${mongo}_*.jar 2>/dev/null | grep -q . &&
    ls "${SI_HOME}/lib/"bson_record_codec_${mongo}_*.jar 2>/dev/null | grep -q .
}

_has_wso2event_jars() {
    compgen -G "${SI_HOME}/lib/siddhi-io-wso2event-*.jar" >/dev/null \
        || compgen -G "${SI_HOME}/wso2/lib/plugins/*siddhi-io-wso2event*.jar" >/dev/null
}

# ─── Deploy Siddhi apps ───────────────────────────────────────────────────────
if [[ "$SKIP_DEPLOY" == "false" && ${#SPECIFIC_TCS[@]} -eq 0 ]]; then
    echo "=== Deploying Siddhi apps ==="
    bash "${SCRIPT_DIR}/scripts/deploy.sh" --core

    if [[ "$WITH_KAFKA" == "true" ]]; then
        if _has_kafka_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --kafka
        else
            skip_group "Kafka OSGi JARs not found in \${SI_HOME}/lib/" "${KAFKA_TCS[@]}"
            echo "       Convert the Kafka client JARs with jartobundle.sh and place them in \${SI_HOME}/lib/, then restart SI."
            WITH_KAFKA=false
        fi
    fi

    if [[ "$WITH_MYSQL" == "true" ]]; then
        if _has_mysql_jdbc; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --mysql
        else
            skip_group "MySQL JDBC driver not found in \${SI_HOME}/lib/" "${MYSQL_TCS[@]}"
            echo "       Download mysql-connector-j-*.jar and place it in \${SI_HOME}/lib/, then restart SI."
            WITH_MYSQL=false
        fi
    fi

    if [[ "$WITH_POSTGRES" == "true" ]]; then
        if _has_pg_jdbc; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --postgres
        else
            skip_group "PostgreSQL JDBC driver not found in \${SI_HOME}/lib/" "${POSTGRES_TCS[@]}"
            echo "       Download postgresql-${PGJDBC_MIN_VERSION}.jar (or newer) into \${SI_HOME}/lib/, then restart SI."
            WITH_POSTGRES=false
        fi
    fi

    if [[ "$WITH_RABBITMQ" == "true" ]]; then
        if _has_rabbitmq_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --rabbitmq
        else
            skip_group "RabbitMQ extension JARs not found" "${RABBITMQ_TCS[@]}"
            echo "       Place siddhi-io-rabbitmq and amqp-client JARs in \${SI_HOME}/lib/, then restart SI."
            WITH_RABBITMQ=false
        fi
    fi

    if [[ "$WITH_REDIS" == "true" ]]; then
        if _has_redis_extension; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --redis
        else
            skip_group "siddhi-store-redis extension not found" "${REDIS_TCS[@]}"
            echo "       Place siddhi-store-redis JAR in \${SI_HOME}/wso2/lib/plugins/, then restart SI."
            WITH_REDIS=false
        fi
    fi

    if [[ "$WITH_MONGODB" == "true" ]]; then
        if _has_mongodb_installer_artifacts; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --mongodb
        else
            echo -e "${RED}[FAIL]${NC} MongoDB store/CDC installer artifacts are not all present."
            echo "       Start SI, run bin/extension-installer.sh install mongodb and install cdc-mongodb, then restart SI."
            exit 1
        fi
    fi

    if [[ "$WITH_THRIFT" == "true" ]]; then
        if _has_wso2event_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --thrift
        else
            SI_HOME="${SI_HOME}" bash "${SCRIPT_DIR}/infra/wso2event/install.sh"
            echo -e "${RED}[FAIL]${NC} The wso2event extensions were missing and are now installed in \${SI_HOME}/lib."
            echo "       Restart SI, then run the tests again."
            exit 1
        fi
    fi
    echo ""
elif [[ ${#SPECIFIC_TCS[@]} -gt 0 && "$SKIP_DEPLOY" == "false" ]]; then
    echo "=== Deploying selected apps ==="
    bash "${SCRIPT_DIR}/scripts/deploy.sh" "${SPECIFIC_TCS[@]}"
    echo ""
fi

# ─── Run test script ──────────────────────────────────────────────────────────
run_test() {
    local tc="$1"       # e.g. TC01
    local script="$2"   # e.g. test_tc01_passthrough.sh
    local label="$3"    # e.g. "Baseline HTTP pass-through"

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${tc}${NC}: ${label}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local script_path="${SCRIPT_DIR}/scripts/${script}"
    if [[ ! -f "${script_path}" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} Script not found: ${script_path}"
        SKIPPED_TCS+=("${tc} (script not found)")
        (( TOTAL_SKIP++ )) || true
        return
    fi

    local rc=0
    bash "${script_path}" || rc=$?
    if [[ $rc -eq 0 ]]; then
        (( TOTAL_PASS++ )) || true
    elif [[ $rc -eq $SKIP_EXIT_CODE ]]; then
        SKIPPED_TCS+=("${tc} (prerequisite missing, see its output)")
        (( TOTAL_SKIP++ )) || true
    elif [[ $rc -eq $PARTIAL_SKIP_EXIT_CODE ]]; then
        (( TOTAL_PASS++ )) || true
        PARTIAL_TCS+=("${tc}")
    else
        FAILED_TCS+=("${tc}")
        (( TOTAL_FAIL++ )) || true
    fi
    echo ""
}

# ─── TC metadata lookup (bash 3.2 compatible - no associative arrays) ─────────

tc_script() {
    case "$1" in
        TC01) echo "test_tc01_passthrough.sh" ;;
        TC02) echo "test_tc02_http_ingest.sh" ;;
        TC03) echo "test_tc03_window_aggregation.sh" ;;
        TC04) echo "test_tc04_filter_transform.sh" ;;
        TC05) echo "test_tc05_pattern_detect.sh" ;;
        TC06) echo "test_tc06_store_query.sh" ;;
        TC07) echo "test_tc07_mysql_persist.sh" ;;
        TC08) echo "test_tc08_kafka.sh" ;;
        TC09) echo "test_tc09_incremental_aggregation.sh" ;;
        TC10) echo "test_tc10_stream_table_join.sh" ;;
        TC11) echo "test_tc11_cdc_polling.sh" ;;
        TC12) echo "test_tc12_file_source.sh" ;;
        TC13) echo "test_tc13_sequence.sh" ;;
        TC14) echo "test_tc14_non_occurrence.sh" ;;
        TC15) echo "test_tc15_format_transform.sh" ;;
        TC16) echo "test_tc16_time_functions.sh" ;;
        TC17) echo "test_tc17_regex_functions.sh" ;;
        TC18) echo "test_tc18_error_handling.sh" ;;
        TC19) echo "test_tc19_helm_lint_defaults.sh" ;;
        TC20) echo "test_tc20_ingress_only_default.sh" ;;
        TC21) echo "test_tc21_gateway_api_enabled.sh" ;;
        TC22) echo "test_tc22_required_tls_secret.sh" ;;
        TC23) echo "test_tc23_backward_compat.sh" ;;
        TC24) echo "test_tc24_external_gateway_ref.sh" ;;
        TC25) echo "test_tc25_backend_tls_policy.sh" ;;
        TC26) echo "test_tc26_rate_limit_policy.sh" ;;
        TC27) echo "test_tc27_mutual_exclusion.sh" ;;
        TC28) echo "test_tc28_k8s_resources_created.sh" ;;
        TC29) echo "test_tc29_k8s_gateway_programmed.sh" ;;
        TC30) echo "test_tc30_k8s_httproute_accepted.sh" ;;
        TC31) echo "test_tc31_k8s_si_pod_ready.sh" ;;
        TC32) echo "test_tc32_k8s_https_routing.sh" ;;
        TC33) echo "test_tc33_k8s_backend_tls.sh" ;;
        TC34) echo "test_tc34_k8s_rate_limit.sh" ;;
        TC35) echo "test_tc35_server_lifecycle.sh" ;;
        TC36) echo "test_tc36_jartobundle.sh" ;;
        TC37) echo "test_tc37_osgi_lib.sh" ;;
        TC38) echo "test_tc38_ciphertool.sh" ;;
        TC53) echo "test_tc53_dependency_floors.sh" ;;
        TC39) echo "test_tc39_cdc_listening.sh" ;;
        TC48) echo "test_tc48_pg_cdc_listening.sh" ;;
        TC49) echo "test_tc49_pg_cdc_polling.sh" ;;
        TC40) echo "test_tc40_file_sink.sh" ;;
        TC41) echo "test_tc41_grpc_echo.sh" ;;
        TC42) echo "test_tc42_grpc_consume.sh" ;;
        TC43) echo "test_tc43_thrift_databridge.sh" ;;
        TC44) echo "test_tc44_http_request_response.sh" ;;
        TC45) echo "test_tc45_rabbitmq.sh" ;;
        TC46) echo "test_tc46_redis_store.sh" ;;
        TC47) echo "test_tc47_xml_emit.sh" ;;
        TC50) echo "test_tc50_javascript_function.sh" ;;
        TC51) echo "test_tc51_javascript_eval.sh" ;;
        TC52) echo "test_tc52_oracle_ldap_store.sh" ;;
        TC54) echo "test_tc54_mongodb_store.sh" ;;
        TC55) echo "test_tc55_mongodb_cdc.sh" ;;
        TC56) echo "test_tc56_kafka_deployment_config.sh" ;;
        TC57) echo "test_tc57_cron_trigger_scheduler.sh" ;;
        TC58) echo "test_tc58_avro_kafka_roundtrip.sh" ;;
        TC59) echo "test_tc59_keyword_attribute_names.sh" ;;
        TC60) echo "test_tc60_oracle_error_store.sh" ;;
        TC61) echo "test_tc61_table_stats_markin.sh" ;;
        TC62) echo "test_tc62_kafka_state_persistence.sh" ;;
        TC63) echo "test_tc63_file_search_dynamic_regex.sh" ;;
        TC64) echo "test_tc64_avro_schema_registry.sh" ;;
        TC65) echo "test_tc65_smb_file.sh" ;;
        TC66) echo "test_tc66_map_functions.sh" ;;
        TC67) echo "test_tc67_http_oauth_sink.sh" ;;
        TC68) echo "test_tc68_https_and_auth.sh" ;;
        TC69) echo "test_tc69_grpc_tls.sh" ;;
        TC70) echo "test_tc70_tcp_transport.sh" ;;
        TC71) echo "test_tc71_websocket_transport.sh" ;;
        TC72) echo "test_tc72_remote_file.sh" ;;
        TC73) echo "test_tc73_json_list_functions.sh" ;;
        TC74) echo "test_tc74_text_mapper.sh" ;;
        *) echo "" ;;
    esac
}

tc_label() {
    case "$1" in
        TC01) echo "Baseline HTTP pass-through" ;;
        TC02) echo "HTTP ingest + in-memory table + Store API" ;;
        TC03) echo "Window aggregations (time + length-batch)" ;;
        TC04) echo "Filter predicates + str/math transforms" ;;
        TC05) echo "Sequential pattern detection (->)" ;;
        TC06) echo "Store Query API (exhaustive)" ;;
        TC07) echo "MySQL RDBMS store [requires MySQL]" ;;
        TC08) echo "Kafka source + filtered sink [requires Kafka]" ;;
        TC09) echo "Incremental aggregation (per-granularity)" ;;
        TC10) echo "Stream-to-table join (data enrichment)" ;;
        TC11) echo "CDC polling mode [requires MySQL]" ;;
        TC12) echo "File source (LINE mode + tailing)" ;;
        TC13) echo "Sequence detection (consecutive events)" ;;
        TC14) echo "Non-occurrence pattern (missing heartbeat)" ;;
        TC15) echo "Format transformation (XML/JSON-custom/CSV)" ;;
        TC16) echo "Time extension functions" ;;
        TC17) echo "Regex extension functions" ;;
        TC18) echo "Error routing (regex numeric validation)" ;;
        TC19) echo "Helm lint — default values (backward compat baseline)" ;;
        TC20) echo "Helm template — Ingress-only default rendering" ;;
        TC21) echo "Helm template — Gateway API enabled, Ingress suppressed" ;;
        TC22) echo "Helm template — required tlsSecret validation" ;;
        TC23) echo "Helm template — backward compat with pre-gatewayApi values" ;;
        TC24) echo "Helm template — external Gateway reference (create=false)" ;;
        TC25) echo "Helm template — BackendTLSPolicy content and targeting" ;;
        TC26) echo "Helm template — BackendTrafficPolicy rate limit values" ;;
        TC27) echo "Helm template — mutual exclusion (Ingress vs Gateway API)" ;;
        TC28) echo "K8s live — all Gateway API resources created" ;;
        TC29) echo "K8s live — Gateway reaches Programmed=True" ;;
        TC30) echo "K8s live — HTTPRoute Accepted + ResolvedRefs=True" ;;
        TC31) echo "K8s live — SI pod Running and Ready" ;;
        TC32) echo "K8s live — HTTPS routing via Envoy Gateway" ;;
        TC33) echo "K8s live — BackendTLSPolicy created and targeting" ;;
        TC34) echo "K8s live — BackendTrafficPolicy rate limit values" ;;
        TC35) echo "SI server lifecycle — start/stop/restart verification" ;;
        TC36) echo "jartobundle.sh — JAR to OSGi bundle conversion" ;;
        TC37) echo "osgi-lib.sh — OSGi lib deployment to server runtime" ;;
        TC38) echo "ciphertool.sh — encrypt/decrypt round-trip" ;;
        TC53) echo "Dependency floors — Netty/Jackson minimum versions and bundles.info integrity" ;;
        TC39) echo "MySQL CDC listening mode — INSERT/UPDATE/DELETE via Debezium [requires MySQL]" ;;
        TC40) echo "File sink — HTTP events written to CSV file" ;;
        TC41) echo "gRPC echo — request-response round-trip (grpc-service + grpc-call)" ;;
        TC42) echo "gRPC consume — fire-and-forget (grpc source + grpc sink)" ;;
        TC43) echo "Thrift DataBridge (WSO2Event data over TCP, login over SSL; external and legacy clients)" ;;
        TC44) echo "HTTP request/response — http-request sink + http-response source (sink.id correlation)" ;;
        TC45) echo "RabbitMQ pass-through — source + filter + sink [requires RabbitMQ]" ;;
        TC46) echo "Redis store — @store(type=redis) PK upsert + Store API [requires Redis]" ;;
        TC47) echo "XML emit via HTTP sink — self-loop round-trip with ifThenElse classification" ;;
        TC50) echo "JavaScript script function — named function transformation" ;;
        TC51) echo "JavaScript js:eval — dynamic arithmetic and boolean expressions" ;;
        TC52) echo "Oracle RDBMS store via jdbc:oracle:thin:@ldap:// naming [requires Oracle + OpenLDAP]" ;;
        TC54) echo "MongoDB store — Extension Installer runtime dependencies + PK upsert [requires MongoDB]" ;;
        TC55) echo "MongoDB CDC — change-stream insert/update events [requires MongoDB replica set]" ;;
        TC56) echo "Kafka source/sink options from deployment.yaml [standalone, requires Kafka]" ;;
        TC57) echo "Cron triggers — same trigger id in two apps, Quartz scheduler shutdown when idle" ;;
        TC58) echo "Avro sink/source mapping over Kafka — round trip, wire encoding, external record [requires Kafka]" ;;
        TC59) echo "Siddhi keywords (offset, in, per, at, set) as attribute names" ;;
        TC60) echo "Error store on Oracle — create, store, list, replay, purge [standalone, requires Oracle]" ;;
        TC61) echo "RDBMS table statistics while operations fail — no MarkIn errors [requires MySQL driver, Docker]" ;;
        TC62) echo "Kafka source under state persistence — no duplicates across cycles and restart [standalone, requires Kafka]" ;;
        TC63) echo "file:search uses each event's regex when it comes from an attribute" ;;
        TC64) echo "Avro mapping with a Confluent Schema Registry — wire-format source, registry sink, unknown id [requires Kafka]" ;;
        TC65) echo "SMB file sink and dir.uri source over smb:// and smb2:// [requires Samba]" ;;
        TC66) echo "map:createFromJSON, map:toJSON and map:createFromXML on the embedded org.json and commons-lang3" ;;
        TC67) echo "HTTP sink with OAuth 2.0: client credentials grant, 401, token refresh and retry" ;;
        TC68) echo "HTTP over TLS: HTTPS source, mutual TLS, basic auth, HTTPS sink with 'Name: value' headers, REST API alongside" ;;
        TC69) echo "gRPC over TLS: TLS and mutual TLS source and sink, handshake checks, plain-text and certificate-less clients refused" ;;
        TC70) echo "TCP transport: binary, text and JSON mappers over the pack's TCP server, sync sink, burst, bad client" ;;
        TC71) echo "Websocket transport: client and server sinks/sources over ws:// and wss://, burst, TLS upgrade checks" ;;
        TC72) echo "File over FTP and SFTP (password and key): line source with move, append sink, file:isExist/size [requires FTP/SFTP]" ;;
        TC73) echo "JSON and list functions: json:get*/setElement/tokenize/group, list:create/get/add/sort/tokenize/collect" ;;
        TC74) echo "Text mapper: default format, regex groups, missing attributes, templates, mustache, event grouping" ;;
        TC48) echo "PostgreSQL CDC listening mode — INSERT/UPDATE/DELETE via Debezium logical replication [requires PostgreSQL]" ;;
        TC49) echo "PostgreSQL CDC polling mode [requires PostgreSQL]" ;;
        *) echo "Unknown" ;;
    esac
}

if [[ ${#SPECIFIC_TCS[@]} -gt 0 ]]; then
    # Run only specified TCs
    for tc in "${SPECIFIC_TCS[@]}"; do
        script=$(tc_script "$tc")
        if [[ -n "$script" ]]; then
            run_test "$tc" "$script" "$(tc_label "$tc")"
        else
            echo -e "${RED}[ERROR]${NC} Unknown test case: $tc"
            FAILED_TCS+=("${tc} (unknown test case)")
            (( TOTAL_FAIL++ )) || true
        fi
    done
else
    # Run all applicable TCs
    for tc in "${CORE_TCS[@]}"; do
        run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
    done

    if [[ "$WITH_MYSQL" == "true" ]]; then
        for tc in "${MYSQL_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_POSTGRES" == "true" ]]; then
        for tc in "${POSTGRES_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_ORACLE_LDAP" == "true" ]]; then
        for tc in "${ORACLE_LDAP_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_KAFKA" == "true" ]]; then
        for tc in "${KAFKA_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_RABBITMQ" == "true" ]]; then
        for tc in "${RABBITMQ_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_REDIS" == "true" ]]; then
        for tc in "${REDIS_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_SAMBA" == "true" ]]; then
        for tc in "${SAMBA_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_FTP" == "true" ]]; then
        for tc in "${FTP_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_MONGODB" == "true" ]]; then
        for tc in "${MONGODB_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_THRIFT" == "true" ]]; then
        for tc in "${THRIFT_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_HELM" == "true" && "$SKIP_HELM" == "false" ]]; then
        if ! command -v helm >/dev/null 2>&1; then
            skip_group "'helm' not found in PATH" "${HELM_TCS[@]}"
        elif [[ ! -d "${HELM_SI_CHART}" ]]; then
            skip_group "HELM_SI_CHART directory not found: ${HELM_SI_CHART}" "${HELM_TCS[@]}"
        else
            for tc in "${HELM_TCS[@]}"; do
                run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
            done
        fi
    fi

    if [[ "$WITH_K8S" == "true" ]]; then
        if [[ "$SKIP_HELM" == "true" ]]; then
            echo -e "${YELLOW}[SKIP]${NC} Kubernetes live tests skipped — Helm chart tests are skipped (TC28-TC34 depend on chart correctness)."
        elif [[ "$SKIP_K8S" == "true" ]]; then
            echo -e "${YELLOW}[SKIP]${NC} Kubernetes live tests skipped (--skip-k8s)."
        elif ! command -v kubectl >/dev/null 2>&1; then
            skip_group "'kubectl' not found" "${K8S_TCS[@]}"
        elif ! kubectl cluster-info >/dev/null 2>&1; then
            skip_group "no Kubernetes cluster reachable" "${K8S_TCS[@]}"
        else
            for tc in "${K8S_TCS[@]}"; do
                run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
            done
        fi
    fi

    if [[ "$WITH_TOOLS" == "true" ]]; then
        for tc in "${TOOLS_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi
fi

# ─── Final summary ────────────────────────────────────────────────────────────
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
TOTAL=$(( TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP ))
if [[ $TOTAL_FAIL -eq 0 && $TOTAL_SKIP -eq 0 && ${#PARTIAL_TCS[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}FINAL SUMMARY: ${TOTAL_PASS}/${TOTAL} PASSED${NC}"
elif [[ $TOTAL_FAIL -eq 0 && $TOTAL_SKIP -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}FINAL SUMMARY: ${TOTAL_PASS}/${TOTAL} PASSED, ${#PARTIAL_TCS[@]} with skipped checks${NC}"
elif [[ $TOTAL_FAIL -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}FINAL SUMMARY: ${TOTAL_PASS} PASSED, 0 FAILED, ${TOTAL_SKIP} SKIPPED (of ${TOTAL})${NC}"
else
    echo -e "${RED}${BOLD}FINAL SUMMARY: ${TOTAL_PASS} PASSED, ${TOTAL_FAIL} FAILED, ${TOTAL_SKIP} SKIPPED (of ${TOTAL})${NC}"
fi
for tc in ${FAILED_TCS[@]+"${FAILED_TCS[@]}"}; do
    echo -e "  ${RED}FAILED${NC}  ${tc}"
done
for tc in ${SKIPPED_TCS[@]+"${SKIPPED_TCS[@]}"}; do
    echo -e "  ${YELLOW}SKIPPED${NC} ${tc}"
done
for tc in ${PARTIAL_TCS[@]+"${PARTIAL_TCS[@]}"}; do
    echo -e "  ${YELLOW}PASSED, SOME CHECKS SKIPPED${NC} ${tc}"
done
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

if [[ $TOTAL_FAIL -gt 0 ]]; then
    exit 1
fi
if [[ "$FAIL_ON_SKIP" == "true" && $(( TOTAL_SKIP + ${#PARTIAL_TCS[@]} )) -gt 0 ]]; then
    echo "Exiting non-zero because --fail-on-skip was given and tests or checks were skipped."
    exit 1
fi
exit 0
