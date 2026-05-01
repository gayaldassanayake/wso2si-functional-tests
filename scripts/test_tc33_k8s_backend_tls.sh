#!/usr/bin/env bash
# TC33: BackendTLSPolicy is created and targets the correct service port
# Upgrades the Helm release with backendTLS.enabled=true, then validates.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC33"

NS="${K8S_TEST_NAMESPACE}"

# Verify the BackendTLSPolicy CRD is available (requires Gateway API v1.3+)
if ! kubectl get crd backendtlspolicies.gateway.networking.k8s.io >/dev/null 2>&1; then
    log_skip "BackendTLSPolicy CRD not installed (requires Gateway API v1.3+) — skipping TC33"
    print_summary; exit 0
fi
log_info "BackendTLSPolicy CRD is available"

log_info "Upgrading Helm release with backendTLS.enabled=true..."
helm upgrade "${K8S_RELEASE_NAME}" "${HELM_SI_CHART}" \
    --values "${HELM_SI_CHART}/values_local.yaml" \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set "wso2.gatewayApi.gatewayClassName=${K8S_GATEWAY_CLASS}" \
    --set "wso2.gatewayApi.gateway.name=${K8S_GATEWAY_NAME}" \
    --set "wso2.gatewayApi.gateway.tlsSecret=${K8S_TLS_SECRET}" \
    --set wso2.gatewayApi.backendTLS.enabled=true \
    --set wso2.gatewayApi.rateLimit.enabled=false \
    --set "wso2.deployment.hostname=${K8S_HOSTNAME}" \
    -n "${NS}" 2>&1

sleep 5  # allow Kubernetes to process the new resources

log_info "T1: BackendTLSPolicy resource exists"
wait_for_k8s_resource "backendtlspolicy" "${NS}" "${K8S_RESOURCE_TIMEOUT}"
assert_k8s_resource_exists "T1: BackendTLSPolicy created" "backendtlspolicy" "${NS}"

BTLS_NAME=$(kubectl get backendtlspolicy -n "${NS}" -o name 2>/dev/null | head -1 | sed 's|.*/||')

log_info "T2: BackendTLSPolicy uses gateway.networking.k8s.io/v1alpha3"
BTLS_API=$(kubectl get backendtlspolicy "${BTLS_NAME}" -n "${NS}" \
    -o jsonpath='{.apiVersion}' 2>/dev/null)
if echo "${BTLS_API}" | grep -q "v1alpha3"; then
    log_pass "T2: apiVersion=${BTLS_API}"
else
    log_fail "T2: unexpected apiVersion '${BTLS_API}'"
fi

log_info "T3: BackendTLSPolicy targets the headless Service"
TARGET_KIND=$(kubectl get backendtlspolicy "${BTLS_NAME}" -n "${NS}" \
    -o jsonpath='{.spec.targetRefs[0].kind}' 2>/dev/null)
assert_k8s_field "T3: targetRef kind=Service" \
    "backendtlspolicy/${BTLS_NAME}" "{.spec.targetRefs[0].kind}" "Service" "${NS}"

log_info "T4: BackendTLSPolicy targets sectionName=management (port 9443)"
assert_k8s_field "T4: sectionName=management" \
    "backendtlspolicy/${BTLS_NAME}" "{.spec.targetRefs[0].sectionName}" "management" "${NS}"

log_info "T5: BackendTLSPolicy validation hostname is the headless service FQDN"
HOSTNAME=$(kubectl get backendtlspolicy "${BTLS_NAME}" -n "${NS}" \
    -o jsonpath='{.spec.validation.hostname}' 2>/dev/null)
if echo "${HOSTNAME}" | grep -q "headless"; then
    log_pass "T5: validation hostname contains 'headless' (${HOSTNAME})"
else
    log_fail "T5: unexpected hostname '${HOSTNAME}'"
fi

# Restore to default (backendTLS disabled) after the test
log_info "Restoring Helm release to backendTLS.enabled=false..."
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
