#!/usr/bin/env bash
# setup.sh — start Docker Compose infrastructure services for SI test suite
#
# Usage:
#   ./scripts/setup.sh --kafka          # Start Kafka + Zookeeper only
#   ./scripts/setup.sh --mysql          # Start MySQL only
#   ./scripts/setup.sh --all            # Start all services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SUITE_ROOT}/config.env"

COMPOSE_FILE="${SUITE_ROOT}/infra/docker-compose.yml"

WITH_KAFKA=false
WITH_MYSQL=false

for arg in "$@"; do
    case "$arg" in
        --kafka) WITH_KAFKA=true ;;
        --mysql) WITH_MYSQL=true ;;
        --all)   WITH_KAFKA=true; WITH_MYSQL=true ;;
        *)
            echo "Usage: $0 [--kafka] [--mysql] [--all]"
            exit 1
            ;;
    esac
done

if [[ "$WITH_KAFKA" == "false" && "$WITH_MYSQL" == "false" ]]; then
    echo "Specify at least one service: --kafka, --mysql, or --all"
    exit 1
fi

# ─── Pre-flight ──────────────────────────────────────────────────────────────
if ! docker info &>/dev/null; then
    echo "[ERROR] Docker is not running. Start Docker Desktop or the Docker daemon."
    exit 1
fi

# ─── Start services ──────────────────────────────────────────────────────────
SERVICES=()
if [[ "$WITH_KAFKA" == "true" ]]; then
    SERVICES+=("zookeeper" "kafka")
fi
if [[ "$WITH_MYSQL" == "true" ]]; then
    SERVICES+=("mysql")
fi

echo "Starting services: ${SERVICES[*]}"
docker compose -f "${COMPOSE_FILE}" up -d "${SERVICES[@]}"

# ─── Wait for healthy ────────────────────────────────────────────────────────
wait_healthy() {
    local container="$1"
    local timeout=120
    local elapsed=0
    echo -n "  Waiting for ${container} to become healthy..."
    while (( elapsed < timeout )); do
        local status
        status=$(docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
        if [[ "${status}" == "healthy" ]]; then
            echo " OK"
            return 0
        fi
        echo -n "."
        sleep 5
        (( elapsed += 5 )) || true
    done
    echo " TIMEOUT"
    echo "[ERROR] ${container} did not become healthy within ${timeout}s"
    docker logs "${container}" --tail 30
    return 1
}

if [[ "$WITH_KAFKA" == "true" ]]; then
    wait_healthy "si-test-zookeeper"
    wait_healthy "si-test-kafka"
fi
if [[ "$WITH_MYSQL" == "true" ]]; then
    wait_healthy "si-test-mysql"
fi

# ─── Kafka post-setup ────────────────────────────────────────────────────────
if [[ "$WITH_KAFKA" == "true" ]]; then
    echo "Creating Kafka test topics..."
    for topic in si-test-input si-test-output; do
        docker exec si-test-kafka \
            kafka-topics --bootstrap-server localhost:9092 \
            --create --topic "${topic}" --partitions 1 --replication-factor 1 \
            --if-not-exists 2>/dev/null && echo "  Topic '${topic}': OK" || true
    done
fi

# ─── MySQL post-setup ────────────────────────────────────────────────────────
if [[ "$WITH_MYSQL" == "true" ]]; then
    echo "Verifying MySQL database..."
    docker exec "${MYSQL_CONTAINER}" \
        mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SHOW DATABASES;" 2>/dev/null | grep -q "${MYSQL_DB}" \
        && echo "  Database '${MYSQL_DB}': OK" \
        || echo "[WARN] Could not verify MySQL database"

    # Check for MySQL JDBC driver in SI_HOME
    if [[ -d "${SI_HOME}/lib" ]]; then
        if ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | head -1 | grep -q '.jar'; then
            echo "  MySQL JDBC driver: found in \${SI_HOME}/lib/"
        else
            echo ""
            echo "  [WARN] MySQL JDBC driver JAR not found in ${SI_HOME}/lib/"
            echo "  TC07 and TC11 will fail without it."
            echo "  Download mysql-connector-j-8.x.x.jar and place it in:"
            echo "    ${SI_HOME}/lib/"
            echo "  Then restart the SI server."
        fi
    fi
fi

echo ""
echo "Infrastructure is ready. You can now:"
echo "  1. Start the SI server: \${SI_HOME}/bin/server.sh"
echo "  2. Deploy test apps:    ./scripts/deploy.sh --core"
echo "  3. Run tests:           ./run_all_tests.sh"
