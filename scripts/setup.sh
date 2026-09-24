#!/usr/bin/env bash
# setup.sh — start Docker Compose infrastructure services for SI test suite
#
# Usage:
#   ./scripts/setup.sh --kafka          # Start Kafka + Zookeeper only
#   ./scripts/setup.sh --mysql          # Start MySQL only
#   ./scripts/setup.sh --rabbitmq       # Start RabbitMQ only
#   ./scripts/setup.sh --redis          # Start Redis only
#   ./scripts/setup.sh --oracle-ldap    # Start Oracle + OpenLDAP (TC52, not part of --all)
#   ./scripts/setup.sh --all            # Start all services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SUITE_ROOT}/config.env"

COMPOSE_FILE="${SUITE_ROOT}/infra/docker-compose.yml"

WITH_KAFKA=false
WITH_MYSQL=false
WITH_RABBITMQ=false
WITH_REDIS=false
WITH_POSTGRES=false
WITH_ORACLE_LDAP=false

for arg in "$@"; do
    case "$arg" in
        --kafka)    WITH_KAFKA=true ;;
        --mysql)    WITH_MYSQL=true ;;
        --rabbitmq) WITH_RABBITMQ=true ;;
        --redis)    WITH_REDIS=true ;;
        --postgres) WITH_POSTGRES=true ;;
        --oracle-ldap) WITH_ORACLE_LDAP=true ;;
        --all)      WITH_KAFKA=true; WITH_MYSQL=true; WITH_RABBITMQ=true; WITH_REDIS=true; WITH_POSTGRES=true ;;
        *)
            echo "Usage: $0 [--kafka] [--mysql] [--rabbitmq] [--redis] [--postgres] [--oracle-ldap] [--all]"
            exit 1
            ;;
    esac
done

if [[ "$WITH_KAFKA" == "false" && "$WITH_MYSQL" == "false" && "$WITH_RABBITMQ" == "false" && "$WITH_REDIS" == "false" && "$WITH_POSTGRES" == "false" && "$WITH_ORACLE_LDAP" == "false" ]]; then
    echo "Specify at least one service: --kafka, --mysql, --rabbitmq, --redis, --postgres, or --all"
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
if [[ "$WITH_RABBITMQ" == "true" ]]; then
    SERVICES+=("rabbitmq")
fi
if [[ "$WITH_REDIS" == "true" ]]; then
    SERVICES+=("redis")
fi
if [[ "$WITH_POSTGRES" == "true" ]]; then
    SERVICES+=("postgres")
fi
if [[ "$WITH_ORACLE_LDAP" == "true" ]]; then
    SERVICES+=("oracle" "openldap")
fi

echo "Starting services: ${SERVICES[*]}"
docker compose -f "${COMPOSE_FILE}" --profile oracle up -d --force-recreate "${SERVICES[@]}"

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
if [[ "$WITH_RABBITMQ" == "true" ]]; then
    wait_healthy "si-test-rabbitmq"
fi
if [[ "$WITH_REDIS" == "true" ]]; then
    wait_healthy "si-test-redis"
fi
if [[ "$WITH_POSTGRES" == "true" ]]; then
    wait_healthy "si-test-postgres"
fi
if [[ "$WITH_ORACLE_LDAP" == "true" ]]; then
    wait_healthy "${ORACLE_CONTAINER}"
    echo -n "  Waiting for ${LDAP_CONTAINER} to accept connections..."
    until docker exec "${LDAP_CONTAINER}" ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base dn &>/dev/null; do
        echo -n "."; sleep 2
    done
    echo " OK"
    # The Oracle driver reads net-service entries anonymously, like a typical OID setup.
    docker exec -i "${LDAP_CONTAINER}" ldapmodify -Q -Y EXTERNAL -H ldapi:/// \
        < "${SUITE_ROOT}/infra/ldap-init/oracle-context-acl.ldif" || true
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

# ─── RabbitMQ post-setup ─────────────────────────────────────────────────────
if [[ "$WITH_RABBITMQ" == "true" ]]; then
    echo "Declaring RabbitMQ topology..."
    bash "${SUITE_ROOT}/infra/rabbitmq-init/declare.sh" "${RABBITMQ_CONTAINER}"
fi

# ─── Redis post-setup ────────────────────────────────────────────────────────
if [[ "$WITH_REDIS" == "true" ]]; then
    echo "Verifying Redis..."
    docker exec "${REDIS_CONTAINER}" redis-cli ping 2>/dev/null | grep -q PONG \
        && echo "  Redis: PONG received" \
        || echo "[WARN] Redis ping failed"
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

# ─── PostgreSQL post-setup ───────────────────────────────────────────────────
if [[ "$WITH_POSTGRES" == "true" ]]; then
    echo "Verifying PostgreSQL database..."
    docker exec "${POSTGRES_CONTAINER}" \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SELECT 1;" 2>/dev/null | grep -q 1 \
        && echo "  Database '${POSTGRES_DB}': OK" \
        || echo "[WARN] Could not verify PostgreSQL database"

    wal=$(docker exec "${POSTGRES_CONTAINER}" \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SHOW wal_level;" 2>/dev/null | tr -d '[:space:]')
    if [[ "${wal}" == "logical" ]]; then
        echo "  wal_level: logical (CDC listening supported)"
    else
        echo "  [WARN] wal_level is '${wal}', expected 'logical'. TC48 cannot stream."
    fi

    if [[ -d "${SI_HOME}/lib" ]]; then
        pgjar=$(ls "${SI_HOME}/lib/postgresql-"*.jar 2>/dev/null | head -1)
        if [[ -n "${pgjar}" ]]; then
            pgver=$(unzip -p "${pgjar}" META-INF/MANIFEST.MF 2>/dev/null \
                    | tr -d '\r' | awk -F': ' '/^Implementation-Version:/{print $2; exit}')
            echo "  PostgreSQL JDBC driver: ${pgver:-unknown} found in \${SI_HOME}/lib/"
            if ! unzip -p "${pgjar}" org/postgresql/replication/fluent/ChainedCommonStreamBuilder.class 2>/dev/null \
                 | LC_ALL=C grep -aq 'withAutomaticFlush'; then
                echo "  [WARN] pgjdbc ${pgver:-unknown} predates ${PGJDBC_MIN_VERSION}; TC48 (CDC listening) will fail."
            fi
        else
            echo ""
            echo "  [WARN] PostgreSQL JDBC driver JAR not found in ${SI_HOME}/lib/"
            echo "  TC48 and TC49 will skip without it."
            echo "  Download postgresql-${PGJDBC_MIN_VERSION}.jar (or newer) and place it in:"
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
