#!/usr/bin/env bash
# TC32: HTTPS traffic routes correctly through Envoy Gateway to WSO2 SI.
# Uses the Node's external IP + LoadBalancer NodePort with --resolve for TLS SNI.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC32"

NS="${K8S_TEST_NAMESPACE}"
GW_PORT="${K8S_GATEWAY_PORT:-8443}"
NODE_IP="192.168.64.2"   # Rancher Desktop Lima VM external IP

# Resolve the Envoy proxy service NodePort for our Gateway
log_info "Resolving Envoy proxy NodePort for Gateway '${K8S_GATEWAY_NAME}'..."
ENVOY_SVC_NAME=$(kubectl get svc -n "${K8S_ENVOY_NS}" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${K8S_GATEWAY_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${NS}" \
    -o name 2>/dev/null | head -1 | sed 's|.*/||')

if [[ -z "${ENVOY_SVC_NAME}" ]]; then
    log_fail "No Envoy proxy service found for Gateway '${K8S_GATEWAY_NAME}' in ${K8S_ENVOY_NS}"
    print_summary; tc_exit_code; exit 1
fi

NODE_PORT=$(kubectl get svc "${ENVOY_SVC_NAME}" -n "${K8S_ENVOY_NS}" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

if [[ -z "${NODE_PORT}" ]]; then
    log_fail "Could not read NodePort from service ${ENVOY_SVC_NAME}"
    print_summary; tc_exit_code; exit 1
fi
log_info "Envoy NodePort: ${NODE_IP}:${NODE_PORT} (resolves SNI ${K8S_HOSTNAME})"

log_info "T1: Envoy proxy service and NodePort are available"
log_pass "T1: Envoy proxy service ${ENVOY_SVC_NAME}, NodePort=${NODE_PORT}"

# All curl calls use --resolve to set the TLS SNI to K8S_HOSTNAME while
# connecting to the node IP. This is required because Envoy's filter chain
# matches on the SNI value, not the TCP destination IP.
RESOLVE_OPT="--resolve ${K8S_HOSTNAME}:${NODE_PORT}:${NODE_IP}"
BASE_URL="https://${K8S_HOSTNAME}:${NODE_PORT}"

log_info "T2: Unknown path returns 404 (Envoy routing is working)"
assert_https_status "T2: /unknown → 404" \
    "${BASE_URL}/unknown-path-xyz" "404" \
    ${RESOLVE_OPT}

log_info "T3: /siddhi-apps without credentials returns 400/401 (request reached SI)"
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" ${RESOLVE_OPT} \
    "${BASE_URL}/siddhi-apps" 2>/dev/null || echo "000")
if [[ "${STATUS}" == "400" || "${STATUS}" == "401" ]]; then
    log_pass "T3: /siddhi-apps unauthenticated → ${STATUS} (SI reachable, auth enforced)"
else
    log_fail "T3: /siddhi-apps unauthenticated → ${STATUS} (expected 400 or 401)"
fi

log_info "T4: /siddhi-apps with valid credentials returns 200"
assert_https_status "T4: /siddhi-apps authenticated → 200" \
    "${BASE_URL}/siddhi-apps" "200" \
    ${RESOLVE_OPT} -u "admin:admin"

log_info "T5: Wrong SNI hostname fails TLS handshake (Envoy SNI routing enforced)"
if curl -sk -o /dev/null \
    --resolve "wrong.host.com:${NODE_PORT}:${NODE_IP}" \
    "https://wrong.host.com:${NODE_PORT}/siddhi-apps" 2>/dev/null; then
    log_fail "T5: curl succeeded with wrong SNI — SNI routing not enforced"
else
    log_pass "T5: wrong SNI → TLS handshake dropped (filter chain not found)"
fi

print_summary; tc_exit_code
