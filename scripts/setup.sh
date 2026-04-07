#!/usr/bin/env bash
# setup.sh — start Docker Compose infrastructure services for SI test suite
#
# Usage:
#   ./scripts/setup.sh --kafka          # Start Kafka + Zookeeper only
#   ./scripts/setup.sh --mysql          # Start MySQL only
#   ./scripts/setup.sh --all            # Start all services
#
# This script also automatically downloads and installs required SI-side JARs
# (MySQL JDBC driver, Kafka client OSGi bundles) into ${SI_HOME}/lib/ when they
# are not already present.  If new JARs are installed, the script will ask you
# to restart the SI server before running the test suite.

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
        local hstatus
        hstatus=$(docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
        if [[ "${hstatus}" == "healthy" ]]; then
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
fi

# ─── JAR installation helpers ────────────────────────────────────────────────
# Returns 0 if SI_HOME/lib exists and is writable; prints error and returns 1 otherwise.
_check_si_lib() {
    if [[ ! -d "${SI_HOME}/lib" ]]; then
        echo "  [WARN] ${SI_HOME}/lib not found — is SI_HOME set correctly? Skipping JAR install."
        return 1
    fi
}

# Download the MySQL JDBC driver into ${SI_HOME}/lib/ if not already present.
# mysql-connector-j ships with an OSGi manifest so jartobundle is not needed.
install_mysql_jdbc() {
    _check_si_lib || return 1

    if ls "${SI_HOME}/lib/mysql-connector"*.jar 2>/dev/null | grep -q .; then
        echo "  MySQL JDBC driver: already present in \${SI_HOME}/lib/"
        return 0
    fi

    local version="8.2.0"
    local jar="mysql-connector-j-${version}.jar"
    local url="https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${version}/${jar}"

    echo "  Downloading MySQL JDBC driver ${version}..."
    if curl -fsSL -o "${SI_HOME}/lib/${jar}" "${url}"; then
        echo "  Installed: ${SI_HOME}/lib/${jar}"
        JARS_INSTALLED=true
    else
        rm -f "${SI_HOME}/lib/${jar}"
        echo "  [WARN] Download failed. Manually place mysql-connector-j-*.jar in ${SI_HOME}/lib/"
        return 1
    fi
}

# Find a JAVA_HOME whose JDK version is in the range supported by jartobundle.sh
# (1.8 – 17).  Checks the active JAVA_HOME first, then common sdkman / macOS
# system locations.  Echoes the path or returns 1 if nothing suitable is found.
_find_jartobundle_java() {
    _java_major_version() {
        local java_bin="$1"
        "${java_bin}" -version 2>&1 | awk -F'"' '/version/ {
            v=$2; split(v,a,"."); print (a[1]=="1" ? a[2] : a[1])
        }'
    }

    _is_compatible() {
        local v="$1"
        [[ -n "${v}" ]] && [[ "${v}" -ge 8 ]] && [[ "${v}" -le 17 ]]
    }

    # 1. Current JAVA_HOME
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        local v
        v=$(_java_major_version "${JAVA_HOME}/bin/java")
        if _is_compatible "${v}"; then
            echo "${JAVA_HOME}"
            return 0
        fi
    fi

    # 2. sdkman candidates (prefer 17, then 11, then 8)
    for pat in ~/.sdkman/candidates/java/17* \
               ~/.sdkman/candidates/java/11* \
               ~/.sdkman/candidates/java/8*; do
        for candidate in ${pat}; do
            [[ -x "${candidate}/bin/java" ]] || continue
            local v
            v=$(_java_major_version "${candidate}/bin/java")
            if _is_compatible "${v}"; then
                echo "${candidate}"
                return 0
            fi
        done
    done

    # 3. macOS system JVMs
    for jvm_home in /Library/Java/JavaVirtualMachines/*/Contents/Home; do
        [[ -x "${jvm_home}/bin/java" ]] || continue
        local v
        v=$(_java_major_version "${jvm_home}/bin/java")
        if _is_compatible "${v}"; then
            echo "${jvm_home}"
            return 0
        fi
    done

    return 1
}

# Download kafka-clients and key runtime dependencies, convert each to an OSGi
# bundle with jartobundle.sh, and copy the result into ${SI_HOME}/lib/.
# siddhi-io-kafka is already bundled in SI; only the Kafka client JARs are needed.
install_kafka_jars() {
    _check_si_lib || return 1

    if ls "${SI_HOME}/lib/"*kafka*clients*.jar 2>/dev/null | grep -q . ||
       ls "${SI_HOME}/lib/"*kafka_2.*.jar      2>/dev/null | grep -q .; then
        echo "  Kafka client JARs: already present in \${SI_HOME}/lib/"
        return 0
    fi

    local jbundle_java
    if ! jbundle_java=$(_find_jartobundle_java); then
        echo "  [WARN] No JDK 8/11/17 found — jartobundle.sh requires JDK ≤ 17."
        echo "         Install JDK 17 (e.g. via sdkman: sdk install java 17-tem) and re-run setup.sh."
        return 1
    fi
    echo "  Using JDK for jartobundle: ${jbundle_java}"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    local download_urls
    download_urls=(
        "https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/3.5.1/kafka-clients-3.5.1.jar"
        "https://repo1.maven.org/maven2/org/lz4/lz4-java/1.8.0/lz4-java-1.8.0.jar"
        "https://repo1.maven.org/maven2/org/xerial/snappy/snappy-java/1.1.10.1/snappy-java-1.1.10.1.jar"
    )

    local any_failed=false
    for url in "${download_urls[@]}"; do
        local fname
        fname=$(basename "${url}")
        echo "  Downloading ${fname}..."
        if ! curl -fsSL -o "${tmpdir}/${fname}" "${url}"; then
            echo "  [WARN] Failed to download ${fname}"
            any_failed=true
            continue
        fi

        local bundledir="${tmpdir}/bundle"
        rm -rf "${bundledir}"
        mkdir -p "${bundledir}"

        echo "  Converting ${fname} to OSGi bundle..."
        CARBON_HOME="${SI_HOME}" JAVA_HOME="${jbundle_java}" \
            bash "${SI_HOME}/bin/jartobundle.sh" "${tmpdir}/${fname}" "${bundledir}" \
            >/dev/null 2>&1 || true

        local installed=false
        for bjar in "${bundledir}"/*.jar; do
            [[ -f "${bjar}" ]] || continue
            cp "${bjar}" "${SI_HOME}/lib/"
            echo "  Installed OSGi bundle: $(basename "${bjar}")"
            installed=true
            JARS_INSTALLED=true
        done

        if [[ "${installed}" == "false" ]]; then
            # lz4-java and snappy-java already carry OSGi headers; copy as-is.
            echo "  [WARN] jartobundle produced no output for ${fname} — copying original JAR"
            cp "${tmpdir}/${fname}" "${SI_HOME}/lib/"
            echo "  Installed (non-bundled): ${fname}"
            JARS_INSTALLED=true
        fi
    done

    [[ "${any_failed}" == "false" ]]
}

# ─── Install SI-side JARs ────────────────────────────────────────────────────
JARS_INSTALLED=false

if [[ "$WITH_KAFKA" == "true" ]]; then
    echo "Installing Kafka client OSGi bundles..."
    install_kafka_jars || true
fi

if [[ "$WITH_MYSQL" == "true" ]]; then
    echo "Installing MySQL JDBC driver..."
    install_mysql_jdbc || true
fi

# ─── Final message ───────────────────────────────────────────────────────────
echo ""
if [[ "${JARS_INSTALLED}" == "true" ]]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "  New JARs were installed in ${SI_HOME}/lib/"
    echo ""
    echo "  Restart the SI server, then re-run:"
    echo "    SI_HOME=${SI_HOME} ./run_all_tests.sh --all"
    echo "════════════════════════════════════════════════════════════════"
else
    echo "Infrastructure is ready. You can now:"
    echo "  1. Start the SI server: \${SI_HOME}/bin/server.sh"
    echo "  2. Run tests:           SI_HOME=${SI_HOME} ./run_all_tests.sh --all"
fi
