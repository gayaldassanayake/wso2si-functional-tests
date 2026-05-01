#!/usr/bin/env bash
# TC31: WSO2 SI StatefulSet pod is Running and Ready
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC31"

NS="${K8S_TEST_NAMESPACE}"
STS_NAME=$(kubectl get statefulset -n "${NS}" -o name 2>/dev/null | head -1 | sed 's|.*/||')

if [[ -z "${STS_NAME}" ]]; then
    log_fail "No StatefulSet found in namespace ${NS}"
    print_summary; tc_exit_code; exit 1
fi

log_info "Testing StatefulSet: ${STS_NAME} (pod probe delay is 180s — timeout=${K8S_POD_TIMEOUT}s)"

log_info "T1: StatefulSet has 1 replica desired"
assert_k8s_field "T1: replicas=1" \
    "statefulset/${STS_NAME}" "{.spec.replicas}" "1" "${NS}"

log_info "T2: StatefulSet becomes ready within ${K8S_POD_TIMEOUT}s"
assert_statefulset_ready "T2: SI pod Ready" \
    "${STS_NAME}" "${NS}" "${K8S_POD_TIMEOUT}" 1

log_info "T3: SI pod phase is Running"
POD_NAME="${STS_NAME}-0"
POD_PHASE=$(kubectl get pod "${POD_NAME}" -n "${NS}" \
    -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "${POD_PHASE}" == "Running" ]]; then
    log_pass "T3: pod ${POD_NAME} is Running"
else
    log_fail "T3: pod ${POD_NAME} phase is '${POD_PHASE}'"
fi

log_info "T4: SI container passes readiness probe"
READY=$(kubectl get pod "${POD_NAME}" -n "${NS}" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
if [[ "${READY}" == "true" ]]; then
    log_pass "T4: container is ready"
else
    log_fail "T4: container not ready (ready=${READY})"
    kubectl describe pod "${POD_NAME}" -n "${NS}" 2>/dev/null | grep -A 5 "Conditions:" >&2 || true
fi

print_summary; tc_exit_code
