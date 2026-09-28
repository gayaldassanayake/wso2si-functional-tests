# Manual test: HA failover (BNYMDMAPROD-198, BNYMDMAPROD-247)

Two HA fixes from SI 1.1.0 need two nodes and a killed active node, so they are checked by hand:

- **BNYMDMAPROD-198:** after a failover both nodes could end up passive. SI 4.4.1 sends the buffered events to the input handlers only after the sources start (`HAManager.java:269-275`).
- **BNYMDMAPROD-247:** one broken Siddhi app stopped the other apps from deploying after a failover. SI 4.4.1 catches the failure per app (`HAManager.createSiddhiAppRuntimes()`).

## Setup

1. Follow [ha-cron-trigger.md](ha-cron-trigger.md) Setup steps 1–4: MySQL, two packs (`node1/`, `node2/`) with the MySQL driver, `WSO2_CLUSTER_DB` on MySQL, `cluster.config.enabled: true`, the HA `deployment.config`, unique `wso2.carbon.id`, and `wso2.carbon.ports.offset: 1` on node 2.
2. In both `conf/server/deployment.yaml`, turn on state persistence in the database:
   ```yaml
   state.persistence:
     enabled: true
     intervalInMin: 1
     revisionsToKeep: 2
     persistenceStore: org.wso2.carbon.streaming.integrator.core.persistence.DBPersistenceStore
     config:
       datasource: WSO2_PERSISTENCE_DB
       table: PERSISTENCE_TABLE
   ```
   and add this datasource under `wso2.datasources.dataSources`:
   ```yaml
       - name: WSO2_PERSISTENCE_DB
         description: "State persistence store for HA"
         definition:
           type: RDBMS
           configuration:
             jdbcUrl: "jdbc:mysql://localhost:3307/si_test_db?useSSL=false&allowPublicKeyRetrieval=true"
             username: sitest
             password: sitest123
             driverClassName: com.mysql.cj.jdbc.Driver
             maxPoolSize: 10
             idleTimeout: 60000
             connectionTestQuery: SELECT 1
             validationTimeout: 30000
             isAutoCommit: false
   ```
3. Put the five apps below in `wso2/server/deployment/siddhi-files/` on **both** nodes.
4. Start node 1 and wait for `Successfully Changed to Active Mode`. Then start node 2 and wait for `Successfully Changed to Passive Mode`.

Only the active node starts the HTTP sources, so both nodes can use ports 8133–8135 on one host. If node 2 logs a bind error for these ports while it is passive, move node 2 to another host.

Helpers:
```bash
state() { grep -hoE 'Successfully Changed to (Active|Passive) Mode' "$1/wso2/server/logs/carbon.log" | tail -1; }
leader() { docker exec si-test-mysql mysql -usitest -psitest123 si_test_db -e "SELECT * FROM LEADER_STATUS_TABLE;"; }
kill_node() { kill -9 "$(cat "$1/wso2/server/runtime.pid")"; }
```

## Apps

`HAGoodA.siddhi` (the load app for Part A):
```sql
@App:name('HAGoodA')
@source(type='http', receiver.url='http://0.0.0.0:8133/HAGoodA/In', @map(type='json'))
define stream In (id string, v int);
@sink(type='log', prefix='[HA-LOAD]')
define stream Out (total long);
from In#window.lengthBatch(10) select count() as total insert into Out;
```

`HAGoodB.siddhi` and `HAGoodC.siddhi`: the same as `HAGoodA` with the name, the port (8134, 8135) and the log prefix (`[HA-B]`, `[HA-C]`) changed.

`HABroken.siddhi` (syntax error, a missing `;`):
```sql
@App:name('HABroken')
define stream In (id string)
from In select id insert into Out;
```

`HAMismatch.siddhi` (the file name differs from `@App:name`):
```sql
@App:name('HAMismatchRenamed')
define trigger T at every 30 sec;
@sink(type='log', prefix='[HA-MISMATCH]')
define stream Out (triggered_time long);
from T select triggered_time insert into Out;
```

## Part A: never both passive (BNYMDMAPROD-198)

Start the load in a separate terminal and leave it running:
```bash
while true; do
  curl -s -o /dev/null --max-time 2 -X POST -H 'Content-Type: application/json' \
    -d "{\"event\":{\"id\":\"e$RANDOM\",\"v\":1}}" http://localhost:8133/HAGoodA/In
  sleep 0.2
done
```

Repeat 10 times, alternating which node is active:

| # | Action | Expected |
|---|---|---|
| 1 | `kill_node <active>` | Within about 30 s the other node logs `Successfully Changed to Active Mode`. |
| 2 | Watch its log | `[HA-LOAD]` lines resume on the new active node. |
| 3 | Restart the killed node | It logs `Successfully Changed to Passive Mode`. |
| 4 | `state node1; state node2; leader` | Exactly one node is active; `LEADER_STATUS_TABLE` has one row, for the active node's id. |

Results:

| Cycle | Killed | Seconds to active | Exactly one active | Notes |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
| 9 | | | | |
| 10 | | | | |

## Part B: one broken app doesn't block the others (BNYMDMAPROD-247)

With all five apps deployed on both nodes, kill the active node, wait for the other to log `Successfully Changed to Active Mode`, then check:

| Check | Command | Expected |
|---|---|---|
| Good apps answer | `for p in 8133:HAGoodA 8134:HAGoodB 8135:HAGoodC; do curl -s -o /dev/null -w "%{http_code}\n" -X POST -H 'Content-Type: application/json' -d '{"event":{"id":"x","v":1}}' http://localhost:${p%%:*}/${p##*:}/In; done` | `200` three times |
| Broken app | `grep -c HABroken <new active>/wso2/server/logs/carbon.log` | Errors for `HABroken` only; the good apps still deploy |
| Name mismatch | `grep '\[HA-MISMATCH\]' <new active>/wso2/server/logs/carbon.log` | Lines appear: `HAMismatchRenamed` **does** deploy after failover. This is a known gap (handover T8), the same as on 1.1.0. |
