#!/usr/bin/env bash
# TC34: BackendTrafficPolicy (Envoy rate-limit) is created and targets the HTTPRoute
# Upgrades the Helm release with rateLimit.enabled=true, then validates.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC34"

NS="${K8S_TEST_NAMESPACE}"

# Verify the BackendTrafficPolicy CRD is available (Envoy Gateway-specific)
if ! kubectl get crd backendtrafficpolicies.gateway.envoyproxy.io >/dev/null 2>&1; then
    log_skip "BackendTrafficPolicy CRD not found — Envoy Gateway may not be installed. Skipping TC34."
    print_summary; exit 0
fi
log_info "BackendTrafficPolicy CRD is available"

log_info "Upgrading Helm release with rateLimit.enabled=true (50 req/Minute)..."
helm upgrade "${K8S_RELEASE_NAME}" "${HELM_SI_CHART}" \
    --values "${HELM_SI_CHART}/values_local.yaml" \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set "wso2.gatewayApi.gatewayClassName=${K8S_GATEWAY_CLASS}" \
    --set "wso2.gatewayApi.gateway.name=${K8S_GATEWAY_NAME}" \
    --set "wso2.gatewayApi.gateway.tlsSecret=${K8S_TLS_SECRET}" \
    --set wso2.gatewayApi.backendTLS.enabled=false \
    --set wso2.gatewayApi.rateLimit.enabled=true \
    --set wso2.gatewayApi.rateLimit.requests=50 \
    --set wso2.gatewayApi.rateLimit.unit=Minute \
    --set "wso2.deployment.hostname=${K8S_HOSTNAME}" \
    -n "${NS}" 2>&1

sleep 5

log_info "T1: BackendTrafficPolicy resource exists"
wait_for_k8s_resource "backendtrafficpolicy" "${NS}" "${K8S_RESOURCE_TIMEOUT}"
assert_k8s_resource_exists "T1: BackendTrafficPolicy created" "backendtrafficpolicy" "${NS}"

BTP_NAME=$(kubectl get backendtrafficpolicy -n "${NS}" -o name 2>/dev/null | head -1 | sed 's|.*/||')

log_info "T2: BackendTrafficPolicy uses Envoy Gateway API group"
BTP_API=$(kubectl get backendtrafficpolicy "${BTP_NAME}" -n "${NS}" \
    -o jsonpath='{.apiVersion}' 2>/dev/null)
if echo "${BTP_API}" | grep -q "envoyproxy"; then
    log_pass "T2: apiVersion=${BTP_API}"
else
    log_fail "T2: unexpected apiVersion '${BTP_API}'"
fi

log_info "T3: BackendTrafficPolicy targets the HTTPRoute"
assert_k8s_field "T3: targetRef kind=HTTPRoute" \
    "backendtrafficpolicy/${BTP_NAME}" "{.spec.targetRefs[0].kind}" "HTTPRoute" "${NS}"

log_info "T4: Rate limit type is Local"
assert_k8s_field "T4: rateLimit.type=Local" \
    "backendtrafficpolicy/${BTP_NAME}" "{.spec.rateLimit.type}" "Local" "${NS}"

log_info "T5: Rate limit requests=50"
assert_k8s_field "T5: requests=50" \
    "backendtrafficpolicy/${BTP_NAME}" \
    "{.spec.rateLimit.local.rules[0].limit.requests}" "50" "${NS}"

log_info "T6: Rate limit unit=Minute"
assert_k8s_field "T6: unit=Minute" \
    "backendtrafficpolicy/${BTP_NAME}" \
    "{.spec.rateLimit.local.rules[0].limit.unit}" "Minute" "${NS}"

# Restore to default (rate limit disabled) after the test
log_info "Restoring Helm release to rateLimit.enabled=false..."
helm upgrade "${K8S_RELEASE_NAME}" "${HELM_SI_CHART}" \
    --values "${HELM_SI_CHART}/values_local.yaml" \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set "wso2.gatewayApi.gatewayClassName=${K8S_GATEWAY_CLASS}" \
    --set "wso2.gatewayApi.gateway.name=${K8S_GATEWAY_NAME}" \
    --set "wso2.gatewayApi.gateway.tlsSecret=${K8S_TLS_SECRET}" \
    --set wso2.gatewayApi.backendTLS.enabled=false \
    --set wso2.gatewayApi.rateLimit.enabled=false \
    --set "wso2.deployment.hostname=${K8S_HOSTNAME}" \
    -n "${NS}" >/dev/null 2>&1

print_summary; tc_exit_code
