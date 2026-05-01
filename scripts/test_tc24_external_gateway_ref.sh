#!/usr/bin/env bash
# TC24: External Gateway reference — gateway.create=false, HTTPRoute points to external namespace
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC24"

YAML=$(helm_template \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.create=false \
    --set wso2.gatewayApi.gateway.name=shared-gateway \
    --set wso2.gatewayApi.gateway.namespace=infra \
    --set wso2.gatewayApi.gateway.listenerName=https \
    --set wso2.config.admin.password=YWRtaW4=)

log_info "T1: No Gateway resource rendered when gateway.create=false"
assert_yaml_not_contains "T1: Gateway resource absent" "${YAML}" "^kind: Gateway$"

log_info "T2: HTTPRoute is rendered"
assert_yaml_contains "T2: HTTPRoute present" "${YAML}" "^kind: HTTPRoute$"

log_info "T3: HTTPRoute parentRef uses external gateway name"
assert_yaml_contains "T3: parentRef name=shared-gateway" "${YAML}" 'name:.*shared-gateway'

log_info "T4: HTTPRoute parentRef uses external gateway namespace"
assert_yaml_contains "T4: parentRef namespace=infra" "${YAML}" 'namespace:.*infra'

log_info "T5: HTTPRoute parentRef sectionName matches configured listener"
assert_yaml_contains "T5: parentRef sectionName=https" "${YAML}" 'sectionName:.*https'

log_info "T6: Ingress is not rendered"
assert_yaml_not_contains "T6: Ingress absent" "${YAML}" "^kind: Ingress$"

print_summary; tc_exit_code
