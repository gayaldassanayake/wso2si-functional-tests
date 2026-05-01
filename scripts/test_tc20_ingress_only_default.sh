#!/usr/bin/env bash
# TC20: Default template rendering — only Ingress renders, no Gateway API resources
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC20"

YAML=$(helm_template --set wso2.config.admin.password=YWRtaW4=)

log_info "T1: Ingress resource is rendered with default values"
assert_yaml_contains "T1: Ingress kind present" "${YAML}" "^kind: Ingress$"

log_info "T2: ingressClassName is nginx (default)"
assert_yaml_contains "T2: ingressClassName=nginx" "${YAML}" "ingressClassName: nginx"

log_info "T3: No Gateway resource rendered"
assert_yaml_not_contains "T3: kind Gateway absent" "${YAML}" "^kind: Gateway$"

log_info "T4: No HTTPRoute resource rendered"
assert_yaml_not_contains "T4: kind HTTPRoute absent" "${YAML}" "^kind: HTTPRoute$"

log_info "T5: No BackendTLSPolicy resource rendered"
assert_yaml_not_contains "T5: kind BackendTLSPolicy absent" "${YAML}" "^kind: BackendTLSPolicy$"

log_info "T6: No BackendTrafficPolicy resource rendered"
assert_yaml_not_contains "T6: kind BackendTrafficPolicy absent" "${YAML}" "^kind: BackendTrafficPolicy$"

print_summary; tc_exit_code
