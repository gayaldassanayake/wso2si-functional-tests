# WSO2 Streaming Integrator — Functional Test Suite

A self-contained regression test suite for WSO2 Streaming Integrator (SI) 4.3.2. It covers:

- **18 SI functional tests** (TC01–TC18) — Siddhi apps, Docker Compose infrastructure, HTTP event injection, log scanning, Store API queries.
- **9 Helm chart tests** (TC19–TC27) — template rendering and lint validation for the updated `helm-si` chart with Gateway API support. No cluster required.
- **7 Kubernetes live tests** (TC28–TC34) — end-to-end validation of the Gateway API resources on a live cluster using Envoy Gateway.

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
  - [Helm chart tests (no cluster required)](#helm-chart-tests-no-cluster-required)
  - [Kubernetes live tests](#kubernetes-live-tests)
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

### SI functional tests (TC01–TC18)

| Requirement | Details |
|---|---|
| WSO2 SI 4.3.2 binary | Installed and configured. The server must be startable before running tests. |
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
├── siddhi-apps/                      ← 18 Siddhi applications (one per TC01–TC18)
│   ├── TC01_PassThrough.siddhi
│   ├── ...
│   └── TC18_ErrorHandling.siddhi
│
├── infra/
│   ├── docker-compose.yml            ← Kafka + Zookeeper + MySQL 8.0
│   └── mysql-init/
│       └── 01_init.sql
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
    └── test_tc34_k8s_rate_limit.sh            ─┘
```

---

## Quick Start

### SI functional tests (TC01–TC18)

```bash
# 1. Set your SI installation path
export SI_HOME=/path/to/wso2si-4.3.2

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
SI_HOME=/opt/wso2si-4.3.2 ./run_all_tests.sh
```

Key settings:

**SI functional tests**

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

TC08 uses Kafka (no HTTP port). TC11 uses CDC source. TC12 uses file source.

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

You can also run a test script directly (apps must already be deployed):

```bash
./scripts/test_tc06_store_query.sh
```

---

## Infrastructure Setup

### Starting Docker services

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

### Stopping Docker services

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
