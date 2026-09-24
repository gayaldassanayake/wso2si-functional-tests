#!/usr/bin/env bash
# Builds ldapctx-1.0.0.jar and installs it into ${SI_HOME}/lib (restart SI afterwards).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${SI_HOME:?SI_HOME must point to the SI pack}"
OSGI_JAR=$(ls "${SI_HOME}"/wso2/lib/plugins/org.eclipse.osgi_*.jar | head -1)
OUT=$(mktemp -d)
javac --release 11 -d "${OUT}/classes" -cp "${OSGI_JAR}" "${DIR}"/src/org/wso2/si/test/ldapctx/Activator.java
jar cfm "${SI_HOME}/lib/ldapctx-1.0.0.jar" "${DIR}/MANIFEST.MF" -C "${OUT}/classes" .
rm -rf "${OUT}"
echo "Installed ${SI_HOME}/lib/ldapctx-1.0.0.jar"
