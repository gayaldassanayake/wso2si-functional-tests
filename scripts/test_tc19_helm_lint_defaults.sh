#!/usr/bin/env bash
# TC19: helm lint with default values — backward compatibility baseline
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC19"

log_info "T1: helm lint passes with chart defaults (gatewayApi.enabled=false)"
assert_helm_lint "T1: helm lint — default values" \
    --set wso2.config.admin.password=YWRtaW4=

log_info "T2: helm lint passes with ingress explicitly enabled and gateway disabled"
assert_helm_lint "T2: helm lint — ingress=true, gatewayApi=false" \
    --set wso2.ingress.enabled=true \
    --set wso2.gatewayApi.enabled=false \
    --set wso2.config.admin.password=YWRtaW4=

log_info "T3: helm lint passes with Gateway API enabled and tlsSecret provided"
assert_helm_lint "T3: helm lint — gatewayApi=true, tlsSecret set" \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.tlsSecret=my-tls-secret \
    --set wso2.config.admin.password=YWRtaW4=

print_summary; tc_exit_code
