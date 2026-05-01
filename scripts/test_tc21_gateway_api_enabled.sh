#!/usr/bin/env bash
# TC21: Gateway API enabled — correct resources render, Ingress suppressed
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC21"

YAML=$(helm_template \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.tlsSecret=si-tls \
    --set wso2.deployment.hostname=si.wso2.com \
    --set wso2.config.admin.password=YWRtaW4=)

log_info "T1: Gateway resource is rendered"
assert_yaml_contains "T1: kind Gateway present" "${YAML}" "^kind: Gateway$"

log_info "T2: Gateway uses configured GatewayClass"
assert_yaml_contains "T2: gatewayClassName=eg" "${YAML}" 'gatewayClassName:.*eg'

log_info "T3: Gateway listener is HTTPS on port 443"
assert_yaml_contains "T3: listener protocol HTTPS" "${YAML}" "protocol: HTTPS"
assert_yaml_contains "T3: listener port 443" "${YAML}" "port: 443"

log_info "T4: Gateway TLS cert references the configured secret"
assert_yaml_contains "T4: certificateRef name=si-tls" "${YAML}" 'name:.*si-tls'

log_info "T5: Gateway allowedRoutes restricted to Same namespace"
assert_yaml_contains "T5: allowedRoutes.from=Same" "${YAML}" "from: Same"

log_info "T6: HTTPRoute is rendered"
assert_yaml_contains "T6: kind HTTPRoute present" "${YAML}" "^kind: HTTPRoute$"

log_info "T7: HTTPRoute hostname matches deployment hostname"
assert_yaml_contains "T7: HTTPRoute hostname=si.wso2.com" "${YAML}" "si.wso2.com"

log_info "T8: HTTPRoute routes /siddhi-apps path"
assert_yaml_contains "T8: HTTPRoute path=/siddhi-apps" "${YAML}" "value: /siddhi-apps"

log_info "T9: HTTPRoute backend targets headless service"
assert_yaml_contains "T9: backendRef to headless service" "${YAML}" ".*-headless"

log_info "T10: Ingress is NOT rendered when Gateway API is enabled"
assert_yaml_not_contains "T10: kind Ingress absent" "${YAML}" "^kind: Ingress$"

log_info "T11: BackendTLSPolicy absent (disabled by default)"
assert_yaml_not_contains "T11: BackendTLSPolicy absent" "${YAML}" "^kind: BackendTLSPolicy$"

log_info "T12: BackendTrafficPolicy absent (disabled by default)"
assert_yaml_not_contains "T12: BackendTrafficPolicy absent" "${YAML}" "^kind: BackendTrafficPolicy$"

print_summary; tc_exit_code
