#!/usr/bin/env bash
# setup_si.sh — Create test namespace, TLS secret, and deploy WSO2 SI with Gateway API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"
source "${SCRIPT_DIR}/../lib/common.sh"
CURRENT_TC="SETUP-SI"

CHART_DIR="${HELM_SI_CHART}"
TEMP_CERT_DIR=$(mktemp -d /tmp/si-tls-XXXXXX)
trap 'rm -rf "${TEMP_CERT_DIR}"' EXIT

# ── Namespace ────────────────────────────────────────────────────────────────
log_info "Creating namespace ${K8S_TEST_NAMESPACE}..."
kubectl create namespace "${K8S_TEST_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── TLS Secret ───────────────────────────────────────────────────────────────
log_info "Generating self-signed TLS certificate for ${K8S_HOSTNAME}..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${TEMP_CERT_DIR}/tls.key" \
    -out    "${TEMP_CERT_DIR}/tls.crt" \
    -subj   "/CN=${K8S_HOSTNAME}/O=WSO2-SI-Test" \
    -addext "subjectAltName=DNS:${K8S_HOSTNAME}" \
    2>/dev/null

kubectl create secret tls "${K8S_TLS_SECRET}" \
    --cert="${TEMP_CERT_DIR}/tls.crt" \
    --key="${TEMP_CERT_DIR}/tls.key" \
    -n "${K8S_TEST_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_pass "TLS secret '${K8S_TLS_SECRET}' created in ${K8S_TEST_NAMESPACE}"

# ── Helm deploy ──────────────────────────────────────────────────────────────
log_info "Deploying WSO2 SI chart from ${CHART_DIR}..."

HELM_ARGS=(
    --values "${CHART_DIR}/values_local.yaml"
    --set wso2.ingress.enabled=false
    --set wso2.gatewayApi.enabled=true
    --set wso2.gatewayApi.gatewayClassName="${K8S_GATEWAY_CLASS}"
    --set wso2.gatewayApi.gateway.create=true
    --set "wso2.gatewayApi.gateway.name=${K8S_GATEWAY_NAME}"
    --set "wso2.gatewayApi.gateway.tlsSecret=${K8S_TLS_SECRET}"
    --set wso2.gatewayApi.gateway.listenerName=https
    --set wso2.gatewayApi.gateway.port="${K8S_GATEWAY_PORT:-8443}"
    --set wso2.gatewayApi.backendTLS.enabled=false
    --set wso2.gatewayApi.rateLimit.enabled=false
    --set "wso2.deployment.hostname=${K8S_HOSTNAME}"
    -n "${K8S_TEST_NAMESPACE}"
)

if helm list -n "${K8S_TEST_NAMESPACE}" 2>/dev/null | grep -q "^${K8S_RELEASE_NAME}"; then
    log_info "Helm release '${K8S_RELEASE_NAME}' exists — upgrading..."
    helm upgrade "${K8S_RELEASE_NAME}" "${CHART_DIR}" "${HELM_ARGS[@]}"
else
    helm install "${K8S_RELEASE_NAME}" "${CHART_DIR}" "${HELM_ARGS[@]}"
fi

log_pass "Helm release '${K8S_RELEASE_NAME}' deployed to namespace '${K8S_TEST_NAMESPACE}'"
log_info "SI pod has a 180s probe delay — use run_all_tests.sh --with-k8s to run tests once ready."
kubectl get all -n "${K8S_TEST_NAMESPACE}" 2>/dev/null || true
