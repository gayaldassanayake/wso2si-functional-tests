#!/usr/bin/env bash
# TC57: Cron trigger lifecycle across apps and Quartz scheduler shutdown (BNYMDMAPROD-220)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC57"

require_si_running

APP_A="TC57_CronTriggerA.siddhi"
APP_B="TC57_CronTriggerB.siddhi"
PID_FILE="${SI_HOME}/wso2/server/runtime.pid"
QUARTZ_WORKER="DefaultQuartzScheduler_Worker"

quartz_worker_count() {
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null) || { echo -1; return; }
    jstack "${pid}" 2>/dev/null | grep -c "\"${QUARTZ_WORKER}" || true
}

LOG_OFFSET=0
mark_log() { LOG_OFFSET=$(wc -c < "${SI_LOG}" 2>/dev/null || echo 0); }
new_log() { tail -c "+$(( LOG_OFFSET + 1 ))" "${SI_LOG}" 2>/dev/null; }

wait_new_log() {
    local pattern="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        new_log | grep -qE "${pattern}" && return 0
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

cleanup() {
    rm -f "${SI_SIDDHI_DIR}/${APP_A}" "${SI_SIDDHI_DIR}/${APP_B}"
}
trap cleanup EXIT

undeploy_app "${APP_A}"
undeploy_app "${APP_B}"
BASELINE_WORKERS=$(quartz_worker_count)

log_info "T1: two apps with the same cron trigger id both fire"
mark_log
deploy_app "${APP_A}"
deploy_app "${APP_B}"
if wait_new_log '\[TC57-A\]' 15 && wait_new_log '\[TC57-B\]' 15; then
    log_pass "T1: [TC57-A] and [TC57-B] both logged"
else
    log_fail "T1: expected ticks from both apps"
fi

log_info "T2: undeploying one app leaves the other app's trigger firing"
mark_log
undeploy_app "${APP_A}"
if ! wait_new_log 'TC57_CronTriggerA undeployed successfully' 20; then
    log_fail "T2: TC57_CronTriggerA was not undeployed"
fi
mark_log
sleep 7
if new_log | grep -q '\[TC57-B\]'; then
    log_pass "T2: [TC57-B] keeps firing after TC57_CronTriggerA is undeployed"
else
    log_fail "T2: [TC57-B] stopped firing after TC57_CronTriggerA was undeployed"
fi
if new_log | grep -q '\[TC57-A\]'; then
    log_fail "T2: [TC57-A] still firing after undeploy"
else
    log_pass "T2: [TC57-A] stopped after undeploy"
fi

log_info "T3: Quartz worker threads exit once no cron job is left"
mark_log
undeploy_app "${APP_B}"
wait_new_log 'TC57_CronTriggerB undeployed successfully' 20 || log_fail "T3: TC57_CronTriggerB was not undeployed"
if [[ "${BASELINE_WORKERS}" != "0" ]]; then
    log_skip "T3: ${BASELINE_WORKERS} ${QUARTZ_WORKER} threads existed before TC57 (another app uses cron, or jstack failed)"
else
    WORKERS=-1
    for _ in $(seq 1 15); do
        WORKERS=$(quartz_worker_count)
        [[ "${WORKERS}" == "0" ]] && break
        sleep 1
    done
    if [[ "${WORKERS}" == "0" ]]; then
        log_pass "T3: no ${QUARTZ_WORKER} threads after both apps are undeployed"
    else
        log_fail "T3: ${WORKERS} ${QUARTZ_WORKER} threads remain after both apps are undeployed"
    fi
fi

log_info "T4: a redeployed app fires again on a new scheduler"
mark_log
deploy_app "${APP_A}"
if wait_new_log '\[TC57-A\]' 15; then
    log_pass "T4: [TC57-A] fires after redeploy"
else
    log_fail "T4: [TC57-A] did not fire after redeploy"
fi
undeploy_app "${APP_A}"

print_summary; tc_exit_code
