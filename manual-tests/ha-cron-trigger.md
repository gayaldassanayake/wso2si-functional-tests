# Manual test: cron triggers across HA state changes (BNYMDMAPROD-220)

On SI 1.1.0 U45, cron triggers stopped firing after a database outage forced an HA state change. SI 4.4.1 stops every trigger when a Siddhi app runtime shuts down (siddhi 5.1.30+), gives each app its own Quartz job key, and shuts the Quartz scheduler down once no cron job is left (siddhi 5.1.34). TC57 covers the single-node behaviour; this procedure covers the HA failover path, which needs two nodes and a shared coordination database.

## Setup

1. Start MySQL: `./scripts/setup.sh --mysql` (container `si-test-mysql`, `localhost:3307`, `sitest`/`sitest123`, database `si_test_db`).
2. Unzip the pack twice as `node1/` and `node2/`. Put `mysql-connector-j-8.x.jar` in each pack's `lib/`.
3. In both `conf/server/deployment.yaml`:
   - Point the `WSO2_CLUSTER_DB` datasource at MySQL:
     ```yaml
     jdbcUrl: "jdbc:mysql://localhost:3307/si_test_db?useSSL=false&allowPublicKeyRetrieval=true"
     driverClassName: com.mysql.cj.jdbc.Driver
     username: sitest
     password: sitest123
     ```
   - Enable clustering: `cluster.config.enabled: true` (keep `groupId: si` on both nodes).
   - Add an HA `deployment.config` (uncomment the "Two node HA" sample). Use `eventSyncServer.port`/`advertisedPort` `9893` on node 1 and `9894` on node 2.
   - Give each node a unique `wso2.carbon.id` (`si-node-1`, `si-node-2`).
4. On node 2 only, set `wso2.carbon.ports.offset: 1` so the two nodes don't clash on ports.
5. Create the table:
   ```bash
   docker exec si-test-mysql mysql -usitest -psitest123 si_test_db \
     -e "CREATE TABLE IF NOT EXISTS CronTicks (triggered_time BIGINT, node VARCHAR(20));"
   ```
6. Put this app in `deployment/siddhi-files/` on both nodes, with `node` set to `n1` on node 1 and `n2` on node 2:
   ```sql
   @App:name('HACronTrigger')
   define trigger T at '*/10 * * * * ?';

   @store(type='rdbms',
          jdbc.url='jdbc:mysql://localhost:3307/si_test_db?useSSL=false&allowPublicKeyRetrieval=true',
          username='sitest', password='sitest123', jdbc.driver.name='com.mysql.cj.jdbc.Driver')
   define table CronTicks (triggered_time long, node string);

   @sink(type='log', prefix='[HA-CRON]')
   define stream TickStream (triggered_time long, node string);

   from T select triggered_time, 'n1' as node insert into TickStream;
   from TickStream insert into CronTicks;
   ```
7. Start node 1 and wait for `Successfully Changed to Active Mode`. Then start node 2 and wait for `Successfully Changed to Passive Mode`.

Use this query to watch the rows:
```bash
docker exec si-test-mysql mysql -usitest -psitest123 si_test_db \
  -e "SELECT node, COUNT(*), FROM_UNIXTIME(MAX(triggered_time)/1000) FROM CronTicks GROUP BY node;"
```

## Steps and expected results

| # | Action | Expected |
|---|---|---|
| 1 | Wait 1 minute | About 6 new `n1` rows. `[HA-CRON]` appears in node 1's log only. |
| 2 | `docker stop si-test-mysql`, wait 2–5 minutes | Both nodes log coordination/heartbeat errors, and a node may change state. Inserts fail while the DB is down. |
| 3 | `docker start si-test-mysql`, wait 1 minute | Exactly one node logs `Successfully Changed to Active Mode`, and rows resume every 10 s from that node. The passive node logs no `[HA-CRON]` lines. |
| 4 | Kill the active node (`kill -9 $(cat <node>/wso2/server/runtime.pid)`) | Within about 10–20 s the other node logs `Successfully Changed to Active Mode`, and rows resume from it. |
| 5 | Restart the killed node | It joins as passive and logs no `[HA-CRON]` lines. |
| 6 | Repeat steps 2–5 three times | After every cycle, rows keep arriving from whichever node is active, with no gap longer than the outage itself. |

On the passive node, `jstack $(cat <node>/wso2/server/runtime.pid) | grep -c DefaultQuartzScheduler_Worker` should be `0` once it has changed to passive mode, because its app runtimes are shut down and no cron job is left.
