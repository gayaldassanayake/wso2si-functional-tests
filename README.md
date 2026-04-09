# WSO2 Streaming Integrator — Functional Test Suite

A self-contained regression test suite for WSO2 Streaming Integrator (SI) 4.3.2. It covers 18 functional areas using Siddhi apps, Docker Compose for infrastructure dependencies, and shell scripts that send events, scan SI logs, and query the Store API to produce clear PASS/FAIL output.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Directory Structure](#directory-structure)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Test Cases](#test-cases)
- [Running Tests](#running-tests)
  - [Core tests (no external infrastructure)](#core-tests-no-external-infrastructure)
  - [With MySQL](#with-mysql)
  - [With Kafka](#with-kafka)
  - [Full suite](#full-suite)
  - [Running individual test cases](#running-individual-test-cases)
- [Infrastructure Setup](#infrastructure-setup)
  - [Starting services](#starting-services)
  - [Stopping services](#stopping-services)
  - [MySQL JDBC driver](#mysql-jdbc-driver)
  - [Kafka OSGi jars](#kafka-osgi-jars)
- [Deploying Siddhi Apps](#deploying-siddhi-apps)
- [Teardown](#teardown)
- [How Assertions Work](#how-assertions-work)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Details |
|---|---|
| WSO2 SI 4.3.2 binary | Installed and configured. The server must be startable before running tests. |
| `bash` ≥ 3.2 | macOS system bash is sufficient. |
| `curl` | For posting events to SI HTTP sources and querying the Store API. |
| `nc` (netcat) | Pre-flight check that SI ports are open. Available by default on macOS and most Linux distros. |
| `python3` | Used to parse Store API JSON responses and compute timestamps. |
| Docker + Docker Compose | Required only for TC07 (MySQL), TC08 (Kafka), TC11 (CDC). The 15 core tests need no Docker. |

---

## Directory Structure

```
test-suite/
│
├── config.env                   ← All configurable variables. Edit SI_HOME here.
├── run_all_tests.sh             ← Top-level test orchestrator
│
├── siddhi-apps/                 ← 18 Siddhi applications (one per test case)
│   ├── TC01_PassThrough.siddhi
│   ├── TC02_HttpIngest.siddhi
│   ├── ...
│   └── TC18_ErrorHandling.siddhi
│
├── infra/
│   ├── docker-compose.yml       ← Kafka + Zookeeper + MySQL 8.0
│   └── mysql-init/
│       └── 01_init.sql          ← Creates cdc_test_table for TC11 on first start
│
└── scripts/
    ├── lib/
    │   └── common.sh            ← Shared helpers (post_event, store_query, wait_for_log, ...)
    ├── setup.sh                 ← Start Docker Compose services and wait for healthy
    ├── deploy.sh                ← Copy Siddhi apps to SI deployment directory
    ├── teardown.sh              ← Remove deployed apps and stop Docker services
    ├── test_tc01_passthrough.sh
    ├── test_tc02_http_ingest.sh
    ├── ...
    └── test_tc18_error_handling.sh
```

---

## Quick Start

```bash
# 1. Set your SI installation path
export SI_HOME=/path/to/wso2si-4.3.2

# 2. Start Docker infrastructure (Kafka + Zookeeper + MySQL)
./scripts/setup.sh --all

# 3. Copy the MySQL JDBC driver and Kafka OSGi JARs into SI
#    MySQL: download mysql-connector-j-8.x.x.jar from https://dev.mysql.com/downloads/connector/j/
cp mysql-connector-j-8.x.x.jar ${SI_HOME}/lib/
#    Kafka: convert Kafka 2.11 client JARs to OSGi using jartobundle.sh, then copy to lib/
cp kafka-clients-*.jar ${SI_HOME}/lib/

# 4. Start the SI server (in a separate terminal)
${SI_HOME}/bin/server.sh
# Wait until you see: "WSO2 Streaming Integrator started"

# 5. Run the full test suite (all 18 test cases including Kafka and MySQL)
./run_all_tests.sh --all
```

---

## Configuration

Edit `config.env` before running tests, or export variables inline:

```bash
# Edit once
nano config.env   # set SI_HOME

# Or pass inline per run
SI_HOME=/opt/wso2si-4.3.2 ./run_all_tests.sh
```

Key settings:

| Variable | Default | Description |
|---|---|---|
| `SI_HOME` | `/path/to/wso2si-4.3.2` | **Must be set.** Path to your installed SI binary. |
| `SI_SIDDHI_DIR` | `${SI_HOME}/wso2/server/deployment/siddhi-files` | Where SI picks up Siddhi apps. |
| `SI_LOG` | `${SI_HOME}/wso2/server/logs/carbon.log` | SI server log file for assertions. |
| `SI_HTTP_PORT` | `9090` | SI management HTTP port. |
| `SI_STORE_API_PORT` | `7070` | Store Query API port. |
| `DEPLOY_WAIT_SECONDS` | `8` | Seconds to wait after copying apps before running tests. Increase on slow machines. |
| `MYSQL_USER` / `MYSQL_PASS` | `sitest` / `sitest123` | Credentials created by Docker Compose. |
| `FILE_SOURCE_PATH` | `/tmp/si-test-sales.csv` | File used by TC12. Must be writable by both the test script and the SI server process. |

HTTP source ports (each Siddhi app binds to a unique port to allow all apps to run simultaneously):

| TC | Port |
|---|---|
| TC01 | 8099 |
| TC02 | 8100 |
| TC03 | 8101 |
| TC04 | 8102 |
| TC05 | 8103 |
| TC06 | 8104 |
| TC07 | 8105 |
| TC09 | 8106 |
| TC10 | 8107 |
| TC13 | 8108 |
| TC14 | 8109 |
| TC15 | 8110 |
| TC16 | 8111 |
| TC17 | 8112 |
| TC18 | 8113 |

TC08 uses Kafka (no HTTP port). TC11 uses CDC source. TC12 uses file source.

---

## Test Cases

| TC | Siddhi App | Feature Area | External Deps |
|---|---|---|---|
| TC01 | `TC01_PassThrough.siddhi` | HTTP source → log sink (baseline) | none |
| TC02 | `TC02_HttpIngest.siddhi` | HTTP ingest, in-memory table, upsert, Store API | none |
| TC03 | `TC03_WindowAggregation.siddhi` | `#window.time()`, `#window.lengthBatch()`, sum/avg/count | none |
| TC04 | `TC04_FilterTransform.siddhi` | Filter predicates, `str:upper/lower/concat`, `math:round` | none |
| TC05 | `TC05_PatternDetect.siddhi` | Sequential pattern `->`, `within` clause | none |
| TC06 | `TC06_StoreAndQuery.siddhi` | Store Query API (200/404/400/500 paths) | none |
| TC07 | `TC07_MySQLPersist.siddhi` | `@store(type='rdbms')` MySQL persistence, JDBC | MySQL |
| TC08 | `TC08_KafkaPassThrough.siddhi` | Kafka source + filtered Kafka sink, JSON over Kafka | Kafka |
| TC09 | `TC09_IncrementalAggregation.siddhi` | `define aggregation ... every sec...min`, `within/per` retrieval | none |
| TC10 | `TC10_StreamTableJoin.siddhi` | Stream-to-table join, data enrichment, left outer join | none |
| TC11 | `TC11_CDCPolling.siddhi` | CDC source in polling mode (MySQL change detection) | MySQL |
| TC12 | `TC12_FileSource.siddhi` | File source, `mode=LINE`, `tailing=true`, CSV mapping | none |
| TC13 | `TC13_Sequence.siddhi` | Sequence operator `,` (consecutive event detection) | none |
| TC14 | `TC14_NonOccurrence.siddhi` | Non-occurrence `not ... for 15 sec` (missing heartbeat) | none |
| TC15 | `TC15_FormatTransform.siddhi` | XML XPath mapping, JSON custom `@attributes`, CSV source | none |
| TC16 | `TC16_TimeFunctions.siddhi` | `time:dateFormat`, `time:dateAdd`, `time:timestampInMilliseconds` | none |
| TC17 | `TC17_RegexFunctions.siddhi` | `regex:find`, `regex:matches`, `regex:group` for log parsing | none |
| TC18 | `TC18_ErrorHandling.siddhi` | `regex:matches()` numeric validation, valid vs invalid event routing | none |

---

## Running Tests

### Core tests (no external infrastructure)

Runs TC01–TC06, TC09, TC10, TC12–TC18 (15 test cases):

```bash
./run_all_tests.sh
```

### With MySQL

Adds TC07 (RDBMS store) and TC11 (CDC polling):

```bash
# Start MySQL first
./scripts/setup.sh --mysql

# Then run
./run_all_tests.sh --with-mysql
```

### With Kafka

Adds TC08 (Kafka source + sink):

```bash
./scripts/setup.sh --kafka
./run_all_tests.sh --with-kafka
```

### Full suite

All 18 test cases:

```bash
./scripts/setup.sh --all
./run_all_tests.sh --all
```

### Running individual test cases

Pass TC numbers to run only those cases. Apps are deployed automatically:

```bash
# Single test case
./run_all_tests.sh TC05

# Multiple test cases
./run_all_tests.sh TC03 TC09 TC13

# Skip deployment if apps are already deployed
./run_all_tests.sh --skip-deploy TC06
```

You can also run a test script directly (apps must already be deployed):

```bash
./scripts/test_tc06_store_query.sh
```

---

## Infrastructure Setup

### Starting services

```bash
# Start Kafka + Zookeeper only
./scripts/setup.sh --kafka

# Start MySQL only
./scripts/setup.sh --mysql

# Start everything
./scripts/setup.sh --all
```

`setup.sh` will:
1. Run `docker compose up -d` for the requested services.
2. Poll every 5 seconds until all containers report `healthy` (120 second timeout).
3. Create the Kafka topics `si-test-input` and `si-test-output` (if Kafka was started).
4. Verify MySQL database connectivity.
5. Warn if the MySQL JDBC driver JAR is missing from `${SI_HOME}/lib/`.

### Stopping services

```bash
./scripts/teardown.sh --all
```

This also removes any deployed TC Siddhi apps from the SI deployment directory.

### MySQL JDBC driver

TC07 and TC11 require the MySQL Connector/J JAR to be present in `${SI_HOME}/lib/`. The SI distribution does not bundle it.

1. Download `mysql-connector-j-8.x.x.jar` from the [MySQL Downloads page](https://dev.mysql.com/downloads/connector/j/).
2. Place it in `${SI_HOME}/lib/`.
3. Restart the SI server.

`setup.sh --mysql` will warn you if the JAR is missing.

### Kafka OSGi jars

TC08 requires Kafka client JARs converted to OSGi bundles in `${SI_HOME}/lib/`. Follow the prerequisite steps documented in the existing `WorkingWithKafka/HelloKafka.siddhi` sample:

```
product-streaming-integrator/modules/samples/artifacts/WorkingWithKafka/HelloKafka.siddhi
```

The steps involve downloading Kafka 2.11, converting client JARs with `jartobundle.sh`, and placing the results in `${SI_HOME}/lib/`.

---

## Deploying Siddhi Apps

`run_all_tests.sh` deploys apps automatically. You can also deploy manually:

```bash
# Core apps (TC01–TC06, TC09–TC10, TC12–TC18)
./scripts/deploy.sh --core

# Add Kafka app
./scripts/deploy.sh --kafka

# Add MySQL apps
./scripts/deploy.sh --mysql

# Everything at once
./scripts/deploy.sh --all

# Specific apps by TC number
./scripts/deploy.sh TC05 TC09 TC13
```

`deploy.sh` copies the selected `.siddhi` files to `${SI_SIDDHI_DIR}` and waits `DEPLOY_WAIT_SECONDS` for SI's artifact scanner to pick them up. It also creates `/tmp/si-test-sales.csv` (empty) for TC12 if it does not exist.

After deployment, confirm all apps started successfully in the SI log:

```bash
tail -f ${SI_HOME}/wso2/server/logs/carbon.log | grep -E "Started Successfully|Exception"
```

---

## Teardown

```bash
# Remove deployed Siddhi apps only (leave Docker running)
./scripts/teardown.sh

# Remove apps + stop Kafka
./scripts/teardown.sh --kafka

# Remove apps + stop MySQL
./scripts/teardown.sh --mysql

# Full cleanup
./scripts/teardown.sh --all
```

---

## How Assertions Work

Each test script uses three assertion mechanisms, all implemented in `scripts/lib/common.sh`:

**1. Log scanning (`wait_for_log` / `assert_log_contains`)**

Every Siddhi app uses a `log` sink with a unique prefix (e.g., `[TC05-ALERT]`). The test polls the SI log file (`carbon.log`) every second for up to a configurable timeout, looking for a regex pattern. This is the primary assertion for stream processing results.

```
assert_log_contains "description" '\[TC05-ALERT\].*userId' 15
```

**2. Store API queries (`assert_store_count`)**

For table-backed results, tests query the SI Store API at `http://localhost:7070/stores/query` and assert the number of records returned. This independently verifies that table writes happened.

```
assert_store_count "3 records in table" "AppName" "from MyTable select *" 3
```

**3. MySQL row counts (`assert_mysql_count`)**

For TC07 and TC11 (RDBMS-backed tables), tests run SQL directly inside the MySQL Docker container via `docker exec` to confirm persistence end-to-end, independent of the SI Store API.

```
assert_mysql_count "3 rows in MySQL" "InventoryTable" 3
```

**Negative assertions** use two techniques depending on context. The simpler approach (`assert_log_not_contains`) sleeps briefly then checks the recent log tail for absence. Where stale log entries from prior runs could cause false passes (e.g., TC14 T3, TC18 T3), a log-baseline approach is used instead: record the line count before the action (`LOG_BASELINE=$(wc -l < "${SI_LOG}")`), then check only new lines (`tail -n +"$((LOG_BASELINE + 1))"`). Both are used in pattern tests (TC05, TC13, TC14, TC18) to confirm non-matching events produce no incorrect output.

---

## Troubleshooting

**"SI is not running on port 9090"**
The SI server is not started or not yet ready. Run `${SI_HOME}/bin/server.sh` and wait for the startup message before running tests.

**"Siddhi deployment directory not found"**
`SI_HOME` in `config.env` points to the wrong location, or SI is not installed. Verify the path:
```bash
ls ${SI_HOME}/wso2/server/deployment/siddhi-files
```

**Test times out waiting for log pattern**
- Increase `DEPLOY_WAIT_SECONDS` in `config.env` if apps are slow to start.
- Check the SI log for startup errors: `tail -100 ${SI_LOG} | grep -i error`
- Confirm the expected app started: `grep "Started Successfully" ${SI_LOG}`

**TC07/TC11 fail with ClassNotFoundException**
The MySQL JDBC driver JAR is missing from `${SI_HOME}/lib/`. See [MySQL JDBC driver](#mysql-jdbc-driver).

**TC08 fails with "Kafka broker not available"**
Either the Kafka Docker container is not running (`./scripts/setup.sh --kafka`) or the Kafka OSGi JARs are not in `${SI_HOME}/lib/`.

**TC14 takes 25+ seconds**
This is expected. TC14 tests a 15-second non-occurrence window, so the test waits for the window to expire. It is the slowest test by design.

**Store API returns unexpected record counts between runs**
In-memory tables persist for the lifetime of the SI server process. If you ran tests previously without restarting SI, old data may still be in tables. Restart the SI server between full test runs for a clean state, or use `--skip-deploy` and rely on the upsert semantics to overwrite existing records.

**"docker compose: command not found"**
Try `docker-compose` (with a hyphen) if you have the older CLI. The scripts use `docker compose` (the newer plugin form). You can add an alias: `alias docker-compose='docker compose'`.
