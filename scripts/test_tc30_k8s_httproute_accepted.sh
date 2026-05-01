#!/usr/bin/env bash
# TC30: HTTPRoute is Accepted and backend refs are resolved by Envoy Gateway
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC30"

NS="${K8S_TEST_NAMESPACE}"
HTTPROUTE_NAME=$(kubectl get httproute -n "${NS}" -o name 2>/dev/null | head -1 | sed 's|.*/||')

if [[ -z "${HTTPROUTE_NAME}" ]]; then
    log_fail "No HTTPRoute found in namespace ${NS} — was TC28 setup run?"
    print_summary; tc_exit_code; exit 1
fi

log_info "Testing HTTPRoute: ${HTTPROUTE_NAME}"

# HTTPRoute status conditions are under .status.parents[0].conditions (not .status.conditions)
wait_for_httproute_condition() {
    local name="$1" ctype="$2" namespace="${3}" timeout="${4:-120}"
    local elapsed=0
    while (( elapsed < timeout )); do
        local status
        status=$(kubectl get httproute "${name}" -n "${namespace}" \
            -o "jsonpath={.status.parents[0].conditions[?(@.type=='${ctype}')].status}" 2>/dev/null)
        [[ "${status}" == "True" ]] && return 0
        sleep 10; (( elapsed += 10 )) || true
    done
    return 1
}

log_info "T1: HTTPRoute condition Accepted=True (waiting up to ${K8S_GATEWAY_TIMEOUT}s)"
if wait_for_httproute_condition "${HTTPROUTE_NAME}" "Accepted" "${NS}" "${K8S_GATEWAY_TIMEOUT}"; then
    log_pass "T1: HTTPRoute Accepted=True"
else
    log_fail "T1: HTTPRoute Accepted not True after ${K8S_GATEWAY_TIMEOUT}s"
fi

log_info "T2: HTTPRoute condition ResolvedRefs=True (backend service found)"
if wait_for_httproute_condition "${HTTPROUTE_NAME}" "ResolvedRefs" "${NS}" "${K8S_GATEWAY_TIMEOUT}"; then
    log_pass "T2: HTTPRoute ResolvedRefs=True"
else
    log_fail "T2: HTTPRoute ResolvedRefs not True after ${K8S_GATEWAY_TIMEOUT}s"
fi

log_info "T3: HTTPRoute parentRef status shows the Gateway"
PARENT_GW=$(kubectl get httproute "${HTTPROUTE_NAME}" -n "${NS}" \
    -o jsonpath='{.status.parents[0].parentRef.name}' 2>/dev/null)
if [[ "${PARENT_GW}" == "${K8S_GATEWAY_NAME}" ]]; then
    log_pass "T3: parentRef in status = ${K8S_GATEWAY_NAME}"
else
    log_fail "T3: parentRef name in status = '${PARENT_GW}', expected '${K8S_GATEWAY_NAME}'"
fi

log_info "T4: HTTPRoute backend controller is Envoy Gateway"
CTRL=$(kubectl get httproute "${HTTPROUTE_NAME}" -n "${NS}" \
    -o jsonpath='{.status.parents[0].controllerName}' 2>/dev/null)
if echo "${CTRL}" | grep -qi "envoyproxy\|envoy"; then
    log_pass "T4: controller is Envoy Gateway (${CTRL})"
else
    log_fail "T4: unexpected controller '${CTRL}'"
fi

print_summary; tc_exit_code
