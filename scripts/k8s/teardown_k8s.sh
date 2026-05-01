#!/usr/bin/env bash
# teardown_k8s.sh — Remove the SI test namespace and optionally uninstall Envoy Gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"
source "${SCRIPT_DIR}/../lib/common.sh"
CURRENT_TC="TEARDOWN"

REMOVE_EG=false
[[ "${1:-}" == "--with-envoy-gateway" ]] && REMOVE_EG=true

log_info "Deleting namespace ${K8S_TEST_NAMESPACE}..."
kubectl delete namespace "${K8S_TEST_NAMESPACE}" --ignore-not-found=true
log_pass "Namespace ${K8S_TEST_NAMESPACE} deleted"

if [[ "${REMOVE_EG}" == "true" ]]; then
    log_info "Uninstalling Envoy Gateway from ${K8S_ENVOY_NS}..."
    helm uninstall eg -n "${K8S_ENVOY_NS}" 2>/dev/null || true
    kubectl delete namespace "${K8S_ENVOY_NS}" --ignore-not-found=true
    log_pass "Envoy Gateway removed"
fi

log_pass "Teardown complete"
