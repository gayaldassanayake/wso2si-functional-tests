#!/usr/bin/env bash
# setup_envoy_gateway.sh — Install Envoy Gateway and wait for it to be ready.
# Run once before deploying WSO2 SI for live K8s tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"
source "${SCRIPT_DIR}/../lib/common.sh"
CURRENT_TC="SETUP-EG"

ENVOY_GATEWAY_VERSION="v1.3.2"
EG_OCI_CHART="oci://docker.io/envoyproxy/gateway-helm"

log_info "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} in namespace ${K8S_ENVOY_NS}..."

# Install or upgrade Envoy Gateway via OCI
if helm list -n "${K8S_ENVOY_NS}" 2>/dev/null | grep -q "^eg"; then
    log_info "Envoy Gateway already installed — upgrading..."
    helm upgrade eg "${EG_OCI_CHART}" \
        --version "${ENVOY_GATEWAY_VERSION}" \
        -n "${K8S_ENVOY_NS}" \
        --wait --timeout 5m
else
    helm install eg "${EG_OCI_CHART}" \
        --version "${ENVOY_GATEWAY_VERSION}" \
        -n "${K8S_ENVOY_NS}" --create-namespace \
        --wait --timeout 5m
fi

log_info "Waiting for Envoy Gateway controller pod to be Ready..."
kubectl rollout status deployment/envoy-gateway -n "${K8S_ENVOY_NS}" --timeout=120s

# Create GatewayClass if it doesn't already exist
log_info "Ensuring GatewayClass '${K8S_GATEWAY_CLASS}' exists..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${K8S_GATEWAY_CLASS}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

# Wait for GatewayClass to be Accepted
local_timeout=60; elapsed=0
until [[ "$(kubectl get gatewayclass "${K8S_GATEWAY_CLASS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == "True" ]]; do
    sleep 5; (( elapsed += 5 )) || true
    if (( elapsed >= local_timeout )); then
        echo "[ERROR] GatewayClass '${K8S_GATEWAY_CLASS}' not Accepted after ${local_timeout}s" >&2
        exit 1
    fi
done

log_pass "Envoy Gateway is ready. GatewayClass '${K8S_GATEWAY_CLASS}' exists."
kubectl get gatewayclass "${K8S_GATEWAY_CLASS}"
