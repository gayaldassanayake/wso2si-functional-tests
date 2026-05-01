#!/usr/bin/env bash
# TC25: BackendTLSPolicy — content and targeting correctness
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC25"

BASE_SETS=(
    --set wso2.ingress.enabled=false
    --set wso2.gatewayApi.enabled=true
    --set wso2.gatewayApi.gateway.tlsSecret=si-tls
    --set wso2.config.admin.password=YWRtaW4=
)

log_info "T1: BackendTLSPolicy is absent when backendTLS.enabled=false (default)"
YAML=$(helm_template "${BASE_SETS[@]}")
assert_yaml_not_contains "T1: BackendTLSPolicy absent by default" "${YAML}" "^kind: BackendTLSPolicy$"

log_info "T2: BackendTLSPolicy renders when backendTLS.enabled=true"
YAML=$(helm_template "${BASE_SETS[@]}" --set wso2.gatewayApi.backendTLS.enabled=true)
assert_yaml_contains "T2: BackendTLSPolicy present" "${YAML}" "^kind: BackendTLSPolicy$"

log_info "T3: BackendTLSPolicy uses gateway.networking.k8s.io/v1alpha3 API"
assert_yaml_contains "T3: correct apiVersion" "${YAML}" "gateway.networking.k8s.io/v1alpha3"

log_info "T4: BackendTLSPolicy targets the headless service"
assert_yaml_contains "T4: targetRef kind=Service" "${YAML}" "kind: Service"
assert_yaml_contains "T4: targetRef name contains -headless" "${YAML}" ".*-headless"

log_info "T5: BackendTLSPolicy targets sectionName=management (port 9443)"
assert_yaml_contains "T5: sectionName=management" "${YAML}" "sectionName: management"

log_info "T6: Default validation uses system CAs when no caCertRefs provided"
assert_yaml_contains "T6: wellKnownCACertificates=System" "${YAML}" "wellKnownCACertificates: System"

log_info "T7: Custom caCertRefs replaces wellKnownCACertificates"
YAML=$(helm_template "${BASE_SETS[@]}" \
    --set wso2.gatewayApi.backendTLS.enabled=true \
    --set "wso2.gatewayApi.backendTLS.caCertRefs[0].name=my-ca" \
    --set "wso2.gatewayApi.backendTLS.caCertRefs[0].kind=ConfigMap" \
    --set "wso2.gatewayApi.backendTLS.caCertRefs[0].group=")
assert_yaml_contains "T7: caCertificateRefs block present" "${YAML}" "caCertificateRefs"
assert_yaml_not_contains "T7: wellKnownCACertificates absent" "${YAML}" "wellKnownCACertificates"

log_info "T8: Custom backendTLS.hostname overrides default FQDN"
YAML=$(helm_template "${BASE_SETS[@]}" \
    --set wso2.gatewayApi.backendTLS.enabled=true \
    --set wso2.gatewayApi.backendTLS.hostname=custom.backend.local)
assert_yaml_contains "T8: custom hostname in validation" "${YAML}" 'hostname:.*custom\.backend\.local'

print_summary; tc_exit_code
