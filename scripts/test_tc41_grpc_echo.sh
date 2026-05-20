#!/usr/bin/env bash
# TC41: gRPC echo — request-response round-trip via grpc-service / grpc-call
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC41"

require_si_running

log_info "T1: gRPC server and client apps started"
undeploy_app "TC41_GrpcServer.siddhi"
undeploy_app "TC41_GrpcClient.siddhi"
deploy_app   "TC41_GrpcServer.siddhi"
deploy_app   "TC41_GrpcClient.siddhi"
assert_log_contains "T1: TC41 server started" 'TC41_GrpcServer.*deployed successfully' 30
assert_log_contains "T1: TC41 client started" 'TC41_GrpcClient.*deployed successfully' 30

log_info "T2: POST one request — server echoes it back to client"
STATUS=$(post_event "http://localhost:${PORT_TC41}/TC41_GrpcClient/TriggerStream" \
    '{"message":"HellogRPC"}')
if [[ "${STATUS}" != "200" ]]; then
    log_fail "T2: HTTP POST returned ${STATUS}, expected 200"
else
    assert_log_contains "T2: gRPC server received HellogRPC" '\[TC41-SERVER\].*HellogRPC' 20
    assert_log_contains "T2: gRPC client received echo" '\[TC41-CLIENT\].*Echo.*HellogRPC' 20
fi

log_info "T3: POST three more messages — all echoed"
for msg in Alpha Beta Gamma; do
    post_event "http://localhost:${PORT_TC41}/TC41_GrpcClient/TriggerStream" \
        "{\"message\":\"${msg}\"}" >/dev/null
    sleep 2  # wait for gRPC round-trip to complete before next request
done
assert_log_contains "T3: Alpha echoed" '\[TC41-CLIENT\].*Echo.*Alpha' 20
assert_log_contains "T3: Beta echoed" '\[TC41-CLIENT\].*Echo.*Beta' 20
assert_log_contains "T3: Gamma echoed" '\[TC41-CLIENT\].*Echo.*Gamma' 20

print_summary; tc_exit_code
