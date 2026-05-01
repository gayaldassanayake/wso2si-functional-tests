#!/usr/bin/env bash
# TC23: Backward compatibility — old values file without gatewayApi key
#       Simulated by overriding values to strip gatewayApi section
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC23"

# Simulate an old values.yaml that only sets ingress (no gatewayApi key at all).
# We use an inline values file that mirrors what an SI 4.2.0 user would have.
OLD_VALUES_FILE=$(mktemp /tmp/tc23-old-values.XXXXXX.yaml)
trap 'rm -f "${OLD_VALUES_FILE}"' EXIT

cat > "${OLD_VALUES_FILE}" <<'EOF'
wso2:
  ingress:
    enabled: true
    ingressClassName: "nginx"
    annotations:
    tlsSecret: ""
    backendProtocol: "AUTO_HTTP"
    sslRedirect: "false"
    ratelimit:
      enabled: false
      zoneName: ""
      burstLimit: ""
  config:
    admin:
      username: "admin"
      password: "YWRtaW4="
    secureVault:
      enabled: false
    keyStore:
      primary:
        fileName: "wso2carbon.jks"
        alias: "wso2carbon"
        password: ""
        keyPassword: ""
      secureVault:
        fileName: "securevault.jks"
        alias: "wso2carbon"
        password: ""
        keyPassword: ""
    trustStore:
      primary:
        fileName: "client-truststore.jks"
        password: ""
    queryApi:
      listenerConfigurations:
        default: 7070
        msf4jHttps: 7444
        keyStorePassword: wso2carbon
        certPass: wso2carbon
        keyStoreFile: "${carbon.home}/resources/security/wso2carbon.jks"
    transport:
      http:
        default: 9090
        msf4jHttps: 9443
        keyStoreFile: "${carbon.home}/resources/security/wso2carbon.jks"
        keyStorePassword: wso2carbon
        certPass: wso2carbon
    databridge:
      keyStoreLocation: ${sys:carbon.home}/resources/security/wso2carbon.jks
      keyStorePassword: wso2carbon
      thrift:
        tcpPort: 7611
        sslPort: 7711
      binary:
        tcpPort: 9611
        sslPort: 9711
    dataAgent:
      thrift:
        trustStorePath: '${sys:carbon.home}/resources/security/client-truststore.jks'
        trustStorePassword: 'wso2carbon'
      binary:
        trustStorePath: '${sys:carbon.home}/resources/security/client-truststore.jks'
        trustStorePassword: 'wso2carbon'
    metrics:
      enabled: false
    datasources:
      clusterDB:
        username: wso2carbon
        password: wso2carbon
      permissionsDB:
        username: wso2carbon
        password: wso2carbon
      metricsDB:
        username: wso2carbon
        password: wso2carbon
    serviceCatalog:
      enabled: false
      username: admin
      password: admin
  deployment:
    securityContext:
      apparmor: true
      seccompProfile: true
      runAsUser: ""
    hostname: "si.wso2.com"
    BuildVersion: "4.3.0"
    JKSSecretName: ""
    imagePullSecrets: ""
    image:
      containerRegistry: "docker.io"
      repository: "wso2/wso2si"
      digest: ""
      tag: "4.3.0-ubuntu"
      pullPolicy: IfNotPresent
    replicas: 1
    strategy:
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
    resources:
      requests:
        memory: "512Mi"
        cpu: "500m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
      jvm:
        memory:
          xms: "512m"
          xmx: "1024m"
    envs:
    mountSiddhiApps: false
    probes:
      livenessProbe:
        initialDelaySeconds: 60
        periodSeconds: 10
      readinessProbe:
        initialDelaySeconds: 60
        periodSeconds: 10
EOF

log_info "T1: helm template succeeds with old values.yaml (no gatewayApi key)"
YAML=$(helm template si-test "${HELM_SI_CHART}" --values "${OLD_VALUES_FILE}" 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    log_pass "T1: helm template succeeds with pre-gatewayApi values file"
else
    log_fail "T1: helm template failed — backward compat broken. Output: ${YAML}"
fi

log_info "T2: Ingress renders with old values"
assert_yaml_contains "T2: Ingress renders" "${YAML}" "^kind: Ingress$"

log_info "T3: No Gateway API resources render with old values"
assert_yaml_not_contains "T3: no Gateway resource" "${YAML}" "^kind: Gateway$"
assert_yaml_not_contains "T3: no HTTPRoute resource" "${YAML}" "^kind: HTTPRoute$"

print_summary; tc_exit_code
