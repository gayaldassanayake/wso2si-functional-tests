#!/usr/bin/env bash
# TC28: All expected Kubernetes resources are created by the Helm release
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC28"

NS="${K8S_TEST_NAMESPACE}"
REL="${K8S_RELEASE_NAME}"

log_info "T1: StatefulSet exists"
assert_k8s_resource_exists "T1: StatefulSet created" "statefulset" "${NS}"

log_info "T2: Headless Service exists"
# The chart prefixes with cloudName (defaults to 'cloud'), so the service is cloud-<release>-headless
HEADLESS_SVC=$(kubectl get svc -n "${NS}" -o name 2>/dev/null | grep "headless" | head -1 | sed 's|.*/||')
if [[ -n "${HEADLESS_SVC}" ]]; then
    log_pass "T2: headless Service exists (${HEADLESS_SVC})"
else
    log_fail "T2: no headless Service found in namespace ${NS}"
fi

log_info "T3: Gateway resource exists"
wait_for_k8s_resource "gateway/${K8S_GATEWAY_NAME}" "${NS}" "${K8S_RESOURCE_TIMEOUT}"
assert_k8s_resource_exists "T3: Gateway '${K8S_GATEWAY_NAME}' created" \
    "gateway/${K8S_GATEWAY_NAME}" "${NS}"

log_info "T4: Gateway uses correct GatewayClass"
assert_k8s_field "T4: gatewayClassName=eg" \
    "gateway/${K8S_GATEWAY_NAME}" \
    "{.spec.gatewayClassName}" \
    "${K8S_GATEWAY_CLASS}" "${NS}"

log_info "T5: Gateway listener is HTTPS on configured port"
assert_k8s_field "T5: listener protocol=HTTPS" \
    "gateway/${K8S_GATEWAY_NAME}" \
    "{.spec.listeners[0].protocol}" \
    "HTTPS" "${NS}"
assert_k8s_field "T5: listener port=${K8S_GATEWAY_PORT:-8443}" \
    "gateway/${K8S_GATEWAY_NAME}" \
    "{.spec.listeners[0].port}" \
    "${K8S_GATEWAY_PORT:-8443}" "${NS}"

log_info "T6: Gateway TLS references the correct secret"
assert_k8s_field "T6: TLS secret name matches" \
    "gateway/${K8S_GATEWAY_NAME}" \
    "{.spec.listeners[0].tls.certificateRefs[0].name}" \
    "${K8S_TLS_SECRET}" "${NS}"

log_info "T7: HTTPRoute exists"
HTTPROUTE_NAME=$(kubectl get httproute -n "${NS}" -o name 2>/dev/null | head -1 | sed 's|.*/||')
wait_for_k8s_resource "httproute/${HTTPROUTE_NAME}" "${NS}" "${K8S_RESOURCE_TIMEOUT}" 2>/dev/null || true
assert_k8s_resource_exists "T7: HTTPRoute created" "httproute" "${NS}"

log_info "T8: HTTPRoute parentRef points to the Gateway"
assert_k8s_field_matches "T8: parentRef name=si-gateway" \
    "httproute/${HTTPROUTE_NAME}" \
    "{.spec.parentRefs[0].name}" \
    "${K8S_GATEWAY_NAME}" "${NS}"

log_info "T9: HTTPRoute hostname matches configured hostname"
assert_k8s_field "T9: HTTPRoute hostname=si.wso2.com" \
    "httproute/${HTTPROUTE_NAME}" \
    "{.spec.hostnames[0]}" \
    "${K8S_HOSTNAME}" "${NS}"

log_info "T10: HTTPRoute rule path is /siddhi-apps"
assert_k8s_field "T10: path value=/siddhi-apps" \
    "httproute/${HTTPROUTE_NAME}" \
    "{.spec.rules[0].matches[0].path.value}" \
    "/siddhi-apps" "${NS}"

log_info "T11: No Ingress resource created"
INGRESS_COUNT=$(kubectl get ingress -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${INGRESS_COUNT}" == "0" ]]; then
    log_pass "T11: no Ingress resource in namespace"
else
    log_fail "T11: unexpected Ingress resource(s) found: $(kubectl get ingress -n "${NS}" --no-headers 2>/dev/null)"
fi

print_summary; tc_exit_code
