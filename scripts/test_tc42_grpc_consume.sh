#!/usr/bin/env bash
# TC42: gRPC consume — fire-and-forget via grpc sink / grpc source
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC42"

require_si_running

log_info "T1: gRPC consumer and sender apps started"
undeploy_app "TC42_GrpcConsume.siddhi"
undeploy_app "TC42_GrpcSender.siddhi"
deploy_app   "TC42_GrpcConsume.siddhi"
deploy_app   "TC42_GrpcSender.siddhi"
assert_log_contains "T1: TC42 consumer started" 'TC42_GrpcConsume.*deployed successfully' 30
assert_log_contains "T1: TC42 sender started" 'TC42_GrpcSender.*deployed successfully' 30

# GrpcEventServiceServer closes the HTTP/2 stream after each consumed event
# (calls responseObserver.onCompleted() in onNext). Redeploy the sender to get
# a fresh gRPC streaming connection before each event delivery.
undeploy_app "TC42_GrpcSender.siddhi"
deploy_app   "TC42_GrpcSender.siddhi"
assert_log_contains "T1: TC42 sender restarted" 'TC42_GrpcSender.*deployed successfully' 30

log_info "T2: POST one event — consumer receives it"
STATUS=$(post_event "http://localhost:${PORT_TC42}/TC42_GrpcSender/SendStream" \
    '{"message":"FireAndForget"}')
if [[ "${STATUS}" != "200" ]]; then
    log_fail "T2: HTTP POST returned ${STATUS}, expected 200"
else
    assert_log_contains "T2: consumer received FireAndForget" '\[TC42-CONSUME\].*FireAndForget' 20
fi

log_info "T3: Sender reconnects — another event is delivered on a fresh connection"
undeploy_app "TC42_GrpcSender.siddhi"
deploy_app   "TC42_GrpcSender.siddhi"
assert_log_contains "T3: TC42 sender restarted" 'TC42_GrpcSender.*deployed successfully' 30
STATUS=$(post_event "http://localhost:${PORT_TC42}/TC42_GrpcSender/SendStream" \
    '{"message":"Reconnect"}')
if [[ "${STATUS}" != "200" ]]; then
    log_fail "T3: HTTP POST returned ${STATUS}, expected 200"
else
    assert_log_contains "T3: consumer received Reconnect" '\[TC42-CONSUME\].*Reconnect' 20
fi

print_summary; tc_exit_code
