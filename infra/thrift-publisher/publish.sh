#!/usr/bin/env bash
# Publishes events to an SI Thrift receiver from a separate JVM, using the databridge agent and
# libthrift of the pack in CLIENT_HOME (defaults to SI_HOME). Point CLIENT_HOME at an older pack,
# such as SI 1.1.0, to test an older client against the server under test. CLIENT_LIBTHRIFT
# picks a specific libthrift jar when the client pack has more than one.
#
# Usage: publish.sh <dataUrl> <authUrl> <streamId> <transport> <count>
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${SI_HOME:?SI_HOME must point to the SI pack}"
CLIENT_HOME="${CLIENT_HOME:-${SI_HOME}}"
PLUGINS="${CLIENT_HOME}/wso2/lib/plugins"

# Newest jar matching any of the space-separated name patterns, compared on the version after the last '_'.
newest() {
    local p patterns
    read -r -a patterns <<< "$1"
    for p in "${patterns[@]}"; do ls -1 "${PLUGINS}"/${p}.jar 2>/dev/null || true; done \
        | awk -F_ '{print $NF "\t" $0}' | sort -V | tail -1 | cut -f2
}

libthrift="${CLIENT_LIBTHRIFT:-$(newest 'libthrift_*')}"
[[ -f "${libthrift}" ]] || { echo "No libthrift jar in ${PLUGINS}" >&2; exit 1; }
cp="${libthrift}:"
for pattern in 'org.wso2.carbon.databridge.agent_*' 'org.wso2.carbon.databridge.commons_*' \
        'org.wso2.carbon.databridge.commons.thrift_*' 'org.wso2.carbon.databridge.commons.binary_*' \
        'org.wso2.carbon.config_*' 'org.wso2.carbon.secvault_*' 'org.wso2.carbon.utils_*' \
        'org.yaml.snakeyaml_* snakeyaml_*' 'com.google.gson_*' 'disruptor_*' 'commons-pool_*' 'json_*' \
        'org.ops4j.pax.logging.pax-logging-api_*' 'org.eclipse.osgi_*' 'org.eclipse.osgi.services_*'; do
    jar=$(newest "${pattern}")
    [[ -n "${jar}" ]] || { echo "No ${pattern}.jar in ${PLUGINS}" >&2; exit 1; }
    cp+="${jar}:"
done
for pattern in 'commons-io_*' 'commons-lang3_*' 'org.wso2.orbit.javax.xml.bind.jaxb-api_*' \
        'org.wso2.orbit.sun.xml.bind.jaxb_*'; do
    jar=$(newest "${pattern}")
    [[ -n "${jar}" ]] && cp+="${jar}:"
done

OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT
javac --release 11 -nowarn -d "${OUT}" -cp "${cp}" "${DIR}"/src/org/wso2/si/test/thrift/ThriftPublisher.java

echo "Client: $(basename "$(newest 'org.wso2.carbon.databridge.agent_*')"), $(basename "${libthrift}")"
java -Dcarbon.home="${CLIENT_HOME}" -Dwso2.runtime=server \
     -Djavax.net.ssl.trustStore="${CLIENT_HOME}/resources/security/client-truststore.jks" \
     -Djavax.net.ssl.trustStorePassword=wso2carbon \
     -cp "${OUT}:${cp}" org.wso2.si.test.thrift.ThriftPublisher \
     "${CLIENT_HOME}/conf/server/deployment.yaml" "$1" "$2" admin admin "$3" "$4" "$5"
