# WSO2 Streaming Integrator — Functional Test Suite

A self-contained regression test suite for WSO2 Streaming Integrator (SI) 4.3.x / 4.4.x. It covers:

- **29 SI functional tests** (TC01–TC18, TC40–TC42, TC44, TC47, TC50–TC51, TC57, TC59, TC63, TC66–TC67) — Siddhi apps, Docker Compose infrastructure, HTTP event injection, log scanning, Store API queries, file sink, gRPC, HTTP request/response, XML emit, JavaScript functions, cron triggers, keywords as attribute names,, file search with a dynamic regex, the map extension's JSON and XML functions, and the HTTP sink's OAuth 2.0 token refresh.
- **9 Helm chart tests** (TC19–TC27) — template rendering and lint validation for the updated `helm-si` chart with Gateway API support. No cluster required.
- **7 Kubernetes live tests** (TC28–TC34) — end-to-end validation of the Gateway API resources on a live cluster using Envoy Gateway.
- **5 distribution tool tests** (TC35–TC38, TC53) — server lifecycle, `jartobundle.sh`, `osgi-lib.sh`, `ciphertool.sh`, dependency version floors.
- **2 PostgreSQL CDC tests** (TC48, TC49) — listening mode via Debezium logical replication, and polling mode.
- **1 Oracle LDAP naming test** (TC52) — RDBMS store on Oracle reached through a `jdbc:oracle:thin:@ldap://` URL.
- **1 Kafka `deployment.yaml` config test** (TC56, standalone) — Kafka source/sink options set globally under `siddhi.extensions`.
- **2 Avro over Kafka tests** (TC58, TC64) — `siddhi-map-avro` sink and source mapping of binary Kafka messages, with an inline schema and with a Confluent Schema Registry.
- **1 SMB file test** (TC65) — `siddhi-io-file` sink and `dir.uri` source on an SMB share, over `smb://` and `smb2://`.
- **1 CDC listening test** (TC39) — MySQL CDC via Debezium binlog (INSERT/UPDATE/DELETE events).
- **3 optional extension tests** (TC43, TC45, TC46) — Thrift DataBridge, RabbitMQ pass-through, Redis store. TC45 and TC46 self-skip when the required SI extension JARs are absent; TC43 installs its own (see below).

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
  - [With Samba](#with-samba)
  - [With Kafka](#with-kafka)
  - [Helm chart tests (no cluster required)](#helm-chart-tests-no-cluster-required)
  - [Kubernetes live tests](#kubernetes-live-tests)
  - [Distribution tool tests (TC35–TC42)](#distribution-tool-tests-tc35tc42)
  - [Full suite](#full-suite)
  - [Running individual test cases](#running-individual-test-cases)
- [Infrastructure Setup](#infrastructure-setup)
  - [Starting Docker services](#starting-docker-services)
  - [Stopping Docker services](#stopping-docker-services)
  - [MySQL JDBC driver](#mysql-jdbc-driver)
  - [Kafka OSGi jars](#kafka-osgi-jars)
- [Kubernetes Setup (TC28–TC34)](#kubernetes-setup-tc28tc34)
  - [Prerequisites](#kubernetes-prerequisites)
  - [Install Envoy Gateway](#install-envoy-gateway)
  - [Deploy WSO2 SI](#deploy-wso2-si)
  - [Kubernetes teardown](#kubernetes-teardown)
- [Deploying Siddhi Apps](#deploying-siddhi-apps)
- [Teardown](#teardown)
- [How Assertions Work](#how-assertions-work)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### SI functional tests (TC01–TC18) and binary/tool tests (TC35–TC42)

| Requirement | Details |
|---|---|
| WSO2 SI pack under test | Extracted and configured. The server must be startable before running tests. |
| `bash` ≥ 3.2 | macOS system bash is sufficient. |
| `curl` | For posting events to SI HTTP sources and querying the Store API. |
| `nc` (netcat) | Pre-flight check that SI ports are open. Available by default on macOS and most Linux distros. |
| `python3` | Used to parse Store API JSON responses and compute timestamps. |
| Docker + Docker Compose | Required only for TC07 (MySQL), TC08 (Kafka), TC11 (CDC). The 15 core tests need no Docker. |

### Helm chart tests (TC19–TC27)

| Requirement | Details |
|---|---|
| `helm` ≥ 3.14 | Used to render and lint the `helm-si` chart. |
| `helm-si` chart | Cloned locally. Default path: `/Users/nipunal/work/repositories/support-rotation/helm-si`. Override with `HELM_SI_CHART=...`. |

No running Kubernetes cluster is needed for TC19–TC27.

### Kubernetes live tests (TC28–TC34)

| Requirement | Details |
|---|---|
| `kubectl` | Configured to reach the target cluster. |
| `helm` ≥ 3.14 | Used to install Envoy Gateway and deploy WSO2 SI. |
| `openssl` | Generates the self-signed TLS certificate for the Gateway listener. |
| Kubernetes cluster | Any cluster with Gateway API CRDs installed. Tested on Rancher Desktop (k3s v1.33.5). |
| Envoy Gateway v1.3.2 | Installed by `scripts/k8s/setup_envoy_gateway.sh` (see [Kubernetes Setup](#kubernetes-setup-tc28tc34)). |
| Internet access | The setup pulls `docker.io/wso2/wso2si:4.3.0-ubuntu` (~627 MB) and the Envoy Gateway images. |

---

## Directory Structure

```
wso2si-functional-tests/
│
├── config.env                        ← All configurable variables (SI_HOME, HELM_SI_CHART, K8s settings)
├── run_all_tests.sh                  ← Top-level test orchestrator
├── GATEWAY_API_TEST_REPORT.md        ← Full test report for Gateway API changes
│
├── siddhi-apps/                      ← Siddhi applications for TC01–TC18 and TC39–TC42
│   ├── TC01_PassThrough.siddhi
│   ├── ...
│   ├── TC18_ErrorHandling.siddhi
│   ├── TC39_CDCListening.siddhi
│   ├── TC40_FileSink.siddhi
│   ├── TC41_GrpcServer.siddhi
│   ├── TC41_GrpcClient.siddhi
│   ├── TC42_GrpcConsume.siddhi
│   └── TC42_GrpcSender.siddhi
│
├── infra/
│   ├── docker-compose.yml            ← Kafka + Zookeeper + Schema Registry + MySQL 8.0 + PostgreSQL 16
│   ├── mysql-init/
│   │   └── 01_init.sql
│   └── postgres-init/
│       └── 01_init.sql               ← wal_level tables, REPLICA IDENTITY FULL, publication
│
└── scripts/
    ├── lib/
    │   └── common.sh                 ← Shared helpers: SI, Helm, and K8s assertion functions
    │
    ├── setup.sh                      ← Start Docker Compose services
    ├── deploy.sh                     ← Copy Siddhi apps to SI deployment directory
    ├── teardown.sh                   ← Remove apps and stop Docker services
    │
    ├── k8s/                          ← Kubernetes setup/teardown scripts
    │   ├── setup_envoy_gateway.sh    ← Install Envoy Gateway + create GatewayClass
    │   ├── setup_si.sh               ← Create namespace, TLS secret, deploy SI Helm chart
    │   └── teardown_k8s.sh           ← Delete K8s namespace (and optionally Envoy Gateway)
    │
    ├── test_tc01_passthrough.sh      ─┐
    ├── ...                            │ TC01–TC18: SI functional tests
    ├── test_tc18_error_handling.sh   ─┘
    │
    ├── test_tc19_helm_lint_defaults.sh        ─┐
    ├── ...                                     │ TC19–TC27: Helm chart template tests
    ├── test_tc27_mutual_exclusion.sh          ─┘
    │
    ├── test_tc28_k8s_resources_created.sh     ─┐
    ├── ...                                     │ TC28–TC34: Kubernetes live tests
    ├── test_tc34_k8s_rate_limit.sh            ─┘
    │
    ├── test_tc35_server_lifecycle.sh          ─┐ TC35: standalone (run before starting SI)
    ├── test_tc36_jartobundle.sh               │
    ├── test_tc37_osgi_lib.sh                  │ TC36–TC38: distribution tool tests (--with-tools)
    ├── test_tc38_ciphertool.sh               ─┘
    │
    ├── test_tc39_cdc_listening.sh             ─┐ TC39: MySQL CDC listening (Debezium)
    ├── test_tc40_file_sink.sh                  │ TC40–TC42: CORE_TCS (run with standard SI)
    ├── test_tc41_grpc_echo.sh                  │
    └── test_tc42_grpc_consume.sh             ─┘
```

---

## Quick Start

### SI functional tests (TC01–TC18)

```bash
# 1. Set your SI installation path
export SI_HOME=/path/to/wso2si-<version>

# 2. Start Docker infrastructure (Kafka + Zookeeper + MySQL)
./scripts/setup.sh --all

# 3. Copy the MySQL JDBC driver and Kafka OSGi JARs into SI
cp mysql-connector-j-8.x.x.jar ${SI_HOME}/lib/
cp kafka-clients-*.jar ${SI_HOME}/lib/

# 4. Start the SI server (in a separate terminal)
${SI_HOME}/bin/server.sh
# Wait until you see: "WSO2 Streaming Integrator started"

# 5. Run all 18 SI functional test cases
./run_all_tests.sh --all
```

### Distribution tool tests (TC35–TC42)

TC35 is standalone and must run before starting the SI server. TC36–TC38 test distribution tools:

```bash
# 1. Point to the pack under test (TOOLS_PACK_HOME defaults to SI_HOME)
export SI_HOME=/path/to/wso2si-<version>

# 2. Run the standalone server lifecycle test (stop any running SI server first)
bash scripts/test_tc35_server_lifecycle.sh

# 3. Run tool tests (jartobundle, osgi-lib, ciphertool)
./run_all_tests.sh --with-tools

# TC39-TC42 run automatically with --all or --with-mysql (after starting SI)
```

TC39 requires MySQL; TC40–TC42 need only a running SI server (included in --all).

### Helm chart tests (TC19–TC27, no cluster needed)

```bash
# Set the path to the helm-si chart
export HELM_SI_CHART=/path/to/helm-si

./run_all_tests.sh --with-helm
```

### Kubernetes live tests (TC28–TC34)

```bash
# 1. Install Envoy Gateway and create the GatewayClass
bash scripts/k8s/setup_envoy_gateway.sh

# 2. Deploy WSO2 SI with Gateway API config
bash scripts/k8s/setup_si.sh

# 3. Run the live K8s tests (SI pod takes ~3 min to become Ready)
./run_all_tests.sh --with-k8s
```

---

## Configuration

Edit `config.env` before running tests, or export variables inline:

```bash
# Edit once
nano config.env   # set SI_HOME

# Or pass inline per run
SI_HOME=/opt/wso2si-<version> ./run_all_tests.sh
```

Key settings:

**SI functional tests**

| Variable | Default | Description |
|---|---|---|
| `SI_HOME` | none | **Must be set.** The extracted pack under test. The runner and every SI test check that the server on `SI_HTTP_PORT` was started from this pack. |
| `TOOLS_PACK_HOME` | `${SI_HOME}` | Pack that TC35–TC38 and TC53 inspect. Set it only to check a different pack on purpose; the runner warns when it differs. |
| `SI_SIDDHI_DIR` | `${SI_HOME}/wso2/server/deployment/siddhi-files` | Where SI picks up Siddhi apps. |
| `SI_LOG` | `${SI_HOME}/wso2/server/logs/carbon.log` | SI server log file for assertions. |
| `SI_HTTP_PORT` | `9090` | SI management HTTP port. Override it, with `SI_STORE_API_PORT`, to test a second pack whose `deployment.yaml` uses other ports. |
| `SI_STORE_API_PORT` | `7070` | Store Query API port. |
| `DEPLOY_WAIT_SECONDS` | `8` | Seconds to wait after copying apps before running tests. Increase on slow machines. |
| `MYSQL_USER` / `MYSQL_PASS` | `sitest` / `sitest123` | Credentials created by Docker Compose. |
| `FILE_SOURCE_PATH` | `/tmp/si-test-sales.csv` | File used by TC12. Must be writable by both the test script and the SI server process. |

**Helm chart tests**

| Variable | Default | Description |
|---|---|---|
| `HELM_SI_CHART` | `/Users/nipunal/work/repositories/support-rotation/helm-si` | Path to the `helm-si` chart directory. |

**Kubernetes live tests**

| Variable | Default | Description |
|---|---|---|
| `K8S_TEST_NAMESPACE` | `wso2-si-k8s-test` | Namespace used for the SI deployment. |
| `K8S_RELEASE_NAME` | `si-k8s-test` | Helm release name for SI. |
| `K8S_HOSTNAME` | `si.wso2.com` | Hostname used in the Gateway listener and HTTPRoute. |
| `K8S_TLS_SECRET` | `si-gateway-tls` | Name of the TLS Secret created by `setup_si.sh`. |
| `K8S_GATEWAY_NAME` | `si-gateway` | Name of the Gateway resource. |
| `K8S_GATEWAY_CLASS` | `eg` | GatewayClass name (Envoy Gateway default). |
| `K8S_GATEWAY_PORT` | `8443` | Gateway listener port. Use a port not already taken on your node (443 conflicts with Traefik on k3s/Rancher Desktop). |
| `K8S_ENVOY_NS` | `envoy-gateway-system` | Namespace where Envoy Gateway is installed. |
| `K8S_POD_TIMEOUT` | `360` | Seconds to wait for the SI pod to become Ready (probe delay is 180 s). |

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

TC08 uses Kafka (no HTTP port). TC11 uses CDC source. TC12 uses file source. TC39 uses CDC source (no HTTP port). TC40–TC47 use the ports below.

| TC | Port | Notes |
|---|---|---|
| TC40 | 8114 | |
| TC41 | 8115 | + gRPC port 8283 (grpc-service) |
| TC42 | 8116 | + gRPC port 8183 (grpc consume) |
| TC43 | — | Thrift TCP 7611 / SSL 7711 (SI DataBridge ports) |
| TC44 | 8119 | + echo port 8120 (http-service self-loop) |
| TC46 | 8121 | |
| TC47 | 8122 | + echo port 8123 (XML self-loop receiver) |
| TC50 | 8124 | JavaScript script function |
| TC51 | 8125 | JavaScript `js:eval` |
| TC52 | 8126 | Oracle store via LDAP naming |
| TC58 | 8128 | Avro over Kafka (HTTP source) |
| TC59 | 8129 | Keywords as attribute names |
| TC63 | 8133 | File search with a dynamic regex |
| TC64 | 8134 | Avro with a Confluent Schema Registry (HTTP source) |
| TC65 | 8135, 8136 | SMB file sink and source, `smb://` and `smb2://` (HTTP source) |
| TC66 | 8137 | Map extension JSON and XML functions |
| TC67 | 8140 | HTTP sink with OAuth 2.0 (HTTP source) + OAuth mock 8141 |
| TC60 | 8130 | Oracle error store (HTTP source) + receiver 8131 |
| TC61 | 8132 | Table statistics (HTTP source); own MySQL on 3309 |

---

## Test Cases

### SI Functional Tests (TC01–TC18)

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

### Helm Chart Tests — Gateway API (TC19–TC27)

These tests validate the updated `helm-si` chart's Gateway API support using `helm template` and `helm lint`. No running cluster is required.

| TC | Script | What is tested |
|---|---|---|
| TC19 | `test_tc19_helm_lint_defaults.sh` | `helm lint` passes across all three config modes |
| TC20 | `test_tc20_ingress_only_default.sh` | Default chart renders Ingress only — no Gateway API resources |
| TC21 | `test_tc21_gateway_api_enabled.sh` | Gateway, HTTPRoute render correctly; Ingress suppressed |
| TC22 | `test_tc22_required_tls_secret.sh` | Empty `tlsSecret` when `gateway.create=true` fails fast with a clear error |
| TC23 | `test_tc23_backward_compat.sh` | Values file without `gatewayApi` key (pre-upgrade scenario) renders Ingress without error |
| TC24 | `test_tc24_external_gateway_ref.sh` | `gateway.create=false` omits Gateway; HTTPRoute references external namespace |
| TC25 | `test_tc25_backend_tls_policy.sh` | `BackendTLSPolicy` API version, `sectionName: management`, CA cert and hostname overrides |
| TC26 | `test_tc26_rate_limit_policy.sh` | `BackendTrafficPolicy` Envoy API group, `type: Local`, `requests`/`unit` values |
| TC27 | `test_tc27_mutual_exclusion.sh` | `gatewayApi.enabled=true` takes precedence over `ingress.enabled=true` |

### Distribution Tool Tests (TC35–TC38)

TC35 is **standalone** — it starts and stops the SI server itself and must run *before* the main SI instance is started.

TC36–TC38 test the WSO2 SI distribution tools. They inspect `TOOLS_PACK_HOME` (defaults to `SI_HOME`), which must contain `bin/jartobundle.sh`, `bin/osgi-lib.sh`, and `bin/ciphertool.sh`.

**Note:** `osgi-lib.sh` and `ciphertool.sh` reject JDK versions above 11. TC37 and TC38 automatically override `JAVA_HOME` to a JDK 11 installation at `/Library/Java/JavaVirtualMachines/graalvm-ce-java11-22.3.0/Contents/Home` when the active JDK is newer. If that path does not exist, the test self-skips.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC35 | `test_tc35_server_lifecycle.sh` | `server.sh` start/stop, JDK compatibility check | None (STANDALONE) |
| TC36 | `test_tc36_jartobundle.sh` | `jartobundle.sh` — JAR to OSGi bundle conversion | `TOOLS_PACK_HOME` |
| TC37 | `test_tc37_osgi_lib.sh` | `osgi-lib.sh` — register new bundle in `bundles.info` | `TOOLS_PACK_HOME` |
| TC38 | `test_tc38_ciphertool.sh` | `ciphertool.sh` — encrypt/decrypt round-trip | `TOOLS_PACK_HOME` |
| TC53 | `test_tc53_dependency_floors.sh` | Netty/Jackson security floors (`NETTY_MIN_VERSION`, `JACKSON_MIN_VERSION`), no duplicate versions, no dangling `bundles.info` entries, snappy-java and Avro embedded in `siddhi-map-avro` (`AVRO_MIN_VERSION`), no `lib/` bundle importing `com.google.gson.internal`, no `lib/` bundle embedding Gson (siddhi-io-kafka only warns), log4j embedded in pax-logging at or above `LOG4J_MIN_VERSION`, every bundle the launcher loads by filename present in `wso2/lib/plugins`, extension installer's kafka-clients/kafka_2.13 at or above `KAFKA_CLIENTS_MIN_VERSION`, no feign, okhttp3, okio or org.json classes embedded in `siddhi-map-avro`, commons-beanutils at or above `BEANUTILS_MIN_VERSION` and no ServiceMix beanutils bundle, exactly one libthrift bundle at or above `LIBTHRIFT_MIN_VERSION` with every `org.apache.thrift` import requiring it, no Jackson 1.x classes embedded in `siddhi-io-kafka`, commons-lang3 with the CVE-2025-48924 fix and org.json with the CVE-2023-5072 fix embedded in `siddhi-execution-map`, exactly one platform org.json bundle, and one with the CVE-2022-45688 and CVE-2023-5072 fixes | `TOOLS_PACK_HOME` |

### CDC Listening Test (TC39)

TC39 requires MySQL with Debezium-compatible binlog privileges (granted automatically by `infra/mysql-init/01_init.sql`).

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC39 | `test_tc39_cdc_listening.sh` | CDC listening mode (Debezium binlog) INSERT/UPDATE/DELETE | MySQL |

### Table Statistics Test (TC61)

Covers BNYMDMAPROD-231. With statistics on, a table operation that throws must still close its latency tracker; otherwise the next event on that thread fails with `MarkIn consecutively called without calling markOut`. TC61 starts its own MySQL container (`si-test-mysql-tc61`, port 3309) because it stops the database mid-test. It runs in the MySQL group.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC61 | `test_tc61_table_stats_markin.sh` | `@app:statistics` with an RDBMS `@PrimaryKey` table: inserts, duplicate inserts, upserts, deletes, and a MySQL outage | MySQL JDBC driver in `lib/`, Docker |

Checks: statistics are enabled; duplicate-key failures occur; no `MarkIn consecutively` error is logged; writes resume after the outage; the app still processes events and the last upsert lands.

### PostgreSQL CDC Tests (TC48, TC49)

TC48 covers the gap flagged in [siddhi-io-cdc PR #101](https://github.com/siddhi-io/siddhi-io-cdc/pull/101): Debezium 3.6.1 calls `ChainedCommonStreamBuilder.withAutomaticFlush(boolean)`, which pgjdbc only gained in **42.7.11**. The PostgreSQL driver is user-supplied, so an older one fails at streaming start with `NoSuchMethodError`.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC48 | `test_tc48_pg_cdc_listening.sh` | PostgreSQL CDC listening (Debezium logical replication) INSERT/UPDATE/DELETE | PostgreSQL, pgjdbc 42.7.11+ |
| TC49 | `test_tc49_pg_cdc_polling.sh` | PostgreSQL CDC polling mode | PostgreSQL, pgjdbc |

**Driver handling.** TC48 checks the jar for `withAutomaticFlush` directly rather than parsing its version string, because a repackaged or vendor jar can carry a misleading filename. Behaviour:

- driver **absent** → both tests self-skip (the TC43/TC45/TC46 convention)
- driver **present but too old** → TC48 **fails** with an explicit message naming the pgjdbc requirement, instead of surfacing a bare `NoSuchMethodError`
- driver **present and new enough** → the tests run

**Three PostgreSQL-specific settings the Siddhi apps must carry.** These are not needed for MySQL and are easy to miss:

| Setting | Why |
|---|---|
| `connector.properties='plugin.name=pgoutput'` | siddhi-io-cdc defaults the logical decoding plugin to `decoderbufs`, a Debezium-specific Postgres extension absent from stock PostgreSQL images. Without this the connector dies with `could not access file "decoderbufs"`. `pgoutput` is built into PostgreSQL 10+. |
| `table.name='public.<table>'` | For PostgreSQL, siddhi-io-cdc passes `table.name` straight into Debezium's `table.include.list`, which matches `schema.table`. A bare table name silently captures nothing. |
| `?stringtype=unspecified` in the polling URL | The polling cursor is bound as a string. MySQL coerces it to a number implicitly; PostgreSQL is strictly typed and rejects `bigint > character varying`. This pgjdbc option sends the value as `unknown` so PostgreSQL infers the type. |

The test database also needs `wal_level=logical` and `REPLICA IDENTITY FULL` on the captured table — the latter is what makes `before_*` fields populated on UPDATE/DELETE. Both are set by the Compose service and `infra/postgres-init/01_init.sql`.

### Oracle LDAP Naming Test (TC52)

Covers BNYMDMAPROD-232. The Oracle thin driver resolves `jdbc:oracle:thin:@ldap://host:port/SERVICE,cn=OracleContext,...` with a JNDI `DirContext` lookup. Inside SI every JNDI call goes through carbon-jndi, whose `WrapperContext` only implements `DirContext` from 1.0.7 onwards; older versions make the store fail to connect.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC52 | `test_tc52_oracle_ldap_store.sh` | `@store(type='rdbms')` on Oracle via LDAP directory naming | Oracle + OpenLDAP, ojdbc11 bundle, LDAP factory bundle |

Compose seeds OpenLDAP with a minimal Oracle Net schema (`infra/ldap-init/`) and a `FREEPDB1` net-service entry pointing at the Oracle container.

carbon-jndi only hands out JNDI factories registered as OSGi services, so the JDK's `com.sun.jndi.ldap.LdapCtxFactory` must be registered by a bundle. `infra/ldap-ctx-bundle/` builds a minimal one, equivalent to the provider bundle customers deploy for Oracle LDAP naming. On JDK 17+ that bundle needs `--add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED` to instantiate the factory. SI 4.4.1's `carbon.sh`/`carbon.bat` pass it; for older packs set it through `JAVA_OPTS`.

### Standalone tests after a suite run

`run_all_tests.sh` leaves the apps it deployed in `${SI_SIDDHI_DIR}`. The standalone tests below (TC56, TC60, TC62) restart SI, so after a suite run they start with every suite app deployed (about 35). Results can then depend on the other apps. For example, with `state.persistence` on, one app that fails to persist stops persistence for the apps after it. To test a standalone case on its own, stop SI and remove the suite apps first:

```bash
rm -f "${SI_HOME}/wso2/server/deployment/siddhi-files/"TC*.siddhi
```

### Kafka deployment.yaml Config Test (TC56)

Covers EIINTERNAL-637. Kafka source and sink options set under `siddhi.extensions` in `deployment.yaml` must replace the app's values for every Kafka source/sink on the node. siddhi-io-kafka 5.0.10–5.0.21 read them, then overwrote six source options (`optional.configuration`, `seq.enabled`, `is.binary.message`, `enable.offsets.commit`, `enable.async.commit`, `topic.offsets.map`) with the app's values again, so global SASL/SSL settings were silently dropped. Fixed in 5.0.22.

TC56 is **standalone**: it needs SI stopped, appends a `siddhi.extensions` block to `deployment.yaml`, starts SI, and restores `deployment.yaml` and stops SI on exit.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC56 | `test_tc56_kafka_deployment_config.sh` | Source `optional.configuration` (`client.id`) and sink `bootstrap.servers` from `deployment.yaml` | Kafka, Kafka client bundles in `lib/` (STANDALONE) |

Checks: the consumer group `tc56-group` shows CLIENT-ID `tc56-cfgtest` (it shows a generated id on 5.0.21), events flow through the source, and the sink delivers even though the app's `bootstrap.servers` is a closed port.

```bash
./scripts/setup.sh --kafka
# with SI running once: bin/extension-installer.sh install kafka, then stop SI
SI_HOME=/path/to/wso2si-4.4.1 bash scripts/test_tc56_kafka_deployment_config.sh
```

### Oracle Error Store Test (TC60)

Covers BNYMDMAPROD-86. The error store must work on Oracle 12c+. Listing and purge also need carbon-analytics `542eee502b`, which stores `timestamp` as `NUMBER(19)` instead of `LONG` (ORA-17027 on list, ORA-00997 on purge).

TC60 is **standalone**: it needs SI stopped, enables `error.store` with an Oracle `ERROR_STORE_DB` datasource in `deployment.yaml`, starts SI, and restores `deployment.yaml` and stops SI on exit.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC60 | `test_tc60_oracle_error_store.sh` | `DBErrorStore` on Oracle, HTTP sink `on.error='STORE'`, `/error-handler` API | Oracle, ojdbc11 bundle in `lib/` (STANDALONE) |

Checks: the table is created on the first stored error; entries get increasing identity ids; count, list and replay (to a receiver app) work; the table survives a restart; purge by retention empties it.

```bash
./scripts/setup.sh --oracle-ldap
SI_HOME=/path/to/wso2si-4.4.1 bash scripts/test_tc60_oracle_error_store.sh
```

### Kafka State Persistence Test (TC62)

Covers BNYMDMAPROD-250. Each persistence cycle pauses and resumes every source. Before siddhi-io-kafka 5.0.19, resume also seeked the consumer back to the snapshot offsets, which duplicated events.

TC62 is **standalone**: it needs SI stopped, enables `state.persistence` (1-minute interval) in `deployment.yaml`, starts SI, and restores `deployment.yaml` and stops SI on exit. It takes about 6 minutes.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC62 | `test_tc62_kafka_state_persistence.sh` | Kafka source (`partition.no.list='0,1,2,3'`, single thread) with periodic persistence and a restart; file sink counts | Kafka, Kafka client bundles in `lib/` (STANDALONE) |

Checks: 100 events sent at 1/s over at least two persistence cycles are each emitted once, with no `Seeking partition` on resume; after a restart the state is restored and only the 10 new events arrive (110 in total, all unique). The old code only re-seeked assigned partitions, so the app sets `partition.no.list`. With siddhi-io-kafka 5.0.18 the seek-back check fails.

```bash
./scripts/setup.sh --kafka
SI_HOME=/path/to/wso2si-4.4.1 bash scripts/test_tc62_kafka_state_persistence.sh
```

### Avro over Kafka Tests (TC58, TC64)

`siddhi-map-avro` embeds its own Avro and snappy-java, so a server-wide version bump doesn't reach them. TC58 exercises the mapper after they change (siddhi-map-avro 2.2.6: Avro 1.11.5, snappy-java 1.1.10.7). The embedded versions themselves are checked by TC53 T7.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC58 | `test_tc58_avro_kafka_roundtrip.sh` | `@map(type='avro')` Kafka sink and source with `is.binary.message='true'` | Kafka, Kafka client bundles in `lib/` |
| TC64 | `test_tc64_avro_schema_registry.sh` | `@map(type='avro', schema.registry=…, schema.id=…)` Kafka source and sink | Kafka, Schema Registry, Kafka client bundles in `lib/` |

Checks: an HTTP event is published as Avro and decoded back by the Avro Kafka source; topic `tc58-avro` holds the exact Avro binary encoding of the record (not JSON); a record hand-encoded and produced with `kcat` is decoded; no Avro or class-loading errors are logged. Runs in the Kafka group; the app deploys itself.

TC64 covers the schema-registry path, where siddhi-map-avro fetches the schema through its embedded Confluent client. Each run registers its own subject and uses its own topics, then replaces `@SCHEMA_ID@` and `@RUN_ID@` in the app before deploying it. Checks: the app deploys with the registered schema id; a record in the Confluent wire format (magic byte, schema id, Avro body) produced with `kcat` is decoded by the registry source; an HTTP event sent through the registry sink lands on the topic as exactly its plain Avro encoding and is decoded by a `schema.def` source; an unknown schema id fails deployment with the registry's "Schema … not found" error; no class-loading errors are logged. Runs in the Kafka group.

```bash
./scripts/setup.sh --kafka
SI_HOME=/path/to/wso2si-4.4.1 bash scripts/test_tc58_avro_kafka_roundtrip.sh
SI_HOME=/path/to/wso2si-4.4.1 bash scripts/test_tc64_avro_schema_registry.sh
```

### SMB File Test (TC65)

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC65 | `test_tc65_smb_file.sh` | `@sink(type='file')` and `@source(type='file', dir.uri=…)` on `smb://` and `smb2://` URIs | Samba (`setup.sh --samba`) |

For each scheme, the script fills `@SMB_BASE@` and `@RUN_ID@` in `siddhi-apps/templates/TC65_*.siddhi`, deploys the app and checks: it deploys; an HTTP event is written by the file sink to `<run>/out/<id>.txt` on the share; a CSV file placed in `<run>/in/` is read by the `dir.uri` source; no unknown-scheme or class-loading errors are logged. The templates live outside `siddhi-apps/` top level so `deploy.sh` doesn't deploy them unrendered. siddhi-io-file 2.0.27 to 2.0.29 (SI 4.4.0, 4.4.1 beta) fail at deployment: their SMB VFS providers were removed with the commons-vfs2 sandbox.

```bash
./scripts/setup.sh --samba
./run_all_tests.sh --with-samba   # or: ./run_all_tests.sh TC65
```

### Core SI Runtime Tests (TC40–TC42, TC44, TC47, TC50–TC51, TC57, TC59, TC63, TC66–TC67)

These run alongside TC01–TC18 as part of the standard core test run.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC40 | `test_tc40_file_sink.sh` | File sink in append mode, CSV mapping, HTTP trigger | None |
| TC41 | `test_tc41_grpc_echo.sh` | gRPC request-response (`grpc-service` + `grpc-call`) | None |
| TC42 | `test_tc42_grpc_consume.sh` | gRPC fire-and-forget (`grpc` source + `grpc` sink) | None |
| TC44 | `test_tc44_http_request_response.sh` | `http-request` sink + `http-response` source (sink.id correlation); `http-service` self-loop | None |
| TC47 | `test_tc47_xml_emit.sh` | XML emit via HTTP sink, XPath ingest, `ifThenElse` classification, self-loop round-trip | None |
| TC50 | `test_tc50_javascript_function.sh` | `script:javascript` named function with string transformation | `siddhi-script-js` |
| TC51 | `test_tc51_javascript_eval.sh` | `js:eval` dynamic arithmetic and boolean expressions | `siddhi-script-js` |
| TC57 | `test_tc57_cron_trigger_scheduler.sh` | Cron triggers with the same id in two apps; Quartz worker threads exit when no cron job is left (BNYMDMAPROD-220) | `jstack` on `PATH` |
| TC59 | `test_tc59_keyword_attribute_names.sh` | `offset`, `in`, `per`, `at` and `set` as attribute names in streams, filters, tables and on-demand queries (EIINTERNAL-1239) | None |
| TC63 | `test_tc63_file_search_dynamic_regex.sh` | `file:search` with a regex from each event, with `exclude.subdirectories` and `subdirectory.depth`; later events must not reuse the first event's regex (support fix #64, wso2/product-integrator-si#377) | None |
| TC66 | `test_tc66_map_functions.sh` | `map:createFromJSON` keeps Integer, Long and Double values and rejects deeply nested JSON with a `JSONException`, not a `StackOverflowError`; `map:toJSON` keeps null values; `map:createFromXML` number detection, where a leading `+` stays a string. Checks the org.json and commons-lang3 copies embedded in `siddhi-execution-map` | None |
| TC67 | `test_tc67_http_oauth_sink.sh` | `http` sink with `consumer.key`/`consumer.secret`/`token.url`: client credentials grant, a 401 from the API, a refresh-token grant and a successful retry, then token reuse. `infra/oauth-mock` serves the token endpoint and the API. siddhi-io-http parses the token responses with the platform org.json bundle | `python3` |

### Optional Extension Tests (TC43, TC45, TC46)

These tests self-skip when the required SI extension JARs are absent from `${SI_HOME}/wso2/lib/plugins/` (or `lib/`). They can be run with the corresponding flag once the extensions are installed.

| TC | Script | Feature Area | External Deps |
|---|---|---|---|
| TC43 | `test_tc43_thrift_databridge.sh` | Thrift DataBridge — WSO2Event data over TCP, login over SSL; external publisher with this pack's client and with an older pack's (`THRIFT_LEGACY_CLIENT_HOME`) | `siddhi-io-wso2event`, `siddhi-map-wso2event` (shipped in `infra/wso2event`) |
| TC45 | `test_tc45_rabbitmq.sh` | RabbitMQ source + filter + sink pass-through | `siddhi-io-rabbitmq` JARs + RabbitMQ broker |
| TC46 | `test_tc46_redis_store.sh` | `@store(type='redis')` PK upsert + Store API | `siddhi-store-redis` JAR + Redis |

### Kubernetes Live Tests — Gateway API (TC28–TC34)

These tests deploy the chart to a live cluster with Envoy Gateway and assert real Kubernetes resource state and HTTP routing behaviour.

| TC | Script | What is tested |
|---|---|---|
| TC28 | `test_tc28_k8s_resources_created.sh` | All K8s resources created with correct spec (Gateway, HTTPRoute, StatefulSet, Service) |
| TC29 | `test_tc29_k8s_gateway_programmed.sh` | Gateway condition `Programmed=True`, address assigned |
| TC30 | `test_tc30_k8s_httproute_accepted.sh` | HTTPRoute `Accepted=True`, `ResolvedRefs=True`, correct controller |
| TC31 | `test_tc31_k8s_si_pod_ready.sh` | SI pod `Running` and `Ready` (waits up to `K8S_POD_TIMEOUT` seconds) |
| TC32 | `test_tc32_k8s_https_routing.sh` | HTTPS traffic flows correctly: 404 unknown, 400/401 unauthenticated, 200 authenticated, TLS SNI enforced |
| TC33 | `test_tc33_k8s_backend_tls.sh` | `BackendTLSPolicy` created with correct API, targets `sectionName: management` |
| TC34 | `test_tc34_k8s_rate_limit.sh` | `BackendTrafficPolicy` created with correct Envoy API, rate limit values applied |

---

### Manual HA Tests

These need two nodes and a killed active node, so they are run by hand:

| Procedure | Covers |
|---|---|
| [`manual-tests/ha-cron-trigger.md`](manual-tests/ha-cron-trigger.md) | Cron triggers across HA state changes (BNYMDMAPROD-220) |
| [`manual-tests/ha-failover.md`](manual-tests/ha-failover.md) | Never both passive after failover (BNYMDMAPROD-198); one broken app doesn't block the others (BNYMDMAPROD-247) |

## Running Tests

### Core tests (no external infrastructure)

Runs TC01–TC06, TC09, TC10, TC12–TC18 (15 test cases):

```bash
./run_all_tests.sh
```

Add `--fail-on-skip` to any run to exit non-zero when a test was skipped (for example a missing JDBC driver), not just when one failed.

### With MySQL

Adds TC07 (RDBMS store) and TC11 (CDC polling):

```bash
# Start MySQL first
./scripts/setup.sh --mysql

# Then run
./run_all_tests.sh --with-mysql
```

### With PostgreSQL

Adds TC48 (CDC listening) and TC49 (CDC polling):

```bash
# Start PostgreSQL first
./scripts/setup.sh --postgres

# Place pgjdbc 42.7.11+ in the SI lib directory, then restart SI
cp postgresql-42.7.13.jar ${SI_HOME}/lib/

./run_all_tests.sh --with-postgres
```

### With Oracle via LDAP naming

Adds TC52. The Oracle image is large, so these services sit behind the `oracle` Compose profile and are not part of `--all`:

```bash
./scripts/setup.sh --oracle-ldap

# Oracle JDBC driver, converted to an OSGi bundle
curl -O https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.26.3.0.0/ojdbc11-23.26.3.0.0.jar
${SI_HOME}/bin/jartobundle.sh ojdbc11-23.26.3.0.0.jar ${SI_HOME}/lib

# Registers com.sun.jndi.ldap.LdapCtxFactory with carbon-jndi
SI_HOME=${SI_HOME} ./infra/ldap-ctx-bundle/build.sh

# Restart SI (packs older than 4.4.1 on JDK 17+ also need
# JAVA_OPTS="--add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED")
${SI_HOME}/bin/server.sh

./run_all_tests.sh --with-oracle-ldap
```

### With Samba

Adds TC65 (SMB file sink and source). The Samba container binds host port 445, so turn off macOS File Sharing over SMB first if it holds the port:

```bash
./scripts/setup.sh --samba
./run_all_tests.sh --with-samba
```

### With Kafka

Adds TC08 (Kafka source + sink), TC58 (Avro over Kafka) and TC64 (Avro with a Schema Registry). `setup.sh --kafka` also starts the Schema Registry:

```bash
./scripts/setup.sh --kafka
./run_all_tests.sh --with-kafka
```

### Helm chart tests (no cluster required)

Runs TC19–TC27. Requires `helm` in `PATH` and the `helm-si` chart at `HELM_SI_CHART`.

```bash
export HELM_SI_CHART=/path/to/helm-si
./run_all_tests.sh --with-helm
```

To exclude Helm tests from a run that would otherwise include them (e.g. `--all`), add `--skip-helm`:

```bash
# Run everything except the Helm chart tests
# Note: also automatically skips K8s live tests (TC28-TC34 depend on chart correctness)
./run_all_tests.sh --all --skip-helm

# Helm and K8s tests both explicitly skipped
./run_all_tests.sh --all --skip-helm --skip-k8s
```

Run a single Helm test case directly (no SI server needed):

```bash
bash scripts/test_tc21_gateway_api_enabled.sh
```

### Kubernetes live tests

Runs TC28–TC34. Requires a running cluster with Envoy Gateway installed.
Set up the cluster first (see [Kubernetes Setup](#kubernetes-setup-tc28tc34)), then:

```bash
./run_all_tests.sh --with-k8s
```

To skip K8s tests explicitly, use `--skip-k8s`:

```bash
# All tests except K8s live tests
./run_all_tests.sh --all --skip-k8s
```

**Automatic skip:** if `--skip-helm` is set, K8s tests are skipped automatically even when `--with-k8s` is present — the live tests deploy and validate the same chart, so skipping chart tests implies skipping the live tests too.

Run a single K8s test directly:

```bash
bash scripts/test_tc32_k8s_https_routing.sh
```

### Distribution tool tests (TC35–TC38)

TC35 is standalone — run it **before** starting the SI server:

```bash
export SI_HOME=/path/to/wso2si-<version>
bash scripts/test_tc35_server_lifecycle.sh
```

TC36–TC38 test distribution tools and run while SI is **not** running (they don't need a live server):

```bash
export SI_HOME=/path/to/wso2si-<version>
./run_all_tests.sh --with-tools
```

If your active JDK is newer than 11, TC37 and TC38 automatically fall back to the GraalVM CE JDK 11 at `/Library/Java/JavaVirtualMachines/graalvm-ce-java11-22.3.0/Contents/Home`. If that JDK is not installed they self-skip.

### CDC listening test (TC39)

TC39 requires MySQL with Debezium privileges. It is included in `--with-mysql` / `--all` runs:

```bash
./scripts/setup.sh --mysql
./run_all_tests.sh --with-mysql   # includes TC39 alongside TC07 and TC11
```

TC40–TC42, TC44, TC47, TC50, TC51, TC57, TC59, TC63, and TC66 are included automatically in all standard runs alongside TC01–TC18.

### Optional extension tests (TC43, TC45, TC46)

TC45 and TC46 self-skip when the required extension JARs are absent. TC43 never skips: when `siddhi-io-wso2event` or `siddhi-map-wso2event` is missing from `${SI_HOME}/lib`, it installs them from `infra/wso2event` (`infra/wso2event/install.sh`) and fails until SI is restarted.

```bash
# Thrift DataBridge. THRIFT_LEGACY_CLIENT_HOME is optional: an extracted older pack, such as
# SI 1.1.0 (libthrift 0.9.2), whose databridge client TC43 also publishes with.
SI_HOME=${SI_HOME} ./infra/wso2event/install.sh   # then restart SI
THRIFT_LEGACY_CLIENT_HOME=/path/to/wso2si-1.1.0 ./run_all_tests.sh --with-thrift

# RabbitMQ (requires siddhi-io-rabbitmq JARs + running RabbitMQ broker)
./scripts/setup.sh --rabbitmq
./run_all_tests.sh --with-rabbitmq

# Redis store (requires siddhi-store-redis JAR + running Redis)
./scripts/setup.sh --redis
./run_all_tests.sh --with-redis
```

### MongoDB installer tests

TC54 verifies the MongoDB store path installed by SI itself. TC55 verifies MongoDB CDC change streams. The setup starts MongoDB 8 as a single-node replica set because change streams require it. Start MongoDB, start SI once, install both extensions, then restart SI so its downloaded JARs are available to OSGi:

```bash
./scripts/setup.sh --mongodb
${SI_HOME}/bin/server.sh
# In another terminal, once SI has started:
${SI_HOME}/bin/extension-installer.sh install mongodb
${SI_HOME}/bin/extension-installer.sh install cdc-mongodb
# Stop and restart SI, then:
./run_all_tests.sh --with-mongodb
```

The tests require `siddhi-store-mongodb` or `siddhi-io-cdc` plus `mongodb-driver-sync`, `mongodb-driver-core`, `bson`, and `bson-record-codec` version 5.11.1. They fail if any expected installer artifact is absent.

### Full suite

All test cases including SI functional, Helm chart, and Kubernetes live tests:

```bash
./scripts/setup.sh --all               # Start Docker infrastructure
# ... start SI server, configure K8s (see below) ...
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

Named test cases pre-deploy the same apps as `--all`. Apps that a test script deploys one at a time (TC39, TC48, TC55, and TC52 and TC56–TC67) are left to the script. Several Debezium connectors on the same database can't run together.

You can also run a test script directly (apps must already be deployed):

```bash
./scripts/test_tc06_store_query.sh
```

---

## Infrastructure Setup

### Starting Docker services

```bash
# Start Kafka + Zookeeper + Schema Registry (host port 8081) only
./scripts/setup.sh --kafka

# Start MySQL only
./scripts/setup.sh --mysql

# Start PostgreSQL only
./scripts/setup.sh --postgres

# Start MongoDB only
./scripts/setup.sh --mongodb

# Start Samba (share "sambashare", user ubuntu/admin, host port 445) only
./scripts/setup.sh --samba

# Start everything
./scripts/setup.sh --all
```

`setup.sh` will:
1. Run `docker compose up -d` for the requested services.
2. Poll every 5 seconds until all containers report `healthy` (120 second timeout).
3. Create the Kafka topics `si-test-input` and `si-test-output` (if Kafka was started).
4. Verify MySQL database connectivity.
5. Warn if the MySQL JDBC driver JAR is missing from `${SI_HOME}/lib/`.

### Stopping Docker services

```bash
./scripts/teardown.sh --all
```

This also removes any deployed TC Siddhi apps from the SI deployment directory.

### MySQL JDBC driver

TC07, TC11, and TC39 require the MySQL Connector/J JAR to be present in `${SI_HOME}/lib/`. The SI distribution does not bundle it.

1. Download `mysql-connector-j-8.x.x.jar` from the [MySQL Downloads page](https://dev.mysql.com/downloads/connector/j/).
2. Place it in `${SI_HOME}/lib/`.
3. Restart the SI server.

`setup.sh --mysql` will warn you if the JAR is missing.

TC39 additionally requires the `sitest` user to have `RELOAD`, `SHOW DATABASES`, `REPLICATION SLAVE`, and `REPLICATION CLIENT` MySQL privileges (needed by Debezium's snapshot phase). These are granted automatically by `infra/mysql-init/01_init.sql` when the Docker Compose MySQL container is first started.

### PostgreSQL JDBC driver

TC48 and TC49 require the PostgreSQL JDBC driver in `${SI_HOME}/lib/`. The SI distribution does not bundle it.

1. Download `postgresql-42.7.11.jar` **or newer** from [Maven Central](https://repo1.maven.org/maven2/org/postgresql/postgresql/).
2. Place it in `${SI_HOME}/lib/`.
3. Restart the SI server.

Versions below 42.7.11 will run TC49 (polling) but fail TC48 (listening): Debezium 3.6.1 needs `withAutomaticFlush`, added in 42.7.11. `setup.sh --postgres` warns when the driver is missing or too old.

### Kafka OSGi jars

TC08 requires Kafka client JARs converted to OSGi bundles in `${SI_HOME}/lib/`. Follow the prerequisite steps documented in the existing `WorkingWithKafka/HelloKafka.siddhi` sample:

```
product-streaming-integrator/modules/samples/artifacts/WorkingWithKafka/HelloKafka.siddhi
```

The steps involve downloading Kafka 2.11, converting client JARs with `jartobundle.sh`, and placing the results in `${SI_HOME}/lib/`.

---

---

## Kubernetes Setup (TC28–TC34)

### Kubernetes Prerequisites

Before running TC28–TC34 verify the following:

- `kubectl` is configured and the target cluster is reachable (`kubectl cluster-info`).
- The cluster has the standard Gateway API CRDs installed (version ≥ 1.2). The setup script installs Envoy Gateway which also ships the additional CRDs (`BackendTLSPolicy`, `BackendTrafficPolicy`).
- Port 443 is **not already bound** on every cluster node by another LoadBalancer service. On Rancher Desktop / k3s, Traefik occupies port 443. Use `K8S_GATEWAY_PORT=8443` (the default) to avoid conflicts.
- `openssl` is available (used to generate the self-signed TLS certificate).
- Internet access for pulling `docker.io/wso2/wso2si:4.3.0-ubuntu` (~627 MB) and Envoy images.

### Install Envoy Gateway

```bash
bash scripts/k8s/setup_envoy_gateway.sh
```

This script:

1. Installs Envoy Gateway v1.3.2 from `oci://docker.io/envoyproxy/gateway-helm` into the `envoy-gateway-system` namespace.
2. Waits for the `envoy-gateway` deployment to roll out.
3. Creates the `GatewayClass` named `eg` with `controllerName: gateway.envoyproxy.io/gatewayclass-controller`.
4. Polls until the GatewayClass reports `Accepted=True`.

If Envoy Gateway is already installed, the script runs `helm upgrade` instead of `helm install`.

### Deploy WSO2 SI

```bash
bash scripts/k8s/setup_si.sh
```

This script:

1. Creates the namespace `wso2-si-k8s-test` (idempotent).
2. Generates a self-signed TLS certificate for `si.wso2.com` (with a SAN) and stores it as the Secret `si-gateway-tls`.
3. Installs the `helm-si` chart (from `HELM_SI_CHART`) with Gateway API enabled:
   - `wso2.ingress.enabled=false`
   - `wso2.gatewayApi.enabled=true`
   - `wso2.gatewayApi.gateway.tlsSecret=si-gateway-tls`
   - `wso2.gatewayApi.gateway.port=8443` (configurable via `K8S_GATEWAY_PORT`)
   - `wso2.gatewayApi.backendTLS.enabled=false`

The script exits immediately after deployment. The SI pod takes approximately **3 minutes** to become Ready (the readiness probe has a 180 s initial delay). TC31 waits automatically.

### Kubernetes Teardown

```bash
# Remove only the SI namespace (leaves Envoy Gateway intact)
bash scripts/k8s/teardown_k8s.sh

# Remove the SI namespace AND uninstall Envoy Gateway
bash scripts/k8s/teardown_k8s.sh --with-envoy-gateway
```

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

Log assertions only see what SI logged after the **log mark**. `common.sh` sets the mark when a test starts, and `undeploy_app` moves it once SI confirms the undeploy, so lines from earlier runs, earlier tests or the old app's shutdown can't satisfy a check. Call `mark_log` before a step whose pattern repeats an earlier one. Lines SI writes only at startup (Thrift ports, for example) are checked with `assert_boot_log_contains`, which reads from the start of the current boot.

Anchor patterns on the event data, not on a loose substring: LogSink prints `Event{timestamp=…, data=[…], isExpired=false}`, so a pattern like `'.*false'` or `'.*1'` matches every event.

```
assert_log_contains "description" '\[TC05-ALERT\].*data=\[u1, ' 15
```

**Deployment (`assert_app_deployed`, `redeploy_app`)**

`assert_app_deployed "desc" AppName` waits for `Siddhi App AppName deployed successfully` since the mark and fails if SI also logged `Error starting Siddhi App 'AppName'` or `Error on 'AppName'` (a source or sink that failed to start, such as an HTTP port already in use). SI logs "deployed successfully" even in that case. `redeploy_app file.siddhi AppName` undeploys, deploys and asserts, which also gives the test fresh in-memory state.

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

**Negative assertions** (`assert_log_not_contains`) sleep briefly, then check the log since the mark for absence. Some older tests (TC14, TC18, TC39, TC48, TC55–TC64) keep their own line or byte baselines, which work the same way.

**Results and exit codes.** A failed assertion records a failure and the test keeps going (`common.sh` does not use `set -e`), so every check runs and `print_summary` lists all failures. A test exits 0 when nothing failed, 1 when something failed, 77 (`SKIP_EXIT_CODE`) when a prerequisite such as a JDBC driver or extension is missing, and 78 (`PARTIAL_SKIP_EXIT_CODE`) when every check it ran passed but some were skipped with `log_skip`. `run_all_tests.sh` reports exit 77, and groups it turns off because their jars are missing, as SKIPPED with the reason, and lists every failed and skipped TC at the end. Tests that exit 78 count as passed and are listed as "PASSED, SOME CHECKS SKIPPED". Pass `--fail-on-skip` to make any skip, whole or partial, fail the run, which is what a release gate wants.

**Pack identity.** `SI_HOME` is required. The runner prints the pack version from `bin/version.txt`, and the runner and `require_si_running` check that the server on `SI_HTTP_PORT` is the one started from `SI_HOME` (its `wso2/server/runtime.pid` owns the port), so a second pack on the same machine can't be tested by mistake. `TOOLS_PACK_HOME` defaults to `SI_HOME`.

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

**TC37/TC38 skip with "no JDK 11 found"**
`osgi-lib.sh` and `ciphertool.sh` reject JDK > 11. TC37 and TC38 look for a JDK 11 installation at `/Library/Java/JavaVirtualMachines/graalvm-ce-java11-22.3.0/Contents/Home` and skip if it is absent. Install GraalVM CE 22.3.0 (Java 11) or change the `JAVA11=` path at the top of each script to point at any JDK 11 home on your system.

**TC43 fails with "wso2event extensions were missing" or "not loaded"**
TC43 needs `siddhi-io-wso2event` and `siddhi-map-wso2event` in `${SI_HOME}/lib`; they are not bundled with SI. The test copies them from `infra/wso2event` when they are missing. Restart SI so it loads them, then rerun. The Thrift agent accepts only `tcp://` data URLs: port 7711 carries the SSL login, not event data.

**TC08 fails with "Kafka broker not available"**
Either the Kafka Docker container is not running (`./scripts/setup.sh --kafka`) or the Kafka OSGi JARs are not in `${SI_HOME}/lib/`.

**TC14 takes 25+ seconds**
This is expected. TC14 tests a 15-second non-occurrence window, so the test waits for the window to expire. It is the slowest test by design.

**Store API returns unexpected record counts between runs**
In-memory tables persist for the lifetime of the SI server process. If you ran tests previously without restarting SI, old data may still be in tables. Restart the SI server between full test runs for a clean state, or use `--skip-deploy` and rely on the upsert semantics to overwrite existing records.

**"docker compose: command not found"**
Try `docker-compose` (with a hyphen) if you have the older CLI. The scripts use `docker compose` (the newer plugin form). You can add an alias: `alias docker-compose='docker compose'`.

---

### Kubernetes test troubleshooting (TC28–TC34)

**`svclb` pod is `Pending` / Gateway never gets `Programmed=True`**
Port `K8S_GATEWAY_PORT` is already occupied on the node. On Rancher Desktop, Traefik holds port 443. The default `K8S_GATEWAY_PORT=8443` avoids this. If 8443 is also taken, change it in `config.env` and re-run `setup_si.sh`.

```bash
# Check which ports are taken by svclb
kubectl get pods -n kube-system | grep svclb
kubectl describe pod <svclb-pod-name> -n kube-system | grep "FailedScheduling"
```

**`helm template` fails with `dig: interface conversion`**
The Helm version on the system is older than 3.14. Update Helm, or check that `helm version` shows ≥ 3.14.

**TC29: Gateway stuck at `Programmed=False` with `AddressNotAssigned`**
The Envoy proxy LoadBalancer service has no external IP. See the svclb issue above.

**TC30: HTTPRoute condition never becomes `True`**
Check the Envoy Gateway controller logs for reconciliation errors:
```bash
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=40
```
Common causes: the Gateway is not yet `Programmed`, or the headless Service has no endpoints (SI pod not Ready yet).

**TC31: SI pod stays `Pending`**
```bash
kubectl describe pod cloud-si-k8s-test-0 -n wso2-si-k8s-test | grep -A 5 "Events:"
```
Typical causes: image pull failure (check internet access / Docker Hub rate limits), or insufficient node resources.

**TC32: all requests return `000` (connection failed)**
The Envoy proxy NodePort is not reachable from the host. On Rancher Desktop, the node external IP is `192.168.64.2`. Verify connectivity:
```bash
nc -zv 192.168.64.2 <nodePort>
```
If unreachable, check whether Rancher Desktop's Lima VM is running and its network is up.

**TC32: requests return `503`**
Envoy can reach the backend service but the backend is returning an error. This is usually caused by routing to the HTTPS port (9443) without a `BackendTLSPolicy`. The chart automatically uses the HTTP port (9090) when `backendTLS.enabled=false`. Verify the HTTPRoute backend port:
```bash
kubectl get httproute -n wso2-si-k8s-test -o jsonpath='{.items[0].spec.rules[0].backendRefs[0].port}'
```
Expected: `9090`.

**TC33 skipped: `BackendTLSPolicy CRD not installed`**
The cluster has Gateway API CRDs older than v1.3. Installing Envoy Gateway v1.3.2 (via `setup_envoy_gateway.sh`) upgrades the CRDs automatically. If you installed Envoy Gateway manually, apply the experimental channel CRDs:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
```

**TC34 skipped: `BackendTrafficPolicy CRD not found`**
Envoy Gateway is not installed or the installation is incomplete. Re-run `setup_envoy_gateway.sh`.
