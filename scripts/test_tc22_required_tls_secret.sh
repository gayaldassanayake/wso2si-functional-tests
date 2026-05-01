#!/usr/bin/env bash
# TC22: Missing tlsSecret when gateway.create=true must cause a fast-fail
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC22"

log_info "T1: helm template fails when tlsSecret is empty and gateway.create=true"
assert_helm_template_fails \
    "T1: empty tlsSecret triggers required error" \
    "tlsSecret must be set" \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.create=true \
    --set wso2.gatewayApi.gateway.tlsSecret="" \
    --set wso2.config.admin.password=YWRtaW4=

log_info "T2: helm template succeeds when tlsSecret is provided"
YAML=$(helm_template \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.create=true \
    --set wso2.gatewayApi.gateway.tlsSecret=my-cert \
    --set wso2.config.admin.password=YWRtaW4=)
assert_yaml_contains "T2: valid tlsSecret renders Gateway without error" "${YAML}" "^kind: Gateway$"

log_info "T3: helm template succeeds without tlsSecret when gateway.create=false"
YAML=$(helm_template \
    --set wso2.ingress.enabled=false \
    --set wso2.gatewayApi.enabled=true \
    --set wso2.gatewayApi.gateway.create=false \
    --set wso2.config.admin.password=YWRtaW4=)
assert_yaml_not_contains "T3: no Gateway resource when create=false" "${YAML}" "^kind: Gateway$"
assert_yaml_contains "T3: HTTPRoute still renders when create=false" "${YAML}" "^kind: HTTPRoute$"

print_summary; tc_exit_code
