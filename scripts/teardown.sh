#!/usr/bin/env bash
# teardown.sh — remove deployed Siddhi apps and stop Docker Compose services
#
# Usage:
#   ./scripts/teardown.sh               # Remove all TC apps from SI (leave Docker running)
#   ./scripts/teardown.sh --kafka       # Also stop Kafka + Zookeeper
#   ./scripts/teardown.sh --mysql       # Also stop MySQL
#   ./scripts/teardown.sh --all         # Remove apps + stop all Docker services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SUITE_ROOT}/config.env"

COMPOSE_FILE="${SUITE_ROOT}/infra/docker-compose.yml"

STOP_KAFKA=false
STOP_MYSQL=false

for arg in "$@"; do
    case "$arg" in
        --kafka) STOP_KAFKA=true ;;
        --mysql) STOP_MYSQL=true ;;
        --all)   STOP_KAFKA=true; STOP_MYSQL=true ;;
        *)
            echo "Usage: $0 [--kafka] [--mysql] [--all]"
            exit 1
            ;;
    esac
done

# ─── Remove deployed Siddhi apps ─────────────────────────────────────────────
if [[ -d "${SI_SIDDHI_DIR}" ]]; then
    removed=0
    for f in "${SI_SIDDHI_DIR}"/TC*.siddhi; do
        [[ -f "$f" ]] || continue
        rm -f "$f"
        echo "Removed: $(basename "$f")"
        (( removed++ )) || true
    done
    echo "Removed ${removed} Siddhi app(s) from deployment directory."
else
    echo "[WARN] SI deployment directory not found: ${SI_SIDDHI_DIR}"
fi

# ─── Clean up file source input ──────────────────────────────────────────────
if [[ -f "${FILE_SOURCE_PATH}" ]]; then
    rm -f "${FILE_SOURCE_PATH}"
    echo "Removed file source input: ${FILE_SOURCE_PATH}"
fi

# ─── Stop Docker Compose services ────────────────────────────────────────────
SERVICES=()
if [[ "$STOP_KAFKA" == "true" ]]; then
    SERVICES+=("kafka" "zookeeper")
fi
if [[ "$STOP_MYSQL" == "true" ]]; then
    SERVICES+=("mysql")
fi

if [[ ${#SERVICES[@]} -gt 0 ]]; then
    echo "Stopping Docker services: ${SERVICES[*]}"
    docker compose -f "${COMPOSE_FILE}" rm -sf "${SERVICES[@]}" 2>/dev/null || true
    echo "Docker services stopped and volumes removed."
fi

echo ""
echo "Teardown complete."
