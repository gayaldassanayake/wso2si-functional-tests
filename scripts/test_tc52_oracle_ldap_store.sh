#!/usr/bin/env bash
# TC52: Oracle RDBMS store resolved through LDAP directory naming (BNYMDMAPROD-232)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC52"

require_si_running
require_oracle_ldap_running

if ! ls "${SI_HOME}/lib/ojdbc"*.jar 2>/dev/null | head -1 | grep -q '.jar'; then
    log_skip "Oracle JDBC driver (ojdbc11) not found in \${SI_HOME}/lib/ - skipping TC52"
    exit "${SKIP_EXIT_CODE}"
fi

URL="http://localhost:${PORT_TC52}/TC52_OracleLdapStore/OrderStream"

oracle_query "DROP TABLE IF EXISTS TC52_ORDERS PURGE;" >/dev/null

undeploy_app "TC52_OracleLdapStore.siddhi"
deploy_app   "TC52_OracleLdapStore.siddhi"
assert_app_deployed "app deployed" TC52_OracleLdapStore 60

log_info "T1: Oracle store connects through the LDAP-resolved URL"
if ! assert_log_not_contains "T1: no store connection error" \
        "Error on 'TC52_OracleLdapStore'|Not an instance of DirContext|NotContextException" 10; then
    print_summary; exit 1
fi

log_info "T2: POST 3 orders and verify log output"
post_event "${URL}" '{"orderId":"o1","amount":10.5}' >/dev/null
post_event "${URL}" '{"orderId":"o2","amount":20.0}' >/dev/null
post_event "${URL}" '{"orderId":"o3","amount":30.25}' >/dev/null
assert_log_contains "T2: events logged with [TC52] prefix" '\[TC52\].*o3' 25

log_info "T3: Verify 3 rows in Oracle TC52_ORDERS"
sleep 5
assert_oracle_count "T3: Oracle has 3 rows" "TC52_ORDERS" 3

print_summary; tc_exit_code
