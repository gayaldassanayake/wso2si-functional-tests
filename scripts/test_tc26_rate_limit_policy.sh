#!/usr/bin/env bash
# TC26: BackendTrafficPolicy (rate limiting) — content correctness and Envoy specificity
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC26"

BASE_SETS=(
    --set wso2.ingress.enabled=false
    --set wso2.gatewayApi.enabled=true
    --set wso2.gatewayApi.gateway.tlsSecret=si-tls
    --set wso2.config.admin.password=YWRtaW4=
)

log_info "T1: BackendTrafficPolicy absent when rateLimit.enabled=false (default)"
YAML=$(helm_template "${BASE_SETS[@]}")
assert_yaml_not_contains "T1: BackendTrafficPolicy absent by default" "${YAML}" "^kind: BackendTrafficPolicy$"

log_info "T2: BackendTrafficPolicy renders when rateLimit.enabled=true"
YAML=$(helm_template "${BASE_SETS[@]}" \
    --set wso2.gatewayApi.rateLimit.enabled=true \
    --set wso2.gatewayApi.rateLimit.requests=50 \
    --set wso2.gatewayApi.rateLimit.unit=Minute)
assert_yaml_contains "T2: BackendTrafficPolicy present" "${YAML}" "^kind: BackendTrafficPolicy$"

log_info "T3: BackendTrafficPolicy uses Envoy Gateway-specific API group"
assert_yaml_contains "T3: Envoy apiVersion" "${YAML}" "gateway.envoyproxy.io/v1alpha1"

log_info "T4: BackendTrafficPolicy targets the HTTPRoute"
assert_yaml_contains "T4: targetRef kind=HTTPRoute" "${YAML}" "kind: HTTPRoute"

log_info "T5: Rate limit type is Local"
assert_yaml_contains "T5: rateLimit type=Local" "${YAML}" "type: Local"

log_info "T6: Configured request count is present"
assert_yaml_contains "T6: requests=50" "${YAML}" "requests: 50"

log_info "T7: Configured unit is present"
assert_yaml_contains "T7: unit=Minute" "${YAML}" "unit: Minute"

log_info "T8: Default rate limit values (100 req/Second) render when not overridden"
YAML=$(helm_template "${BASE_SETS[@]}" --set wso2.gatewayApi.rateLimit.enabled=true)
assert_yaml_contains "T8: default requests=100" "${YAML}" "requests: 100"
assert_yaml_contains "T8: default unit=Second" "${YAML}" "unit: Second"

print_summary; tc_exit_code
