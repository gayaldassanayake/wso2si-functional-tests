#!/usr/bin/env bash
# deploy.sh — copy Siddhi apps to SI deployment directory
#
# Usage:
#   ./scripts/deploy.sh --core              # TC01-TC06, TC09-TC10, TC12-TC18 (no external infra)
#   ./scripts/deploy.sh --kafka             # Add TC08
#   ./scripts/deploy.sh --mysql             # Add TC07, TC11
#   ./scripts/deploy.sh --all               # All 18 test cases
#   ./scripts/deploy.sh TC01 TC04 TC06      # Deploy specific apps by number

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SUITE_ROOT}/config.env"

APPS_DIR="${SUITE_ROOT}/siddhi-apps"

# All 18 test apps
CORE_APPS=(
    TC01_PassThrough.siddhi
    TC02_HttpIngest.siddhi
    TC03_WindowAggregation.siddhi
    TC04_FilterTransform.siddhi
    TC05_PatternDetect.siddhi
    TC06_StoreAndQuery.siddhi
    TC09_IncrementalAggregation.siddhi
    TC10_StreamTableJoin.siddhi
    TC12_FileSource.siddhi
    TC13_Sequence.siddhi
    TC14_NonOccurrence.siddhi
    TC15_FormatTransform.siddhi
    TC16_TimeFunctions.siddhi
    TC17_RegexFunctions.siddhi
    TC18_ErrorHandling.siddhi
)
KAFKA_APPS=(TC08_KafkaPassThrough.siddhi)
MYSQL_APPS=(TC07_MySQLPersist.siddhi TC11_CDCPolling.siddhi)
FILE_APPS=(TC12_FileSource.siddhi)

TO_DEPLOY=()
INCLUDE_FILE=false

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--core | --kafka | --mysql | --all | TC01 TC02 ...]"
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --core)
            TO_DEPLOY+=("${CORE_APPS[@]}")
            INCLUDE_FILE=true
            ;;
        --kafka)
            TO_DEPLOY+=("${KAFKA_APPS[@]}")
            ;;
        --mysql)
            TO_DEPLOY+=("${MYSQL_APPS[@]}")
            ;;
        --file)
            INCLUDE_FILE=true
            TO_DEPLOY+=(TC12_FileSource.siddhi)
            ;;
        --all)
            TO_DEPLOY+=("${CORE_APPS[@]}" "${KAFKA_APPS[@]}" "${MYSQL_APPS[@]}")
            INCLUDE_FILE=true
            TO_DEPLOY+=(TC12_FileSource.siddhi)
            ;;
        TC*)
            # Match by number prefix or full filename
            matched=false
            for f in "${APPS_DIR}"/TC*.siddhi; do
                fname="$(basename "$f")"
                prefix="${fname%%_*}"  # e.g. TC01
                if [[ "${fname}" == "${arg}" || "${fname}" == "${arg}.siddhi" || "${prefix}" == "${arg}" ]]; then
                    TO_DEPLOY+=("${fname}")
                    matched=true
                fi
            done
            if [[ "$matched" == "false" ]]; then
                echo "[ERROR] Unknown test case: ${arg}"
                exit 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown argument: ${arg}"
            exit 1
            ;;
    esac
done

# Deduplicate (bash 3.2 compatible)
DEDUPED=()
while IFS= read -r line; do
    DEDUPED+=("$line")
done < <(printf '%s\n' "${TO_DEPLOY[@]}" | sort -u)
TO_DEPLOY=("${DEDUPED[@]}")

# Validate SI_SIDDHI_DIR
if [[ ! -d "${SI_SIDDHI_DIR}" ]]; then
    echo "[ERROR] Siddhi deployment directory not found: ${SI_SIDDHI_DIR}"
    echo "  Set SI_HOME correctly in config.env or via: SI_HOME=/path/to/wso2si ./scripts/deploy.sh"
    exit 1
fi

# Create file source input if needed
if [[ "$INCLUDE_FILE" == "true" ]]; then
    if [[ ! -f "${FILE_SOURCE_PATH}" ]]; then
        touch "${FILE_SOURCE_PATH}"
        echo "Created file source input: ${FILE_SOURCE_PATH}"
    fi
fi

# Deploy
echo "Deploying to: ${SI_SIDDHI_DIR}"
for app in "${TO_DEPLOY[@]}"; do
    src="${APPS_DIR}/${app}"
    if [[ ! -f "${src}" ]]; then
        echo "[ERROR] App not found: ${src}"
        exit 1
    fi
    cp "${src}" "${SI_SIDDHI_DIR}/"
    echo "  Copied: ${app}"
done

echo ""
echo "Deployed ${#TO_DEPLOY[@]} app(s). Waiting ${DEPLOY_WAIT_SECONDS}s for SI to pick them up..."
sleep "${DEPLOY_WAIT_SECONDS}"
echo "Done. Check SI log for startup confirmation:"
echo "  tail -f ${SI_LOG}"
