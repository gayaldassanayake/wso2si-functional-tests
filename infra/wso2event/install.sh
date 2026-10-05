#!/usr/bin/env bash
# Installs the siddhi-io-wso2event and siddhi-map-wso2event bundles TC43 needs into ${SI_HOME}/lib
# (and _lib, which SI copies back over lib on startup). Restart SI afterwards.
# The jars are the Maven Central releases: siddhi-io-wso2event 5.0.2, siddhi-map-wso2event 5.0.3.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${SI_HOME:?SI_HOME must point to the SI pack}"
for dir in "${SI_HOME}/lib" "${SI_HOME}/_lib"; do
    [[ -d "${dir}" ]] || continue
    cp "${DIR}"/siddhi-io-wso2event-*.jar "${DIR}"/siddhi-map-wso2event-*.jar "${dir}/"
    echo "Installed wso2event extensions into ${dir}"
done
