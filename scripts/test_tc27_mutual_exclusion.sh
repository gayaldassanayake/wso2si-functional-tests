#!/usr/bin/env bash
# TC27: Mutual exclusion — enabling both ingress and Gateway API suppresses Ingress
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC27"

log_info "T1: When both ingress.enabled=true and gatewayApi.enabled=true, Ingress is suppressed"
YAML=$(helm_template \
    --set wso2.ingress.enabled=true \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.tlsSecret=si-tls \
    --set wso2.config.admin.password=YWRtaW4=)
assert_yaml_not_contains "T1: Ingress suppressed when gatewayApi enabled" "${YAML}" "^kind: Ingress$"
assert_yaml_contains "T1: Gateway renders" "${YAML}" "^kind: Gateway$"
assert_yaml_contains "T1: HTTPRoute renders" "${YAML}" "^kind: HTTPRoute$"

log_info "T2: Only Ingress renders when gatewayApi.enabled=false and ingress.enabled=true"
YAML=$(helm_template \
    --set wso2.ingress.enabled=true \
    --set wso2.gatewayApi.enabled=false \
    --set wso2.config.admin.password=YWRtaW4=)
assert_yaml_contains "T2: Ingress renders" "${YAML}" "^kind: Ingress$"
assert_yaml_not_contains "T2: Gateway absent" "${YAML}" "^kind: Gateway$"
assert_yaml_not_contains "T2: HTTPRoute absent" "${YAML}" "^kind: HTTPRoute$"

log_info "T3: No traffic routing resources when both disabled"
YAML=$(helm_template \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=false \
    --set wso2.config.admin.password=YWRtaW4=)
assert_yaml_not_contains "T3: Ingress absent" "${YAML}" "^kind: Ingress$"
assert_yaml_not_contains "T3: Gateway absent" "${YAML}" "^kind: Gateway$"
assert_yaml_not_contains "T3: HTTPRoute absent" "${YAML}" "^kind: HTTPRoute$"

print_summary; tc_exit_code
