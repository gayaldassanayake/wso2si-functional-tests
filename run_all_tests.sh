#!/usr/bin/env bash
# run_all_tests.sh — WSO2 SI 4.3.2 Functional Test Suite Orchestrator
#
# Usage:
#   ./run_all_tests.sh                  # Core tests (no external infra)
#   ./run_all_tests.sh --with-kafka     # Core + Kafka tests
#   ./run_all_tests.sh --with-mysql     # Core + MySQL tests (TC07, TC11)
#   ./run_all_tests.sh --all            # All 18 test cases
#   ./run_all_tests.sh --skip-deploy    # Skip deploying apps (already deployed)
#   ./run_all_tests.sh TC01 TC04 TC06   # Run specific test cases
#
# Prerequisites:
#   1. SI server must be running: ${SI_HOME}/bin/server.sh
#   2. Set SI_HOME: export SI_HOME=/path/to/wso2si-4.3.2
#      or edit config.env
#   3. For --with-kafka or --with-mysql: run ./scripts/setup.sh first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

WITH_KAFKA=false
WITH_MYSQL=false
SKIP_DEPLOY=false
SPECIFIC_TCS=()

for arg in "$@"; do
    case "$arg" in
        --with-kafka)  WITH_KAFKA=true ;;
        --with-mysql)  WITH_MYSQL=true ;;
        --all)         WITH_KAFKA=true; WITH_MYSQL=true ;;
        --skip-deploy) SKIP_DEPLOY=true ;;
        TC*)           SPECIFIC_TCS+=("$arg") ;;
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
    # Kafka OSGi bundles placed in SI lib by the jartobundle.sh conversion step
    ls "${SI_HOME}/lib/"*kafka-clients*.jar 2>/dev/null | grep -q . ||
    ls "${SI_HOME}/lib/"*kafka_2.*.jar      2>/dev/null | grep -q .
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
        *) echo "Unknown" ;;
    esac
}

# Core tests (always run unless specific TCs are given)
CORE_TCS=(TC01 TC02 TC03 TC04 TC05 TC06 TC09 TC10 TC12 TC13 TC14 TC15 TC16 TC17 TC18)

# Optional infra-dependent tests
KAFKA_TCS=(TC08)
MYSQL_TCS=(TC07 TC11)

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
