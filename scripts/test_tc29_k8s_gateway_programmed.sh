#!/usr/bin/env bash
# TC29: Gateway reaches Programmed=True and receives an address from Envoy Gateway
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC29"

NS="${K8S_TEST_NAMESPACE}"

log_info "T1: Gateway condition Programmed=True (waiting up to ${K8S_GATEWAY_TIMEOUT}s)"
assert_k8s_condition "T1: Gateway Programmed=True" \
    "gateway/${K8S_GATEWAY_NAME}" "Programmed" "${NS}" "${K8S_GATEWAY_TIMEOUT}"

log_info "T2: Gateway condition Accepted=True"
assert_k8s_condition "T2: Gateway Accepted=True" \
    "gateway/${K8S_GATEWAY_NAME}" "Accepted" "${NS}" "${K8S_GATEWAY_TIMEOUT}"

log_info "T3: Gateway has at least one address assigned"
GW_ADDR=$(kubectl get gateway "${K8S_GATEWAY_NAME}" -n "${NS}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [[ -n "${GW_ADDR}" ]]; then
    log_pass "T3: Gateway address assigned: ${GW_ADDR}"
else
    log_fail "T3: No address found on Gateway status"
fi

log_info "T4: GatewayClass '${K8S_GATEWAY_CLASS}' is Accepted"
assert_k8s_condition "T4: GatewayClass Accepted=True" \
    "gatewayclass/${K8S_GATEWAY_CLASS}" "Accepted" "default" "${K8S_GATEWAY_TIMEOUT}"

print_summary; tc_exit_code
