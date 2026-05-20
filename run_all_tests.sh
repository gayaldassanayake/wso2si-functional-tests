#!/usr/bin/env bash
# run_all_tests.sh — WSO2 SI 4.3.2 Functional Test Suite Orchestrator
#
# Usage:
#   ./run_all_tests.sh                    # Core tests (no external infra)
#   ./run_all_tests.sh --with-kafka       # Core + Kafka tests
#   ./run_all_tests.sh --with-mysql       # Core + MySQL tests (TC07, TC11)
#   ./run_all_tests.sh --with-rabbitmq    # Core + RabbitMQ tests (TC45)
#   ./run_all_tests.sh --with-redis       # Core + Redis tests (TC46)
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
#
# Prerequisites:
#   1. SI server must be running: ${SI_HOME}/bin/server.sh
#   2. Set SI_HOME: export SI_HOME=/path/to/wso2si-4.3.2
#      or edit config.env
#   3. For --with-kafka, --with-mysql, --with-rabbitmq, --with-redis: run ./scripts/setup.sh first
#   4. For --with-tools: set TOOLS_PACK_HOME to the SI pack under test
#      TC35 (server lifecycle) is standalone — run it separately before starting SI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

WITH_KAFKA=false
WITH_MYSQL=false
WITH_RABBITMQ=false
WITH_REDIS=false
WITH_THRIFT=false
WITH_HELM=false
WITH_K8S=false
WITH_TOOLS=false
SKIP_DEPLOY=false
SKIP_HELM=false
SKIP_K8S=false
SPECIFIC_TCS=()

for arg in "$@"; do
    case "$arg" in
        --with-kafka)     WITH_KAFKA=true ;;
        --with-mysql)     WITH_MYSQL=true ;;
        --with-rabbitmq)  WITH_RABBITMQ=true ;;
        --with-redis)     WITH_REDIS=true ;;
        --with-thrift)    WITH_THRIFT=true ;;
        --with-helm)      WITH_HELM=true ;;
        --with-k8s)       WITH_K8S=true ;;
        --with-tools)     WITH_TOOLS=true ;;
        --all)            WITH_KAFKA=true; WITH_MYSQL=true; WITH_RABBITMQ=true; WITH_REDIS=true; WITH_THRIFT=true; WITH_HELM=true; WITH_K8S=true; WITH_TOOLS=true ;;
        --skip-helm)      SKIP_HELM=true ;;
        --skip-k8s)       SKIP_K8S=true ;;
        --skip-deploy)    SKIP_DEPLOY=true ;;
        TC*)              SPECIFIC_TCS+=("$arg") ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -20
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Pre-flight: SI must be running ──────────────────────────────────────────
echo -e "${BOLD}WSO2 SI 4.3.2 Functional Test Suite${NC}"
echo "SI_HOME: ${SI_HOME}"
echo ""

if ! nc -z localhost "${SI_HTTP_PORT}" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} SI server is not running on port ${SI_HTTP_PORT}."
    echo "  Start it with: \${SI_HOME}/bin/server.sh"
    echo "  Then wait for 'WSO2 Streaming Integrator started' in the console."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} SI server is running on port ${SI_HTTP_PORT}"

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

_has_rabbitmq_jars() {
    ls "${SI_HOME}/lib/"*rabbitmq*.jar          2>/dev/null | grep -q . ||
    ls "${SI_HOME}/wso2/lib/plugins/"*rabbitmq*.jar 2>/dev/null | grep -q .
}

_has_redis_extension() {
    ls "${SI_HOME}/wso2/lib/plugins/"*siddhi-store-redis*.jar 2>/dev/null | grep -q . ||
    ls "${SI_HOME}/lib/"*siddhi-store-redis*.jar              2>/dev/null | grep -q .
}

_has_wso2event_jars() {
    ls "${SI_HOME}/wso2/lib/plugins/"*siddhi-io-wso2event*.jar 2>/dev/null | grep -q .
}

# ─── Deploy Siddhi apps ───────────────────────────────────────────────────────
if [[ "$SKIP_DEPLOY" == "false" && ${#SPECIFIC_TCS[@]} -eq 0 ]]; then
    echo "=== Deploying Siddhi apps ==="
    bash "${SCRIPT_DIR}/scripts/deploy.sh" --core

    if [[ "$WITH_KAFKA" == "true" ]]; then
        if _has_kafka_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --kafka
        else
            echo -e "${YELLOW}[WARN]${NC} Kafka OSGi JARs not found in ${SI_HOME}/lib/ — skipping TC08 deployment."
            echo "       Convert the Kafka client JARs with jartobundle.sh and place them in \${SI_HOME}/lib/, then restart SI."
            WITH_KAFKA=false
        fi
    fi

    if [[ "$WITH_MYSQL" == "true" ]]; then
        if _has_mysql_jdbc; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --mysql
        else
            echo -e "${YELLOW}[WARN]${NC} MySQL JDBC driver not found in ${SI_HOME}/lib/ — skipping TC07/TC11 deployment."
            echo "       Download mysql-connector-j-*.jar and place it in \${SI_HOME}/lib/, then restart SI."
            WITH_MYSQL=false
        fi
    fi

    if [[ "$WITH_RABBITMQ" == "true" ]]; then
        if _has_rabbitmq_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --rabbitmq
        else
            echo -e "${YELLOW}[WARN]${NC} RabbitMQ extension JARs not found — skipping TC45 deployment."
            echo "       Place siddhi-io-rabbitmq and amqp-client JARs in \${SI_HOME}/lib/, then restart SI."
            WITH_RABBITMQ=false
        fi
    fi

    if [[ "$WITH_REDIS" == "true" ]]; then
        if _has_redis_extension; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --redis
        else
            echo -e "${YELLOW}[WARN]${NC} siddhi-store-redis extension not found — skipping TC46 deployment."
            echo "       Place siddhi-store-redis JAR in \${SI_HOME}/wso2/lib/plugins/, then restart SI."
            WITH_REDIS=false
        fi
    fi

    if [[ "$WITH_THRIFT" == "true" ]]; then
        if _has_wso2event_jars; then
            bash "${SCRIPT_DIR}/scripts/deploy.sh" --thrift
        else
            echo -e "${YELLOW}[WARN]${NC} siddhi-io-wso2event extension not found — skipping TC43 deployment."
            echo "       Place siddhi-io-wso2event and siddhi-map-wso2event JARs in \${SI_HOME}/wso2/lib/plugins/, then restart SI."
            WITH_THRIFT=false
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
        (( TOTAL_SKIP++ )) || true
        return
    fi

    if bash "${script_path}"; then
        (( TOTAL_PASS++ )) || true
    else
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
        TC39) echo "test_tc39_cdc_listening.sh" ;;
        TC40) echo "test_tc40_file_sink.sh" ;;
        TC41) echo "test_tc41_grpc_echo.sh" ;;
        TC42) echo "test_tc42_grpc_consume.sh" ;;
        TC43) echo "test_tc43_thrift_databridge.sh" ;;
        TC44) echo "test_tc44_http_request_response.sh" ;;
        TC45) echo "test_tc45_rabbitmq.sh" ;;
        TC46) echo "test_tc46_redis_store.sh" ;;
        TC47) echo "test_tc47_xml_emit.sh" ;;
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
        TC39) echo "MySQL CDC listening mode — INSERT/UPDATE/DELETE via Debezium [requires MySQL]" ;;
        TC40) echo "File sink — HTTP events written to CSV file" ;;
        TC41) echo "gRPC echo — request-response round-trip (grpc-service + grpc-call)" ;;
        TC42) echo "gRPC consume — fire-and-forget (grpc source + grpc sink)" ;;
        TC43) echo "Thrift DataBridge (WSO2Event TCP+SSL) [requires WSO2Event extensions]" ;;
        TC44) echo "HTTP request/response — http-request sink + http-response source (sink.id correlation)" ;;
        TC45) echo "RabbitMQ pass-through — source + filter + sink [requires RabbitMQ]" ;;
        TC46) echo "Redis store — @store(type=redis) PK upsert + Store API [requires Redis]" ;;
        TC47) echo "XML emit via HTTP sink — self-loop round-trip with ifThenElse classification" ;;
        *) echo "Unknown" ;;
    esac
}

# Core tests (always run unless specific TCs are given)
CORE_TCS=(TC01 TC02 TC03 TC04 TC05 TC06 TC09 TC10 TC12 TC13 TC14 TC15 TC16 TC17 TC18 TC40 TC41 TC42 TC44 TC47)

# Optional infra-dependent tests
KAFKA_TCS=(TC08)
MYSQL_TCS=(TC07 TC11 TC39)
RABBITMQ_TCS=(TC45)
REDIS_TCS=(TC46)
THRIFT_TCS=(TC43)
TOOLS_TCS=(TC36 TC37 TC38)  # TC35 is standalone — run before starting SI

if [[ ${#SPECIFIC_TCS[@]} -gt 0 ]]; then
    # Run only specified TCs
    for tc in "${SPECIFIC_TCS[@]}"; do
        script=$(tc_script "$tc")
        if [[ -n "$script" ]]; then
            run_test "$tc" "$script" "$(tc_label "$tc")"
        else
            echo -e "${YELLOW}[WARN]${NC} Unknown test case: $tc"
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

    if [[ "$WITH_THRIFT" == "true" ]]; then
        for tc in "${THRIFT_TCS[@]}"; do
            run_test "$tc" "$(tc_script "$tc")" "$(tc_label "$tc")"
        done
    fi

    if [[ "$WITH_HELM" == "true" && "$SKIP_HELM" == "false" ]]; then
        if ! command -v helm >/dev/null 2>&1; then
            echo -e "${YELLOW}[WARN]${NC} 'helm' not found in PATH — skipping Helm chart tests (TC19-TC27)."
        elif [[ ! -d "${HELM_SI_CHART}" ]]; then
            echo -e "${YELLOW}[WARN]${NC} HELM_SI_CHART directory not found: ${HELM_SI_CHART} — skipping TC19-TC27."
        else
            for tc in TC19 TC20 TC21 TC22 TC23 TC24 TC25 TC26 TC27; do
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
            echo -e "${YELLOW}[WARN]${NC} 'kubectl' not found — skipping Kubernetes live tests (TC28-TC34)."
        elif ! kubectl cluster-info >/dev/null 2>&1; then
            echo -e "${YELLOW}[WARN]${NC} No Kubernetes cluster reachable — skipping TC28-TC34."
        else
            for tc in TC28 TC29 TC30 TC31 TC32 TC33 TC34; do
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
if [[ $TOTAL_FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}FINAL SUMMARY: ${TOTAL_PASS}/${TOTAL} PASSED${NC}"
else
    echo -e "${RED}${BOLD}FINAL SUMMARY: ${TOTAL_PASS} PASSED, ${TOTAL_FAIL} FAILED, ${TOTAL_SKIP} SKIPPED${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

[[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
